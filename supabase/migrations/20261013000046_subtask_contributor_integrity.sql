-- A checklist can be prepared by one adult and finished by another. Each
-- item's performer/recorder is its truth; finishing the remaining items must
-- preserve earlier work. Parent participants describe a completed result,
-- while an open checklist keeps its partial contributions on its items.

-- Finding an item already prepared is known readiness, even when the person
-- who prepared it is unknown. The observer is a recorder, never a performer.
alter table public.task_subtask_instances
  drop constraint task_subtask_instances_completion_v2_chk,
  add constraint task_subtask_instances_completion_v3_chk check (
    (is_completed and completed_at is not null
      and (completed_by is not null or completed_by_actor_ref_id is not null
        or recorded_by_actor_ref_id is not null))
    or (not is_completed and completed_by is null
      and completed_by_actor_ref_id is null and completed_at is null)
  );

create or replace function private.fn_sync_checklist_participants_v1(
  p_household_id uuid,
  p_task_id uuid,
  p_recorder_actor_ref_id uuid,
  p_completion_performer_actor_ref_id uuid
) returns uuid[]
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_task public.task_instances%rowtype;
  v_contributions jsonb := '[]'::jsonb;
  v_performers uuid[] := '{}'::uuid[];
  v_required_count integer;
  v_explicit_performers jsonb := '[]'::jsonb;
  v_item jsonb;
begin
  select * into v_task from public.task_instances
  where household_id=p_household_id and id=p_task_id for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if v_task.test_context_id is not null then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
  if v_task.completion_mode <> 'subtasks' then raise exception 'INVALID_INPUT'; end if;
  perform private.fn_assert_actor_ref_scope(p_household_id,p_recorder_actor_ref_id,null);
  perform private.fn_assert_actor_ref_scope(p_household_id,p_completion_performer_actor_ref_id,null);

  if v_task.status='completed' then
    -- Legacy completed_by is known evidence, but an unknown historical recorder
    -- stays unknown. Do not claim the current recorder performed earlier items.
    select coalesce(jsonb_agg(jsonb_build_object(
      'actor_ref_id',c.actor_ref_id,'recorded_by_actor_ref_id',c.recorded_by_actor_ref_id,
      'recorded_at',c.completed_at
    )),'[]'::jsonb) into v_contributions
    from (
      select distinct on (a.id) a.id as actor_ref_id,
        s.recorded_by_actor_ref_id,s.completed_at
      from public.task_subtask_instances s
      join public.domain_actor_refs a on a.household_id=s.household_id
        and a.actor_kind='real_user' and a.test_context_id is null
        and (a.id=s.completed_by_actor_ref_id
          or (s.completed_by_actor_ref_id is null and a.real_user_id=s.completed_by))
      where s.household_id=p_household_id and s.task_instance_id=p_task_id
        and s.test_context_id is null and s.is_completed
      order by a.id,s.completed_at,s.id
    ) c;

    select coalesce(array_agg((x->>'actor_ref_id')::uuid),'{}'::uuid[])
    into v_performers from jsonb_array_elements(v_contributions) x;

    if p_completion_performer_actor_ref_id is not null
       and not p_completion_performer_actor_ref_id=any(v_performers) then
      v_contributions := v_contributions || jsonb_build_array(jsonb_build_object(
        'actor_ref_id',p_completion_performer_actor_ref_id,
        'recorded_by_actor_ref_id',p_recorder_actor_ref_id,'recorded_at',now()
      ));
      v_performers := array_append(v_performers,p_completion_performer_actor_ref_id);
    end if;

    select count(*) into v_required_count from public.task_subtask_instances
    where household_id=p_household_id and task_instance_id=p_task_id and required;
    -- With an optional-only checklist, explicit parent completion is separate
    -- from optional checks. Undoing an optional check does not undo that result.
    if v_required_count=0 then
      select case
        when e.payload->>'completion_performer_actor_ref_id' is not null
          then jsonb_build_array(e.payload->'completion_performer_actor_ref_id')
        else coalesce(e.payload->'performer_actor_ref_ids','[]'::jsonb)
      end into v_explicit_performers
      from public.task_events e
      where e.household_id=p_household_id and e.task_instance_id=p_task_id
        and e.test_context_id is null and e.event_type='completed'
      order by coalesce((e.payload->>'revision')::bigint,0) desc,e.created_at desc,e.id desc
      limit 1;
      select coalesce(array_agg(distinct id),'{}'::uuid[]) into v_performers
      from (
        select unnest(v_performers) id
        union all
        select a.id from jsonb_array_elements_text(coalesce(v_explicit_performers,'[]'::jsonb)) x
        join public.domain_actor_refs a on a.id=x.value::uuid and a.household_id=p_household_id
          and a.actor_kind='real_user' and a.test_context_id is null
      ) declared;
    end if;
  end if;

  update public.task_actual_participants
  set removed_at=now(),removed_by_actor_ref_id=p_recorder_actor_ref_id,
      compatibility_primary=false
  where household_id=p_household_id and task_instance_id=p_task_id
    and test_context_id is null and removed_at is null
    and not actor_ref_id=any(v_performers);

  for v_item in select value from jsonb_array_elements(v_contributions) loop
    insert into public.task_actual_participants(
      household_id,task_instance_id,actor_ref_id,recorded_by_actor_ref_id,
      recorded_at,compatibility_primary,source,test_context_id
    ) values(
      p_household_id,p_task_id,(v_item->>'actor_ref_id')::uuid,
      (v_item->>'recorded_by_actor_ref_id')::uuid,
      (v_item->>'recorded_at')::timestamptz,false,'canonical',null
    ) on conflict (task_instance_id,actor_ref_id) where removed_at is null do nothing;
  end loop;
  return v_performers;
