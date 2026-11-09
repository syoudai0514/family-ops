-- A daily-input card names one production task revision. Canonical completion
-- remains the only writer; this adapter adds the displayed day/revision guard
-- and a receipt that survives both stale cards and the recent-day boundary.
create function public.server_tx_complete_line_daily_task_v1(
  p_actor_id uuid, p_operation_id uuid, p_task_id uuid,
  p_expected_revision bigint, p_day date, p_codmon_sent boolean default false
) returns jsonb
language plpgsql security invoker set search_path='' as $$
declare
  v_context jsonb;
  v_household uuid;
  v_actor_ref uuid;
  v_receipt private.mutation_receipts%rowtype;
  v_hash text;
  v_peek public.task_instances%rowtype;
  v_task public.task_instances%rowtype;
  v_code text;
  v_partner_codes text[];
  v_child uuid;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_task_id is null
    or p_expected_revision is null or p_expected_revision<1
    or p_day is null or not isfinite(p_day) or p_codmon_sent is null then
    raise exception 'INVALID_INPUT';
  end if;
  v_context:=private.fn_require_production_actor_context_v1(p_actor_id);
  v_household:=(v_context->>'household_id')::uuid;
  v_actor_ref:=(v_context->>'actor_ref_id')::uuid;
  v_hash:=encode(sha256(convert_to(jsonb_build_object('task',p_task_id,
    'revision',p_expected_revision,'day',p_day,'codmon_sent',p_codmon_sent)::text,'UTF8')),'hex');
  loop
    insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash,actor_ref_id)
      values(p_actor_id,p_operation_id,'line-daily-task-completion',v_hash,v_actor_ref)
      on conflict(actor_id,operation_id) do nothing;
    if found then exit; end if;
    select * into v_receipt from private.mutation_receipts
      where actor_id=p_actor_id and operation_id=p_operation_id for update;
    if found then
      if v_receipt.action_type<>'line-daily-task-completion' or v_receipt.request_hash<>v_hash
        then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
      if v_receipt.result_payload is null then raise exception 'IDEMPOTENCY_INCOMPLETE'; end if;
      if v_receipt.test_context_id is not null or v_receipt.actor_ref_id is distinct from v_actor_ref
        or v_receipt.result_payload->>'household_id' is distinct from v_household::text then
        raise exception 'CROSS_HOUSEHOLD_RESOURCE';
      end if;
      return v_receipt.result_payload;
    end if;
  end loop;
  if p_day not in ((now() at time zone 'Asia/Tokyo')::date,
    (now() at time zone 'Asia/Tokyo')::date-1) then raise exception 'LINE_DAILY_TASK_DAY_STALE'; end if;
  select * into v_peek from public.task_instances
    where household_id=v_household and id=p_task_id;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if v_peek.test_context_id is not null then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
  select td.code into v_code from public.task_definitions td
    where td.household_id=v_household and td.id=v_peek.task_definition_id;
  if v_code='codmon_submit' then
    if not p_codmon_sent then raise exception 'CODMON_SEND_CONFIRMATION_REQUIRED'; end if;
    -- Existing acknowledgement closes inputs in this order, then submit. Never
    -- hold submit while waiting for its inputs: concurrent acknowledgement
    -- through an existing LINE/PWA entry point follows inputs -> submit too.
    perform 1 from public.task_instances ti join public.task_definitions td
      on td.household_id=ti.household_id and td.id=ti.task_definition_id
      where ti.household_id=v_household and ti.scheduled_date=p_day
        and ti.test_context_id is null and td.code in ('codmon_masaki_pickup_input',
          'codmon_shino_previous_input','codmon_shino_breakfast_input','codmon_shino_pickup_input')
      order by case td.code when 'codmon_masaki_pickup_input' then 1
        when 'codmon_shino_previous_input' then 2 when 'codmon_shino_breakfast_input' then 3 else 4 end,ti.id
      for update of ti;
  elsif p_codmon_sent then raise exception 'INVALID_INPUT';
  end if;
  select * into v_task from public.task_instances
    where household_id=v_household and id=p_task_id for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if v_task.test_context_id is not null then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
  if v_task.revision<>p_expected_revision or v_task.scheduled_date<>p_day
    or v_task.task_definition_id is distinct from v_peek.task_definition_id then
    raise exception 'AGGREGATE_REVISION_CONFLICT';
  end if;
  if v_task.status not in ('todo','in_progress') then raise exception 'TASK_TERMINAL'; end if;
  if v_code is distinct from 'codmon_submit' and (
    v_task.planned_assignee_id is null or v_task.planned_assignee_id=p_actor_id
    or v_task.actual_completed_by_id=p_actor_id or v_task.assignment_mode='anyone'
  ) is not true then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
  v_child:=md5(p_operation_id::text||':line-daily-completion')::uuid;
  if v_code='codmon_submit' then
    select array_agg(distinct td.code) into v_partner_codes
      from public.task_instances ti join public.task_definitions td
        on td.household_id=ti.household_id and td.id=ti.task_definition_id
      where ti.household_id=v_household and ti.scheduled_date=p_day and ti.test_context_id is null
        and ti.status in ('todo','in_progress') and ti.planned_assignee_id<>p_actor_id
        and td.code in ('codmon_masaki_pickup_input','codmon_shino_previous_input',
          'codmon_shino_breakfast_input','codmon_shino_pickup_input');
    v_result:=public.server_tx_acknowledge_codmon_submission_v1(
      p_actor_id,v_child,p_task_id,'line',v_partner_codes);
  else
    v_result:=public.server_tx_complete_task(p_actor_id,v_child,p_task_id,'self',true,'line');
  end if;
  select * into v_task from public.task_instances where household_id=v_household and id=p_task_id;
  v_result:=v_result||jsonb_build_object('ok',true,'household_id',v_household,'task_id',p_task_id,
    'title',v_task.title,'scheduled_date',v_task.scheduled_date,'status',v_task.status,
    'revision',v_task.revision,'completion_mode',v_task.completion_mode,'codmon_sent',coalesce(v_code='codmon_submit',false));
  update private.mutation_receipts set result_type='task_instance',result_id=p_task_id,result_payload=v_result
    where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end; $$;
