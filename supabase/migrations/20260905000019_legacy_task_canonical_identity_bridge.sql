-- Issue #48 final closeout: keep the still-supported legacy task RPC surface
-- canonical-safe during R0/R1 coexistence.  New writes after the one-time DD2
-- backfill must not create rows that immediately fail DD11 reconciliation.

create or replace function private.fn_bridge_legacy_task_assignment_v1()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_actor_ref uuid;
begin
  if new.test_context_id is not null then return new; end if;
  if new.assignment_source is not null and new.assignment_source <> 'legacy_snapshot' then
    return new;
  end if;

  if new.planned_assignee_id is null then
    new.planned_assignee_actor_ref_id := null;
    new.assignment_mode := 'unassigned';
    new.assignment_source := 'legacy_snapshot';
    return new;
  end if;

  select a.id into v_actor_ref
  from public.domain_actor_refs a
  where a.household_id = new.household_id
    and a.actor_kind = 'real_user'
    and a.real_user_id = new.planned_assignee_id;
  if v_actor_ref is null then raise exception 'LEGACY_TASK_ASSIGNEE_ACTOR_REF_NOT_FOUND'; end if;

  new.planned_assignee_actor_ref_id := v_actor_ref;
  new.assignment_mode := 'person';
  new.assignment_source := 'legacy_snapshot';
  return new;
end;
$$;

revoke all on function private.fn_bridge_legacy_task_assignment_v1() from public, anon, authenticated;
grant execute on function private.fn_bridge_legacy_task_assignment_v1() to service_role;

drop trigger if exists task_instances_legacy_assignment_bridge_v1 on public.task_instances;
create trigger task_instances_legacy_assignment_bridge_v1
before insert or update of planned_assignee_id on public.task_instances
for each row execute function private.fn_bridge_legacy_task_assignment_v1();

create or replace function private.fn_bridge_legacy_task_event_actor_v1()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.test_context_id is null and new.actor_id is not null and new.actor_ref_id is null then
    select a.id into new.actor_ref_id
    from public.domain_actor_refs a
    where a.household_id = new.household_id
      and a.actor_kind = 'real_user'
      and a.real_user_id = new.actor_id;
    if new.actor_ref_id is null then raise exception 'LEGACY_TASK_EVENT_ACTOR_REF_NOT_FOUND'; end if;
  end if;
  return new;
end;
$$;

revoke all on function private.fn_bridge_legacy_task_event_actor_v1() from public, anon, authenticated;
grant execute on function private.fn_bridge_legacy_task_event_actor_v1() to service_role;

drop trigger if exists task_events_legacy_actor_bridge_v1 on public.task_events;
create trigger task_events_legacy_actor_bridge_v1
before insert on public.task_events
for each row execute function private.fn_bridge_legacy_task_event_actor_v1();