end;
$$;
revoke all on function private.fn_sync_checklist_participants_v1(uuid,uuid,uuid,uuid)
  from public,anon,authenticated;
grant execute on function private.fn_sync_checklist_participants_v1(uuid,uuid,uuid,uuid) to service_role;

-- No default on the new overload: PostgREST must distinguish it from the
-- established five-argument compatibility entrypoint.
create or replace function public.server_tx_set_subtask_completion(
  p_actor_id uuid,
  p_operation_id uuid,
  p_subtask_instance_id uuid,
  p_completed boolean,
  p_completion_actor text,
  p_expected_revision bigint
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_context jsonb;
  v_household_id uuid;
  v_recorder_actor_ref uuid;
  v_performer_user_id uuid;
  v_performer_actor_ref uuid;
  v_hash text;
  v_receipt private.mutation_receipts%rowtype;
  v_task public.task_instances%rowtype;
  v_subtask public.task_subtask_instances%rowtype;
  v_task_id uuid;
  v_required_total integer;
  v_required_remaining integer;
  v_status text;
  v_revision bigint;
  v_performers uuid[];
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_subtask_instance_id is null
     or p_completed is null or p_completion_actor is null
     or p_completion_actor not in ('self','partner','unknown')
     or (p_expected_revision is not null and p_expected_revision<1) then
    raise exception 'INVALID_INPUT';
  end if;
  v_context := private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id := (v_context->>'household_id')::uuid;
  v_recorder_actor_ref := (v_context->>'actor_ref_id')::uuid;
  v_hash := encode(sha256(convert_to(
    'set-subtask-completion|'||p_subtask_instance_id::text||'|'||p_completed::text
      ||'|'||p_completion_actor||coalesce('|revision:'||p_expected_revision::text,''),
    'UTF8')),'hex');

  loop
    insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash,actor_ref_id)
    values(p_actor_id,p_operation_id,'set-subtask-completion',v_hash,v_recorder_actor_ref)
    on conflict(actor_id,operation_id) do nothing;
    if found then exit; end if;
    select * into v_receipt from private.mutation_receipts
    where actor_id=p_actor_id and operation_id=p_operation_id for update;
    if found then
      if v_receipt.action_type<>'set-subtask-completion' or v_receipt.request_hash<>v_hash then
        raise exception 'IDEMPOTENCY_CONFLICT';
      end if;
      if v_receipt.result_payload is null then raise exception 'IDEMPOTENCY_INCOMPLETE'; end if;
      if v_receipt.test_context_id is not null then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
      if v_receipt.actor_ref_id is not null then
        if v_receipt.actor_ref_id<>v_recorder_actor_ref then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
      elsif not exists(select 1 from public.task_subtask_instances
        where household_id=v_household_id and id=v_receipt.result_id and test_context_id is null)
        and not exists(select 1 from public.task_events
          where household_id=v_household_id and idempotency_key=p_operation_id::text||':subtask'
            and actor_id=p_actor_id and test_context_id is null) then
        raise exception 'CROSS_HOUSEHOLD_RESOURCE';
      end if;
      return v_receipt.result_payload;
    end if;
  end loop;

  -- Read the parent id without a child lock, then take parent -> child locks.
  -- A template edit may remove the item while this operation waits.
  select task_instance_id into v_task_id from public.task_subtask_instances
  where household_id=v_household_id and id=p_subtask_instance_id;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  select * into v_task from public.task_instances
  where household_id=v_household_id and id=v_task_id for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if v_task.test_context_id is not null then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
  if p_expected_revision is not null and v_task.revision<>p_expected_revision then
    raise exception 'AGGREGATE_REVISION_CONFLICT';
  end if;
  if v_task.completion_mode<>'subtasks' then raise exception 'INVALID_INPUT'; end if;
  if v_task.status not in ('todo','in_progress','completed') then raise exception 'TASK_TERMINAL'; end if;
  select * into v_subtask from public.task_subtask_instances
  where household_id=v_household_id and id=p_subtask_instance_id
    and task_instance_id=v_task.id for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if v_subtask.test_context_id is not null then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;

  -- Another recorder checking an already checked item cannot replace its
  -- performer or timestamp. A correction uses explicit undo then a new check.
  if v_subtask.is_completed=p_completed then
    v_result:=jsonb_build_object('ok',true,'changed',false,'revision',v_task.revision);
  else
    if p_completion_actor='unknown' then
      v_performer_user_id:=null;
      v_performer_actor_ref:=null;
    elsif p_completion_actor='self' then
      v_performer_user_id:=p_actor_id;
    else
      select user_id into v_performer_user_id from public.household_members
      where household_id=v_household_id and user_id<>p_actor_id
      order by joined_at,user_id limit 1;
      if v_performer_user_id is null then raise exception 'INVALID_INPUT'; end if;
    end if;
    if p_completion_actor<>'unknown' then
      select id into v_performer_actor_ref from public.domain_actor_refs
      where household_id=v_household_id and actor_kind='real_user'
        and real_user_id=v_performer_user_id and test_context_id is null;
      if v_performer_actor_ref is null then raise exception 'TASK_PERFORMER_ACTOR_REF_NOT_FOUND'; end if;
    end if;
    if p_completed and v_task.assignment_mode='anyone'
       and v_task.active_claimant_actor_ref_id is not null
       and v_task.active_claimant_actor_ref_id<>coalesce(v_performer_actor_ref,v_recorder_actor_ref) then
      raise exception 'TASK_CLAIMED_BY_OTHER';
    end if;

    update public.task_subtask_instances set
      is_completed=p_completed,
      completed_by=case when p_completed then v_performer_user_id else null end,
      completed_by_actor_ref_id=case when p_completed then v_performer_actor_ref else null end,
      recorded_by_actor_ref_id=case when p_completed then v_recorder_actor_ref else null end,
      completed_at=case when p_completed then now() else null end
    where household_id=v_household_id and id=p_subtask_instance_id;

    select count(*) filter(where required),count(*) filter(where required and not is_completed)
    into v_required_total,v_required_remaining
    from public.task_subtask_instances where household_id=v_household_id and task_instance_id=v_task.id;
    v_status:=case
      when v_required_total>0 and v_required_remaining=0 then 'completed'
      when v_task.status='completed' and v_required_total=0 then 'completed'
      -- Checklist progress is represented by its items. Merely checking an
      -- item keeps an open parent's existing status, including routine pause
      -- eligibility for a future todo. Reopening completed work is in_progress.
      when v_task.status in ('in_progress','completed') then 'in_progress'
      else 'todo' end;
    update public.task_instances set
      status=v_status,
      completed_at=case when v_status='completed' then coalesce(v_task.completed_at,now()) else null end,
      attention_state=case when v_status='completed' then 'active' else attention_state end,
      waiting_note=case when v_status='completed' then null else waiting_note end,
      next_check_at=case when v_status='completed' then null else next_check_at end,
      active_claimant_actor_ref_id=case when v_status='completed' then null else active_claimant_actor_ref_id end,
      claimed_at=case when v_status='completed' then null else claimed_at end,
      outcome_reason=null,revision=revision+1
    where household_id=v_household_id and id=v_task.id returning revision into v_revision;
    v_performers:=private.fn_sync_checklist_participants_v1(v_household_id,v_task.id,v_recorder_actor_ref,null);
    insert into public.task_events(
      household_id,task_instance_id,actor_id,actor_ref_id,test_context_id,event_type,payload,source,idempotency_key
    ) values(
      v_household_id,v_task.id,p_actor_id,v_recorder_actor_ref,null,
      case when p_completed then 'subtask_completed' else 'subtask_completion_reverted' end,
      jsonb_build_object('subtask_instance_id',v_subtask.id,'subtask_title',v_subtask.title,
        'completed',p_completed,'performer_actor_ref_id',case when p_completed then v_performer_actor_ref else null end,
        'completion_basis',case when p_completed and p_completion_actor='unknown' then 'observed_ready' else 'performed' end,
        'previous_performer_actor_ref_id',v_subtask.completed_by_actor_ref_id,
        'previous_completed_by',v_subtask.completed_by,'previous_completed_at',v_subtask.completed_at,
        'performer_actor_ref_ids',to_jsonb(v_performers),
        'previous_status',v_task.status,'status',v_status,'previous_revision',v_task.revision,'revision',v_revision),
      'pwa',p_operation_id::text||':subtask'
    );
    v_result:=jsonb_build_object('ok',true,'changed',true,'revision',v_revision,'status',v_status);
  end if;
  update private.mutation_receipts set result_type='task_subtask_instance',result_id=p_subtask_instance_id,result_payload=v_result
  where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end;
