-- LINE saved-input correction is a thin, scoped adapter over existing task
-- writers. A succeeded pending action is provenance, never a second task truth.
create function public.server_read_line_saved_task_v1(
  p_actor_id uuid, p_pending_action_id uuid
) returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare
  v_context jsonb;
  v_household uuid;
  v_pending private.pending_actions%rowtype;
  v_task public.task_instances%rowtype;
begin
  v_context:=private.fn_require_production_actor_context_v1(p_actor_id);
  v_household:=(v_context->>'household_id')::uuid;
  select * into v_pending from private.pending_actions
    where id=p_pending_action_id and actor_id=p_actor_id and household_id=v_household
      and source='line' and status='succeeded' and action_type='task_create_once'
      and result_type in ('task','task_instance') and result_id is not null
      and updated_at>=now()-interval '24 hours';
  if not found then raise exception 'LINE_SAVED_TASK_NOT_CORRECTABLE'; end if;
  select * into v_task from public.task_instances where id=v_pending.result_id
    and household_id=v_household and test_context_id is null
    and origin='manual' and task_definition_id is null and created_by=p_actor_id;
  if not found or exists(select 1 from public.requests where household_id=v_household
      and linked_task_instance_id=v_task.id) then
    raise exception 'LINE_SAVED_TASK_NOT_CORRECTABLE';
  end if;
  return jsonb_build_object(
    'pending_action_id',v_pending.id,'task_id',v_task.id,'household_id',v_household,
    'title',v_task.title,'scheduled_date',v_task.scheduled_date,'due_at',v_task.due_at,
    'status',v_task.status,'revision',v_task.revision,'completion_mode',v_task.completion_mode,
    'can_reschedule',v_task.status in ('todo','in_progress'),
    'can_reopen',v_task.status='completed' and v_task.completion_mode='whole'
      and coalesce(v_task.actual_completed_by_id=p_actor_id,false)
      and v_task.scheduled_date between (now() at time zone 'Asia/Tokyo')::date-1
        and (now() at time zone 'Asia/Tokyo')::date);
end; $$;

