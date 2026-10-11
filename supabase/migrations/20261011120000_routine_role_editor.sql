-- Owner instruction 2026-10-10/11: change a routine (定例) in the app, grouped by who does it
-- (送りの人・迎えの人・迎えない人・誰でもOK・固定…), without asking an AI or a developer.
--
-- Until now the app could only save four of the assignment rules the household actually uses.
-- 「誰でもOK」(anyone_adult), 「前の晩の担当」(previous_evening_assignee) and
-- 「翌朝送らない人」(next_day_nondropoff_adult) were set by hand in SQL, the checklist of a
-- built-in routine (夕食対応, 洗濯…) could not be edited, and only morning/evening chores could
-- be stopped. This opens the same mutations to every routine except the transport legs
-- (送り・お迎え), which keep their own editor.

-- 1. The three rules already resolved by materialize_recurrence_rule can be chosen in the app.
--    Transport legs still cannot depend on a transport role.

create or replace function public.server_tx_change_recurrence(
  p_actor_id uuid,
  p_operation_id uuid,
  p_task_definition_id uuid,
  p_weekday integer,
  p_slot_key text,
  p_assignee_strategy text,
  p_planned_assignee_user_id uuid,
  p_scheduled_local_time time without time zone,
  p_conflict_window_minutes integer,
  p_effective_from date
)
returns jsonb
language plpgsql
set search_path=''
as $$
declare
  v_today date:=(now() at time zone 'Asia/Tokyo')::date;
  v_slot_key text:=coalesce(nullif(btrim(p_slot_key),''),'default');
  v_conflict_window int:=coalesce(p_conflict_window_minutes,60);
  v_effective_from date:=coalesce(p_effective_from,v_today);
  v_request_hash text;
  v_receipt record;
  v_household_id uuid;
  v_task public.task_definitions%rowtype;
  v_existing_rule public.recurrence_rules%rowtype;
  v_rule_id uuid;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null
     or p_task_definition_id is null or p_weekday is null then
    raise exception 'INVALID_INPUT';
  end if;
  if p_weekday not between 1 and 7 then raise exception 'INVALID_INPUT'; end if;
  if p_assignee_strategy is null
     or p_assignee_strategy not in ('fixed','dropoff_assignee','pickup_assignee','nonpickup_adult','unassigned',
                                    'anyone_adult','previous_evening_assignee','next_day_nondropoff_adult') then
    raise exception 'INVALID_INPUT';
  end if;
  if p_assignee_strategy='fixed' and p_planned_assignee_user_id is null then
    raise exception 'INVALID_INPUT';
  end if;
  if p_assignee_strategy='unassigned' and p_planned_assignee_user_id is not null then
    raise exception 'INVALID_INPUT';
  end if;
  if v_conflict_window<0 or v_conflict_window>720 then raise exception 'INVALID_INPUT'; end if;
  if v_effective_from<v_today then raise exception 'INVALID_INPUT'; end if;

  v_request_hash:=encode(sha256(convert_to(
    'change-recurrence|'||p_task_definition_id::text||'|'||p_weekday::text||'|'||v_slot_key
    ||'|'||p_assignee_strategy||'|'||coalesce(p_planned_assignee_user_id::text,'')
    ||'|'||coalesce(p_scheduled_local_time::text,'')||'|'||v_conflict_window::text
    ||'|'||v_effective_from::text,'UTF8')),'hex');

  loop
    insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash)
    values(p_actor_id,p_operation_id,'change-recurrence',v_request_hash)
    on conflict(actor_id,operation_id) do nothing;
    if found then exit; end if;

    select * into v_receipt
    from private.mutation_receipts
    where actor_id=p_actor_id and operation_id=p_operation_id
    for update;

    if found then
      if v_receipt.request_hash<>v_request_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
      return v_receipt.result_payload;
    end if;
  end loop;

  select household_id into v_household_id
  from public.household_members
  where user_id=p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;

  select * into v_task
  from public.task_definitions
  where household_id=v_household_id and id=p_task_definition_id;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;

  if v_task.code in ('dropoff','pickup')
     and p_assignee_strategy in ('dropoff_assignee','pickup_assignee','nonpickup_adult',
                                 'previous_evening_assignee','next_day_nondropoff_adult') then
    raise exception 'INVALID_INPUT';
  end if;

  if p_planned_assignee_user_id is not null and not exists(
    select 1 from public.household_members
    where household_id=v_household_id and user_id=p_planned_assignee_user_id
  ) then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  select * into v_existing_rule
  from public.recurrence_rules
  where household_id=v_household_id
    and task_definition_id=p_task_definition_id
    and weekday=p_weekday and slot_key=v_slot_key and active
  order by version desc
  limit 1;

  if found then
    update public.recurrence_rules
    set active=false,
        effective_to=greatest(v_today-1,v_existing_rule.effective_from)
    where id=v_existing_rule.id;

    delete from public.task_instances
    where household_id=v_household_id
      and recurrence_rule_id=v_existing_rule.id
      and scheduled_date>=v_today
      and status='todo';
  end if;

  begin
    insert into public.recurrence_rules(
      household_id,task_definition_id,weekday,slot_key,
      assignee_strategy,planned_assignee_id,fallback_assignee_id,
      scheduled_local_time,conflict_window_minutes,
      effective_from,active,version,supersedes_rule_id,created_by
    ) values(
      v_household_id,p_task_definition_id,p_weekday,v_slot_key,
      p_assignee_strategy,
      case when p_assignee_strategy='fixed' then p_planned_assignee_user_id else null end,
      case when p_assignee_strategy in ('dropoff_assignee','pickup_assignee','nonpickup_adult')
           then p_planned_assignee_user_id else null end,
      p_scheduled_local_time,v_conflict_window,
      v_effective_from,true,coalesce(v_existing_rule.version,0)+1,v_existing_rule.id,p_actor_id
    ) returning id into v_rule_id;
  exception
    when exclusion_violation then raise exception 'RECURRENCE_OVERLAP';
    when deadlock_detected then raise exception 'RECURRENCE_OVERLAP';
  end;

  perform private.materialize_recurrence_rule(v_household_id,v_rule_id,v_today,v_today+14);

  v_result:=jsonb_build_object(
    'rule_id',v_rule_id,
    'task_definition_id',p_task_definition_id,
    'weekday',p_weekday,
    'slot_key',v_slot_key,
    'assignee_strategy',p_assignee_strategy,
    'fallback_assignee_id',
      case when p_assignee_strategy in ('dropoff_assignee','pickup_assignee','nonpickup_adult')
           then p_planned_assignee_user_id else null end,
    'effective_from',v_effective_from
  );

  update private.mutation_receipts
  set result_type='recurrence_rule',result_id=v_rule_id,result_payload=v_result
  where actor_id=p_actor_id and operation_id=p_operation_id;

  return v_result;