$$;
revoke all on function public.server_tx_set_subtask_completion(uuid,uuid,uuid,boolean,text,bigint)
  from public,anon,authenticated;
grant execute on function public.server_tx_set_subtask_completion(uuid,uuid,uuid,boolean,text,bigint) to service_role;

create or replace function public.server_tx_set_subtask_completion(
  p_actor_id uuid,p_operation_id uuid,p_subtask_instance_id uuid,p_completed boolean,p_completion_actor text
) returns jsonb language sql security invoker set search_path='' as $$
  select public.server_tx_set_subtask_completion(
    p_actor_id,p_operation_id,p_subtask_instance_id,p_completed,p_completion_actor,null::bigint
  );
$$;
revoke all on function public.server_tx_set_subtask_completion(uuid,uuid,uuid,boolean,text)
  from public,anon,authenticated;
grant execute on function public.server_tx_set_subtask_completion(uuid,uuid,uuid,boolean,text) to service_role;

create or replace function public.server_tx_complete_task(
  p_actor_id uuid,p_operation_id uuid,p_task_id uuid,p_completion_actor text,
  p_complete_remaining_subtasks boolean,p_source text
) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare
  v_request_hash text;
  v_receipt private.mutation_receipts%rowtype;
  v_context jsonb;
  v_household_id uuid;
  v_operator_actor_ref uuid;
  v_performer_user_id uuid;
  v_performer_actor_ref uuid;
  v_task public.task_instances%rowtype;
  v_completed_revision bigint;
  v_performers uuid[];
  v_request record;
  v_result jsonb;
  v_source text:=coalesce(p_source,'pwa');