revoke all on function public.server_tx_complete_line_daily_task_v1(uuid,uuid,uuid,bigint,date,boolean)
  from public,anon,authenticated;
grant execute on function public.server_tx_complete_line_daily_task_v1(uuid,uuid,uuid,bigint,date,boolean)
  to service_role;

-- The corresponding failure correction has the same date, actor and receipt
-- boundary. A forged 'today' label must not reopen an old or unrelated row.
create function public.server_tx_undo_line_daily_failure_v1(
  p_actor_id uuid, p_operation_id uuid, p_task_id uuid,
  p_expected_revision bigint, p_day date
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare
  c jsonb; h uuid; actor_ref uuid; task public.task_instances%rowtype;
  receipt private.mutation_receipts%rowtype; hash text; result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_task_id is null
    or p_expected_revision is null or p_expected_revision<1
    or p_day is null or not isfinite(p_day) then raise exception 'INVALID_INPUT'; end if;
  c:=private.fn_require_production_actor_context_v1(p_actor_id);
  h:=(c->>'household_id')::uuid; actor_ref:=(c->>'actor_ref_id')::uuid;
  hash:=encode(sha256(convert_to(jsonb_build_object('task',p_task_id,
    'revision',p_expected_revision,'day',p_day)::text,'UTF8')),'hex');
  loop
    insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash,actor_ref_id)
      values(p_actor_id,p_operation_id,'line-daily-failure-undo',hash,actor_ref)
      on conflict(actor_id,operation_id) do nothing;
    if found then exit; end if;
    select * into receipt from private.mutation_receipts where actor_id=p_actor_id and operation_id=p_operation_id for update;
    if found then
      if receipt.action_type<>'line-daily-failure-undo' or receipt.request_hash<>hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
      if receipt.result_payload is null then raise exception 'IDEMPOTENCY_INCOMPLETE'; end if;
      if receipt.actor_ref_id is distinct from actor_ref or receipt.test_context_id is not null
        or receipt.result_payload->>'household_id' is distinct from h::text then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
      return receipt.result_payload;
    end if;
  end loop;
  if p_day not in ((now() at time zone 'Asia/Tokyo')::date,(now() at time zone 'Asia/Tokyo')::date-1)
    then raise exception 'LINE_DAILY_TASK_DAY_STALE'; end if;
  select * into task from public.task_instances where household_id=h and id=p_task_id for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if task.test_context_id is not null then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
  if task.revision<>p_expected_revision or task.scheduled_date<>p_day then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  if (task.planned_assignee_id is null or task.planned_assignee_id=p_actor_id
    or task.actual_completed_by_id=p_actor_id or task.assignment_mode='anyone') is not true then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
  result:=public.server_tx_mark_task_could_not_do_v1(p_actor_id,
    md5(p_operation_id::text||':line-daily-undo')::uuid,p_task_id,true,'line',p_expected_revision);
  result:=result||jsonb_build_object('household_id',h,'task_id',p_task_id,'scheduled_date',p_day);
  update private.mutation_receipts set result_type='task_instance',result_id=p_task_id,result_payload=result
    where actor_id=p_actor_id and operation_id=p_operation_id;
  return result;
end; $$;
revoke all on function public.server_tx_undo_line_daily_failure_v1(uuid,uuid,uuid,bigint,date) from public,anon,authenticated;
grant execute on function public.server_tx_undo_line_daily_failure_v1(uuid,uuid,uuid,bigint,date) to service_role;