-- Preserve the established public signature/result while making completion
-- evidence canonical in the same transaction.  This is intentionally a
-- coexistence adapter, not a second domain model.
create or replace function public.server_tx_complete_task(
  p_actor_id uuid,
  p_operation_id uuid,
  p_task_id uuid,
  p_completion_actor text,
  p_complete_remaining_subtasks boolean
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_request_hash text;
  v_receipt record;
  v_household_id uuid;
  v_task public.task_instances%rowtype;
  v_resolved_actor uuid;
  v_operator_actor_ref uuid;
  v_performer_actor_ref uuid;
  v_result jsonb;
  v_request record;
begin
  if p_actor_id is null or p_operation_id is null or p_task_id is null then raise exception 'INVALID_INPUT'; end if;
  if p_completion_actor not in ('self','partner') then raise exception 'INVALID_INPUT'; end if;

  v_request_hash := encode(sha256(convert_to(
    'complete-task|' || p_task_id::text || '|' || p_completion_actor || '|' ||
    coalesce(p_complete_remaining_subtasks::text,''),'UTF8')),'hex');

  loop
    insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash)
      values(p_actor_id,p_operation_id,'complete-task',v_request_hash)
      on conflict(actor_id,operation_id) do nothing;
    if found then exit; end if;
    select * into v_receipt from private.mutation_receipts
      where actor_id=p_actor_id and operation_id=p_operation_id for update;
    if found then
      if v_receipt.request_hash<>v_request_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
      return v_receipt.result_payload;
    end if;
  end loop;

  select m.household_id,a.id into v_household_id,v_operator_actor_ref
  from public.household_members m
  join public.domain_actor_refs a on a.household_id=m.household_id
    and a.actor_kind='real_user' and a.real_user_id=m.user_id
  where m.user_id=p_actor_id;
  if v_household_id is null or v_operator_actor_ref is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;

  if p_completion_actor='self' then
    v_resolved_actor:=p_actor_id;
  else
    select user_id into v_resolved_actor from public.household_members
      where household_id=v_household_id and user_id<>p_actor_id order by created_at limit 1;
    if v_resolved_actor is null then raise exception 'INVALID_INPUT'; end if;
  end if;
  select id into v_performer_actor_ref from public.domain_actor_refs
    where household_id=v_household_id and actor_kind='real_user' and real_user_id=v_resolved_actor;
  if v_performer_actor_ref is null then raise exception 'TASK_PERFORMER_ACTOR_REF_NOT_FOUND'; end if;

  select * into v_task from public.task_instances
    where household_id=v_household_id and id=p_task_id for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if v_task.test_context_id is not null then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
  if v_task.status not in ('todo','in_progress') then raise exception 'TASK_TERMINAL'; end if;

  if v_task.completion_mode='whole' then
    update public.task_instances
      set status='completed',completed_at=now(),actual_completed_by_id=v_resolved_actor,
          active_claimant_actor_ref_id=null,claimed_at=null,attention_state='active',
          waiting_note=null,next_check_at=null,outcome_reason=null,revision=revision+1
      where household_id=v_household_id and id=p_task_id;
  else
    if coalesce(p_complete_remaining_subtasks,false) is not true then raise exception 'INVALID_INPUT'; end if;
    perform 1 from public.task_subtask_instances
      where household_id=v_household_id and task_instance_id=p_task_id for update;
    update public.task_subtask_instances
      set is_completed=true,completed_by=v_resolved_actor,completed_at=now()
      where household_id=v_household_id and task_instance_id=p_task_id and required and not is_completed;
    update public.task_instances
      set status='completed',completed_at=now(),active_claimant_actor_ref_id=null,claimed_at=null,
          attention_state='active',waiting_note=null,next_check_at=null,outcome_reason=null,revision=revision+1
      where household_id=v_household_id and id=p_task_id;
  end if;

  insert into public.task_actual_participants(
    household_id,task_instance_id,actor_ref_id,recorded_by_actor_ref_id,
    compatibility_primary,source,test_context_id
  ) values(
    v_household_id,p_task_id,v_performer_actor_ref,v_operator_actor_ref,
    v_task.completion_mode='whole','canonical',null
  ) on conflict do nothing;

  select * into v_request from public.requests
    where household_id=v_household_id and linked_task_instance_id=p_task_id and status='accepted'
    for update;
  if found then
    update public.requests set status='completed',completed_at=now()
      where household_id=v_household_id and id=v_request.id;
  end if;

  insert into public.task_events(
    household_id,task_instance_id,actor_id,actor_ref_id,test_context_id,
    event_type,payload,source,idempotency_key
  ) values(
    v_household_id,p_task_id,p_actor_id,v_operator_actor_ref,null,'completed',
    jsonb_build_object('performer_actor_ref_ids',jsonb_build_array(v_performer_actor_ref)),
    'pwa',p_operation_id::text||':completed'
  );

  v_result:=jsonb_build_object('ok',true);
  update private.mutation_receipts
    set actor_ref_id=v_operator_actor_ref,result_type='task_instance',result_id=p_task_id,result_payload=v_result
    where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end;
$$;

revoke all on function public.server_tx_complete_task(uuid,uuid,uuid,text,boolean) from public,anon,authenticated;
grant execute on function public.server_tx_complete_task(uuid,uuid,uuid,text,boolean) to service_role;