create function public.server_tx_correct_line_saved_task_v1(
  p_actor_id uuid, p_operation_id uuid, p_pending_action_id uuid,
  p_expected_revision bigint, p_action text, p_new_due_at timestamptz default null
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare
  v_context jsonb;
  v_household uuid;
  v_read jsonb;
  v_task public.task_instances%rowtype;
  v_receipt private.mutation_receipts%rowtype;
  v_hash text;
  v_result jsonb;
  v_child uuid;
  v_due time;
  v_end time;
  v_date date;
  v_new_end timestamptz;
begin
  if p_actor_id is null or p_operation_id is null or p_pending_action_id is null
    or p_expected_revision is null or p_expected_revision<1
    or p_action not in ('reschedule','reopen')
    or (p_action='reschedule' and (p_new_due_at is null or not isfinite(p_new_due_at)))
    or (p_action='reopen' and p_new_due_at is not null) then raise exception 'INVALID_INPUT'; end if;
  v_context:=private.fn_require_production_actor_context_v1(p_actor_id);
  v_household:=(v_context->>'household_id')::uuid;
  -- Even receipt replay is scoped to the actor's current household/provenance.
  if not exists(select 1 from private.pending_actions where id=p_pending_action_id
    and household_id=v_household and actor_id=p_actor_id and source='line'
    and status='succeeded' and action_type='task_create_once') then
    raise exception 'LINE_SAVED_TASK_NOT_CORRECTABLE';
  end if;
  v_hash:=encode(sha256(convert_to(jsonb_build_object('pending',p_pending_action_id,
    'revision',p_expected_revision,'action',p_action,'due',p_new_due_at)::text,'UTF8')),'hex');
  loop
    insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash,actor_ref_id)
      values(p_actor_id,p_operation_id,'line-saved-task-correction',v_hash,(v_context->>'actor_ref_id')::uuid)
      on conflict(actor_id,operation_id) do nothing;
    if found then exit; end if;
    select * into v_receipt from private.mutation_receipts
      where actor_id=p_actor_id and operation_id=p_operation_id for update;
    if found then
      if v_receipt.action_type<>'line-saved-task-correction' or v_receipt.request_hash<>v_hash
        then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
      if v_receipt.result_payload is null then raise exception 'IDEMPOTENCY_INCOMPLETE'; end if;
      if v_receipt.result_payload->>'household_id'<>v_household::text
        then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
      return v_receipt.result_payload;
    end if;
  end loop;
  v_read:=public.server_read_line_saved_task_v1(p_actor_id,p_pending_action_id);
  select * into v_task from public.task_instances
    where household_id=v_household and id=(v_read->>'task_id')::uuid for update;
  if not found or v_task.revision<>p_expected_revision then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  -- Re-read permissions under the task lock so a completion by the other adult
  -- cannot be erased between the preview read and this command.
  v_read:=public.server_read_line_saved_task_v1(p_actor_id,p_pending_action_id);
  v_child:=(md5(p_operation_id::text||':saved-task-command'))::uuid;
  if p_action='reopen' then
    if not (v_read->>'can_reopen')::boolean then raise exception 'LINE_SAVED_TASK_NOT_CORRECTABLE'; end if;
    v_result:=public.server_tx_reopen_task(p_actor_id,v_child,v_task.id,p_expected_revision,'line');
  else
    if not (v_read->>'can_reschedule')::boolean then raise exception 'LINE_SAVED_TASK_NOT_CORRECTABLE'; end if;
    v_date:=(p_new_due_at at time zone 'Asia/Tokyo')::date;
    v_due:=(p_new_due_at at time zone 'Asia/Tokyo')::time;
    if v_date<(now() at time zone 'Asia/Tokyo')::date-1 then raise exception 'INVALID_INPUT'; end if;
    -- Keep an explicit duration. An overnight calendar change requires the
    -- richer calendar editor; never silently drop the saved end time.
    if v_task.calendar_ends_at is not null then
      if v_task.due_at is null then raise exception 'LINE_SAVED_TASK_NEEDS_DETAIL'; end if;
      v_new_end:=p_new_due_at+(v_task.calendar_ends_at-v_task.due_at);
      if (v_new_end at time zone 'Asia/Tokyo')::date<>v_date
        or v_new_end<=p_new_due_at then raise exception 'LINE_SAVED_TASK_NEEDS_DETAIL'; end if;
      v_end:=(v_new_end at time zone 'Asia/Tokyo')::time;
    end if;
    perform public.server_tx_edit_task_with_calendar(p_actor_id,v_child,v_task.id,
      v_task.title,v_date,v_due,v_end,v_task.category,v_task.planned_assignee_id,v_task.calendar_visibility);
    -- The shared legacy editor has no channel argument. Correct only this
    -- transaction's uniquely keyed event; keep its single writer and outbox.
    update public.task_events set source='line'
      where household_id=v_household and task_instance_id=v_task.id
        and idempotency_key=v_child::text||':edited' and actor_id=p_actor_id;
    -- The legacy editor predates revision CAS. This scoped adapter owns the
    -- revision boundary while preserving its calendar/outbox writer behavior.
    update public.task_instances set revision=revision+1
      where household_id=v_household and id=v_task.id and revision=p_expected_revision;
    v_result:=jsonb_build_object('task_id',v_task.id);
  end if;
  select * into v_task from public.task_instances where household_id=v_household and id=v_task.id;
  v_result:=v_result||jsonb_build_object('ok',true,'household_id',v_household,
    'pending_action_id',p_pending_action_id,'title',v_task.title,'task_id',v_task.id,
    'scheduled_date',v_task.scheduled_date,'due_at',v_task.due_at,'status',v_task.status,
    'revision',v_task.revision,'action',p_action);
  update private.mutation_receipts set result_type='task_instance',result_id=v_task.id,result_payload=v_result
    where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end; $$;

revoke all on function public.server_read_line_saved_task_v1(uuid,uuid) from public,anon,authenticated;
revoke all on function public.server_tx_correct_line_saved_task_v1(uuid,uuid,uuid,bigint,text,timestamptz) from public,anon,authenticated;
grant execute on function public.server_read_line_saved_task_v1(uuid,uuid) to service_role;
grant execute on function public.server_tx_correct_line_saved_task_v1(uuid,uuid,uuid,bigint,text,timestamptz) to service_role;