end;
$$;

-- 2. Checklist items of any routine except a transport leg (was: app-added routines only).
create or replace function public.server_tx_replace_routine_subtasks(
  p_actor_id uuid,p_operation_id uuid,p_task_definition_id uuid,p_subtasks jsonb
) returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  v_household uuid; v_hash text; v_receipt record; v_result jsonb; v_subtask jsonb;
  v_existing_id uuid; v_seen_ids uuid[] := '{}'; v_count integer := 0;
  v_code text; v_task_kind text;
begin
  if p_actor_id is null or p_operation_id is null or p_task_definition_id is null
     or jsonb_typeof(p_subtasks) <> 'array' then raise exception 'INVALID_INPUT'; end if;
  select household_id into v_household from public.household_members where user_id=p_actor_id;
  if v_household is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  select code,task_kind into v_code,v_task_kind from public.task_definitions
  where household_id=v_household and id=p_task_definition_id for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if v_task_kind = 'transport' or v_code in ('dropoff','pickup') then
    raise exception 'INVALID_INPUT';
  end if;

  v_hash:=encode(sha256(convert_to(jsonb_build_object('definition',p_task_definition_id,'subtasks',p_subtasks)::text,'UTF8')),'hex');
  insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash)
  values(p_actor_id,p_operation_id,'replace-routine-subtasks-v2',v_hash)
  on conflict(actor_id,operation_id) do nothing;
  if not found then
    select * into v_receipt from private.mutation_receipts where actor_id=p_actor_id and operation_id=p_operation_id for update;
    if v_receipt.request_hash<>v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    return v_receipt.result_payload;
  end if;

  for v_subtask in select * from jsonb_array_elements(p_subtasks) loop
    if coalesce(btrim(v_subtask->>'title'),'')='' then raise exception 'INVALID_INPUT'; end if;
    if v_subtask ? 'id' and nullif(v_subtask->>'id','') is not null then
      begin v_existing_id := (v_subtask->>'id')::uuid; exception when invalid_text_representation then raise exception 'INVALID_INPUT'; end;
      update public.task_subtask_definitions
      set title=btrim(v_subtask->>'title'), required=coalesce((v_subtask->>'required')::boolean,true),
          sort_order=v_count, is_active=true
      where household_id=v_household and task_definition_id=p_task_definition_id and id=v_existing_id;
      if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
    else
      insert into public.task_subtask_definitions(household_id,task_definition_id,title,required,sort_order,is_active)
      values(v_household,p_task_definition_id,btrim(v_subtask->>'title'),coalesce((v_subtask->>'required')::boolean,true),v_count,true)
      returning id into v_existing_id;
    end if;
    v_seen_ids := array_append(v_seen_ids,v_existing_id);
    v_count := v_count + 1;
  end loop;
  update public.task_subtask_definitions d set is_active=false
  where d.household_id=v_household and d.task_definition_id=p_task_definition_id
    and not (d.id=any(v_seen_ids))
    and exists(select 1 from public.task_subtask_instances i where i.household_id=d.household_id and i.source_definition_id=d.id);
  delete from public.task_subtask_definitions d
  where d.household_id=v_household and d.task_definition_id=p_task_definition_id
    and not (d.id=any(v_seen_ids))
    and not exists(select 1 from public.task_subtask_instances i where i.household_id=d.household_id and i.source_definition_id=d.id);
  update public.task_definitions set completion_mode=case when v_count>0 then 'subtasks' else 'whole' end
  where household_id=v_household and id=p_task_definition_id;
  v_result:=jsonb_build_object('ok',true,'task_definition_id',p_task_definition_id,'subtask_count',v_count);
  update private.mutation_receipts set result_type='task_definition',result_id=p_task_definition_id,result_payload=v_result
  where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end $$;
