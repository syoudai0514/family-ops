-- Draft-only internal primitive: no scheduler, RPC, or client may call this.
-- A narrowly scoped transaction marker suppresses external projections only
-- for the one exact archive transition. Every other change retains its normal
-- Google/transport triggers, including changes in the same transaction.
create function private.fn_is_unrecorded_archive_transition_v1(p_old public.task_instances,p_new public.task_instances)
returns boolean language sql stable security invoker set search_path='' as $$
  select coalesce(current_setting('family_ops.unrecorded_archive_task',true)=(p_new).id::text,false)
    and (p_old).status='todo' and (p_new).status='skipped' and (p_new).outcome_reason='unrecorded'
    and (p_new).active_claimant_actor_ref_id is null and (p_new).claimed_at is null
    and (p_new).revision=(p_old).revision+1
    and (to_jsonb(p_old)-array['status','outcome_reason','active_claimant_actor_ref_id','claimed_at','revision','updated_at'])
      =(to_jsonb(p_new)-array['status','outcome_reason','active_claimant_actor_ref_id','claimed_at','revision','updated_at']);
$$;
revoke all on function private.fn_is_unrecorded_archive_transition_v1(public.task_instances,public.task_instances)
  from public,anon,authenticated,service_role;

create or replace function private.fn_enqueue_family_ops_calendar_task()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if tg_op='UPDATE' then
    if private.fn_is_unrecorded_archive_transition_v1(old,new) then return new; end if;
  end if;
  if tg_op='DELETE' then
    if old.test_context_id is not null then return old; end if;
    perform private.enqueue_family_ops_calendar_projection(old.household_id,old.task_definition_id,old.scheduled_date,old.id);
    return old;
  end if;
  if new.test_context_id is not null then return new; end if;
  if tg_op='UPDATE' and old.scheduled_date is distinct from new.scheduled_date then
    perform private.enqueue_family_ops_calendar_projection(old.household_id,old.task_definition_id,old.scheduled_date,old.id);
  end if;
  perform private.enqueue_family_ops_calendar_projection(new.household_id,new.task_definition_id,new.scheduled_date,new.id);
  return new;
end $$;

create or replace function private.fn_transport_role_anchor_reconcile_trigger_v1()
returns trigger language plpgsql security definer set search_path='' as $$
declare v_row public.task_instances%rowtype; v_code text; v_should_reconcile boolean:=false;
begin
  if tg_op='UPDATE' then
    if private.fn_is_unrecorded_archive_transition_v1(old,new) then return new; end if;
  end if;
  if tg_op='DELETE' then v_row:=old; else v_row:=new; end if;
  if v_row.test_context_id is not null then
    if tg_op='DELETE' then return old; end if;
    return new;
  end if;
  select td.code into v_code from public.task_definitions td
    where td.household_id=v_row.household_id and td.id=v_row.task_definition_id;
  if v_code not in ('pickup','dropoff') then
    if tg_op='DELETE' then return old; end if;
    return new;
  end if;
  if tg_op='INSERT' or tg_op='DELETE' then v_should_reconcile:=true;
  elsif tg_op='UPDATE' then
    v_should_reconcile:=new.status not in ('todo','in_progress') or new.planned_assignee_id is null
      or old.status not in ('todo','in_progress') or old.planned_assignee_id is null;
  end if;
  if v_should_reconcile then
    perform private.fn_reconcile_transport_role_date_v1(v_row.household_id,v_row.scheduled_date,v_code,'transport_anchor_state',v_row.id);
  end if;
  if tg_op='DELETE' then return old; end if;
  return new;
end $$;

create function private.fn_archive_unrecorded_routine_v1(
  p_household uuid,p_task uuid,p_before date,p_expected_revision bigint
) returns jsonb language plpgsql security definer set search_path='' as $$
declare t public.task_instances%rowtype; old_marker text; saved_state jsonb; next_revision bigint;
begin
  if p_household is null or p_task is null or p_before is null or p_expected_revision is null or p_expected_revision<1 then
    raise exception 'INVALID_INPUT';
  end if;
  select * into t from public.task_instances where household_id=p_household and id=p_task for update;
  if not found then return jsonb_build_object('archived',false,'reason','not_found'); end if;
  if t.revision<>p_expected_revision then
    if t.status='skipped' and t.outcome_reason='unrecorded' and exists(
      select 1 from private.unrecorded_routine_archives a where a.household_id=p_household and a.task_id=p_task
        and a.before_revision=p_expected_revision and a.closed_revision=t.revision
    ) then return jsonb_build_object('archived',true,'already_archived',true,'revision',t.revision); end if;
    return jsonb_build_object('archived',false,'reason','stale');
  end if;
  -- Recheck all protections after taking the task lock. The primitive is private
  -- and deliberately has no scheduler until correction/undo and races are proven.
  if not exists(select 1 from private.fn_unrecorded_routine_candidates_v1(p_before,p_household,p_task)) then
    return jsonb_build_object('archived',false,'reason','protected');
  end if;
  saved_state:=jsonb_build_object('status',t.status,'attention_state',t.attention_state,
    'active_claimant_actor_ref_id',t.active_claimant_actor_ref_id,'claimed_at',t.claimed_at,
    'waiting_note',t.waiting_note,'next_check_at',t.next_check_at,'outcome_reason',t.outcome_reason,
    'rescheduled_to',t.rescheduled_to,'actual_completed_by_id',t.actual_completed_by_id,'completed_at',t.completed_at);
  next_revision:=t.revision+1;
  insert into private.unrecorded_routine_archives(household_id,task_id,before_revision,closed_revision,before_state)
    values(p_household,p_task,t.revision,next_revision,saved_state);
  old_marker:=coalesce(current_setting('family_ops.unrecorded_archive_task',true),'');
  perform set_config('family_ops.unrecorded_archive_task',p_task::text,true);
  update public.task_instances set status='skipped',outcome_reason='unrecorded',
    active_claimant_actor_ref_id=null,claimed_at=null,revision=next_revision
    where household_id=p_household and id=p_task;
  perform set_config('family_ops.unrecorded_archive_task',old_marker,true);
  return jsonb_build_object('archived',true,'revision',next_revision);
end $$;
revoke all on function private.fn_archive_unrecorded_routine_v1(uuid,uuid,date,bigint)
  from public,anon,authenticated,service_role;