begin
  if p_actor_id is null or p_operation_id is null or p_task_id is null
     or p_completion_actor is null or p_completion_actor not in ('self','partner')
     or v_source not in ('pwa','line') then raise exception 'INVALID_INPUT'; end if;
  v_context:=private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id:=(v_context->>'household_id')::uuid;
  v_operator_actor_ref:=(v_context->>'actor_ref_id')::uuid;
  -- Keep the established request hash so already-issued receipts still replay.
  v_request_hash:=encode(sha256(convert_to(
    'complete-task|'||p_task_id::text||'|'||p_completion_actor||'|'||
    coalesce(p_complete_remaining_subtasks::text,''),'UTF8')),'hex');
  loop
    insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash,actor_ref_id)
    values(p_actor_id,p_operation_id,'complete-task',v_request_hash,v_operator_actor_ref)
    on conflict(actor_id,operation_id) do nothing;
    if found then exit; end if;
    select * into v_receipt from private.mutation_receipts
    where actor_id=p_actor_id and operation_id=p_operation_id for update;
    if found then
      if v_receipt.action_type<>'complete-task' or v_receipt.request_hash<>v_request_hash then
        raise exception 'IDEMPOTENCY_CONFLICT'; end if;
      if v_receipt.result_payload is null then raise exception 'IDEMPOTENCY_INCOMPLETE'; end if;
      if v_receipt.test_context_id is not null then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
      if v_receipt.actor_ref_id is not null then
        if v_receipt.actor_ref_id<>v_operator_actor_ref then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
      elsif not exists(select 1 from public.task_instances
        where household_id=v_household_id and id=v_receipt.result_id and test_context_id is null) then
        raise exception 'CROSS_HOUSEHOLD_RESOURCE';
      end if;
      return v_receipt.result_payload;
    end if;
  end loop;
  if p_completion_actor='self' then v_performer_user_id:=p_actor_id;
  else
    select user_id into v_performer_user_id from public.household_members
    where household_id=v_household_id and user_id<>p_actor_id order by joined_at,user_id limit 1;
    if v_performer_user_id is null then raise exception 'INVALID_INPUT'; end if;
  end if;
  select id into v_performer_actor_ref from public.domain_actor_refs
  where household_id=v_household_id and actor_kind='real_user' and real_user_id=v_performer_user_id
    and test_context_id is null;
  if v_performer_actor_ref is null then raise exception 'TASK_PERFORMER_ACTOR_REF_NOT_FOUND'; end if;
  select * into v_task from public.task_instances
  where household_id=v_household_id and id=p_task_id for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if v_task.test_context_id is not null then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
  if v_task.status not in ('todo','in_progress') then raise exception 'TASK_TERMINAL'; end if;
  if v_task.assignment_mode='anyone' and v_task.active_claimant_actor_ref_id is not null
     and v_task.active_claimant_actor_ref_id<>v_performer_actor_ref then raise exception 'TASK_CLAIMED_BY_OTHER'; end if;

  if v_task.completion_mode='subtasks' then
    if coalesce(p_complete_remaining_subtasks,false) is not true then raise exception 'INVALID_INPUT'; end if;
    perform 1 from public.task_subtask_instances
    where household_id=v_household_id and task_instance_id=p_task_id order by id for update;
    if exists(select 1 from public.task_subtask_instances
      where household_id=v_household_id and task_instance_id=p_task_id and test_context_id is not null) then
      raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
    update public.task_subtask_instances set
      is_completed=true,completed_by=v_performer_user_id,completed_by_actor_ref_id=v_performer_actor_ref,
      recorded_by_actor_ref_id=v_operator_actor_ref,completed_at=now()
    where household_id=v_household_id and task_instance_id=p_task_id and required and not is_completed;
  end if;
  update public.task_instances set status='completed',completed_at=now(),
    actual_completed_by_id=case when completion_mode='whole' then v_performer_user_id else null end,
    active_claimant_actor_ref_id=null,claimed_at=null,attention_state='active',waiting_note=null,
    next_check_at=null,outcome_reason=null,revision=revision+1
  where household_id=v_household_id and id=p_task_id returning revision into v_completed_revision;

  if v_task.completion_mode='subtasks' then
    v_performers:=private.fn_sync_checklist_participants_v1(
      v_household_id,p_task_id,v_operator_actor_ref,v_performer_actor_ref
    );
  else
    insert into public.task_actual_participants(
      household_id,task_instance_id,actor_ref_id,recorded_by_actor_ref_id,
      compatibility_primary,source,test_context_id
    ) values(v_household_id,p_task_id,v_performer_actor_ref,v_operator_actor_ref,true,'canonical',null)
    on conflict do nothing;
    v_performers:=array[v_performer_actor_ref];
  end if;
  select * into v_request from public.requests
  where household_id=v_household_id and linked_task_instance_id=p_task_id and status='accepted' for update;
  if found then update public.requests set status='completed',completed_at=now()
    where household_id=v_household_id and id=v_request.id; end if;
  insert into public.task_events(
    household_id,task_instance_id,actor_id,actor_ref_id,test_context_id,event_type,payload,source,idempotency_key
  ) values(v_household_id,p_task_id,p_actor_id,v_operator_actor_ref,null,'completed',
    jsonb_build_object('performer_actor_ref_ids',to_jsonb(v_performers),
      'completion_performer_actor_ref_id',v_performer_actor_ref,
      'previous_revision',v_task.revision,'revision',v_completed_revision),
    v_source,p_operation_id::text||':completed');
  v_result:=jsonb_build_object('ok',true,'revision',v_completed_revision);
  update private.mutation_receipts set result_type='task_instance',result_id=p_task_id,result_payload=v_result
  where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end;
$$;
revoke all on function public.server_tx_complete_task(uuid,uuid,uuid,text,boolean,text)
  from public,anon,authenticated;
grant execute on function public.server_tx_complete_task(uuid,uuid,uuid,text,boolean,text) to service_role;