revoke all on function public.server_tx_replace_routine_subtasks(uuid,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.server_tx_replace_routine_subtasks(uuid,uuid,uuid,jsonb) to service_role;

-- 3. Stop/restart any routine except a transport leg, and set 「余裕があれば」 (optional).
--    p_default_expectation: null leaves it as it is; 'optional' makes it 余裕があれば; 'required'
--    takes 余裕があれば off (a definition that was explicitly 'required' stays 'required').
--    Future open occurrences follow the new expectation, recorded ones keep theirs.
drop function if exists public.server_tx_set_routine_definition_options(uuid,uuid,uuid,boolean,boolean);
create or replace function public.server_tx_set_routine_definition_options(
  p_actor_id uuid,p_operation_id uuid,p_task_definition_id uuid,p_enabled boolean,p_include_in_routine_line boolean,
  p_default_expectation text default null
) returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_household uuid; v_receipt record; v_hash text; v_result jsonb; v_today date := (now() at time zone 'Asia/Tokyo')::date;
begin
  if p_actor_id is null or p_operation_id is null or p_task_definition_id is null or p_enabled is null or p_include_in_routine_line is null
     or (p_default_expectation is not null and p_default_expectation not in ('optional','required')) then
    raise exception 'INVALID_INPUT';
  end if;
  v_hash:=encode(sha256(convert_to(jsonb_strip_nulls(jsonb_build_object('definition',p_task_definition_id,'enabled',p_enabled,'line',p_include_in_routine_line,'expectation',p_default_expectation))::text,'UTF8')),'hex');
  insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash) values(p_actor_id,p_operation_id,'routine-definition-options-v1',v_hash) on conflict(actor_id,operation_id) do nothing;
  if not found then select * into v_receipt from private.mutation_receipts where actor_id=p_actor_id and operation_id=p_operation_id for update; if v_receipt.request_hash<>v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if; return v_receipt.result_payload; end if;
  select household_id into v_household from public.household_members where user_id=p_actor_id; if v_household is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  update public.task_definitions set is_active=p_enabled,include_in_routine_line=p_include_in_routine_line,
    default_expectation=case when p_default_expectation is null then default_expectation
                             when p_default_expectation='optional' then 'optional'
                             when default_expectation='optional' then null
                             else default_expectation end
  where id=p_task_definition_id and household_id=v_household and task_kind<>'transport' and code not in ('dropoff','pickup');
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if p_default_expectation is not null then
    update public.task_instances
    set expectation=case when p_default_expectation='optional' then 'optional' else null end
    where household_id=v_household and task_definition_id=p_task_definition_id and scheduled_date>=v_today and status='todo'
      and case when p_default_expectation='optional' then expectation is distinct from 'optional' else expectation='optional' end;
  end if;
  if not p_include_in_routine_line then
    delete from public.routine_checkin_session_items si using public.routine_checkin_sessions s, public.task_instances ti
    where si.household_id=v_household and si.session_id=s.id and si.task_instance_id=ti.id and ti.task_definition_id=p_task_definition_id and s.status='open' and s.scheduled_date>=v_today;
  end if;
  if not p_enabled then
    update public.recurrence_rules set active=false,
      -- A rule that started today ends on its first day (was today-1: a check violation).
      effective_to=case when effective_from<=v_today then greatest(v_today-1,effective_from) else effective_to end
    where household_id=v_household and task_definition_id=p_task_definition_id and active;
    delete from public.task_instances where household_id=v_household and task_definition_id=p_task_definition_id and scheduled_date>=v_today and status='todo';
  end if;
  v_result:=jsonb_build_object('ok',true); update private.mutation_receipts set result_payload=v_result,result_type='task_definition',result_id=p_task_definition_id where actor_id=p_actor_id and operation_id=p_operation_id; return v_result;
end $$;
revoke all on function public.server_tx_set_routine_definition_options(uuid,uuid,uuid,boolean,boolean,text) from public,anon,authenticated;
grant execute on function public.server_tx_set_routine_definition_options(uuid,uuid,uuid,boolean,boolean,text) to service_role;
