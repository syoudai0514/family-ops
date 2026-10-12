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

-- Replace untouched occurrences without destroying recorded actions or failing
-- on a LINE session's foreign key. Referenced snapshots are retained as cancelled
-- history; their occurrence key is released so the new schedule can materialize.
create or replace function private.retire_pending_recurrence_occurrences(
  p_household_id uuid, p_rule_id uuid, p_from_date date
) returns void language plpgsql security invoker set search_path='' as $$
declare v_task record;
begin
  for v_task in
    select ti.id from public.task_instances ti
    where ti.household_id=p_household_id and ti.recurrence_rule_id=p_rule_id
      and ti.scheduled_date>=p_from_date and ti.status='todo'
      and ti.test_context_id is null and ti.active_claimant_actor_ref_id is null
      and not exists(select 1 from public.task_events e where e.household_id=ti.household_id and e.task_instance_id=ti.id
        and not (e.source='routine_editor' and coalesce(e.payload->>'reason','') in ('routine_definition_paused','routine_definition_restarted')))
      and not exists(select 1 from public.task_subtask_instances s where s.household_id=ti.household_id and s.task_instance_id=ti.id and s.is_completed)
    order by ti.id for update of ti
  loop
    -- Recheck under the acquired row lock. A subtask may have been completed
    -- while this query was waiting for a concurrent user mutation to commit.
    if exists(select 1 from public.task_events e where e.household_id=p_household_id and e.task_instance_id=v_task.id
      and not (e.source='routine_editor' and coalesce(e.payload->>'reason','') in ('routine_definition_paused','routine_definition_restarted')))
      or exists(select 1 from public.task_subtask_instances s where s.household_id=p_household_id and s.task_instance_id=v_task.id and s.is_completed) then
      continue;
    end if;
    begin
      delete from public.task_instances where household_id=p_household_id and id=v_task.id;
    exception when foreign_key_violation then
      update public.task_instances
      set status='cancelled', logical_occurrence_key=null, attention_state='active', revision=revision+1,
          source_context=source_context||jsonb_build_object('recurrence_schedule_replaced',true)
      where household_id=p_household_id and id=v_task.id;
    end;
  end loop;
end $$;
revoke all on function private.retire_pending_recurrence_occurrences(uuid,uuid,date) from public,anon,authenticated;
grant execute on function private.retire_pending_recurrence_occurrences(uuid,uuid,date) to service_role;

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
  if p_assignee_strategy in ('unassigned','anyone_adult','previous_evening_assignee','next_day_nondropoff_adult')
     and p_planned_assignee_user_id is not null then
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

  if (v_task.task_kind='transport' or v_task.code in ('dropoff','pickup'))
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

    perform private.retire_pending_recurrence_occurrences(v_household_id,v_existing_rule.id,v_today);
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

revoke all on function public.server_tx_change_recurrence(uuid,uuid,uuid,int,text,text,uuid,time,int,date) from public,anon,authenticated;
grant execute on function public.server_tx_change_recurrence(uuid,uuid,uuid,int,text,text,uuid,time,int,date) to service_role;

-- Explicit recurrence disable: preserves completed history and removes only future todo work.
create or replace function public.server_tx_deactivate_recurrence(
  p_actor_id uuid, p_operation_id uuid, p_task_definition_id uuid, p_weekday int, p_slot_key text default null
) returns jsonb language plpgsql security invoker set search_path = '' as $$
declare v_household uuid; v_rule public.recurrence_rules%rowtype; v_today date := (now() at time zone 'Asia/Tokyo')::date; v_hash text; v_receipt record; v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_task_definition_id is null or p_weekday is null or p_weekday not between 1 and 7 then raise exception 'INVALID_INPUT'; end if;
  v_hash := encode(sha256(convert_to('deactivate-recurrence|'||p_task_definition_id||'|'||p_weekday||'|'||coalesce(p_slot_key,'default'),'UTF8')),'hex');
  insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash) values(p_actor_id,p_operation_id,'deactivate-recurrence',v_hash) on conflict(actor_id,operation_id) do nothing;
  if not found then select * into v_receipt from private.mutation_receipts where actor_id=p_actor_id and operation_id=p_operation_id; if v_receipt.request_hash<>v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if; return v_receipt.result_payload; end if;
  select household_id into v_household from public.household_members where user_id=p_actor_id; if v_household is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  if not exists(select 1 from public.task_definitions where id=p_task_definition_id and household_id=v_household) then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  select * into v_rule from public.recurrence_rules where household_id=v_household and task_definition_id=p_task_definition_id and weekday=p_weekday and slot_key=coalesce(nullif(btrim(p_slot_key),''),'default') and active order by version desc limit 1;
  if found then update public.recurrence_rules set active=false,effective_to=greatest(v_today-1,v_rule.effective_from) where id=v_rule.id; perform private.retire_pending_recurrence_occurrences(v_household,v_rule.id,v_today); end if;
  v_result:=jsonb_build_object('deactivated',true,'task_definition_id',p_task_definition_id,'weekday',p_weekday); update private.mutation_receipts set result_type='recurrence_rule',result_id=coalesce(v_rule.id,p_task_definition_id),result_payload=v_result where actor_id=p_actor_id and operation_id=p_operation_id; return v_result;
end $$;
revoke all on function public.server_tx_deactivate_recurrence(uuid,uuid,uuid,int,text) from public,anon,authenticated;
grant execute on function public.server_tx_deactivate_recurrence(uuid,uuid,uuid,int,text) to service_role;

-- A routine rename also follows untouched materialized occurrences. Recorded
-- work and an individually renamed occurrence retain their own titles.
create or replace function public.server_tx_edit_task_definition(
  p_actor_id uuid,p_operation_id uuid,p_task_definition_id uuid,p_title text,
  p_category text,p_routine_phase text,p_completion_mode text,p_sort_order int
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare
  v_household uuid; v_hash text; v_receipt record; v_result jsonb;
  v_definition public.task_definitions%rowtype; v_instance record;
  v_today date := (now() at time zone 'Asia/Tokyo')::date;
begin
  if p_actor_id is null or p_operation_id is null or p_task_definition_id is null
    or (p_routine_phase is not null and p_routine_phase not in ('morning','evening','anytime'))
    or (p_completion_mode is not null and p_completion_mode not in ('whole','subtasks')) then
    raise exception 'INVALID_INPUT';
  end if;
  v_hash:=encode(sha256(convert_to('edit-task-definition|'||p_task_definition_id::text||'|'||coalesce(p_title,'')||'|'
    ||coalesce(p_category,'')||'|'||coalesce(p_routine_phase,'')||'|'||coalesce(p_completion_mode,'')||'|'||coalesce(p_sort_order::text,''),'UTF8')),'hex');
  insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash)
    values(p_actor_id,p_operation_id,'edit-task-definition',v_hash) on conflict(actor_id,operation_id) do nothing;
  if not found then
    select * into v_receipt from private.mutation_receipts where actor_id=p_actor_id and operation_id=p_operation_id for update;
    if v_receipt.request_hash<>v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    return v_receipt.result_payload;
  end if;
  select household_id into v_household from public.household_members where user_id=p_actor_id;
  if v_household is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  select * into v_definition from public.task_definitions where household_id=v_household and id=p_task_definition_id for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  update public.task_definitions
    set title=coalesce(nullif(btrim(p_title),''),title),category=coalesce(nullif(btrim(p_category),''),category),
      routine_phase=coalesce(p_routine_phase,routine_phase),completion_mode=coalesce(p_completion_mode,completion_mode),
      sort_order=coalesce(p_sort_order,sort_order)
    where household_id=v_household and id=p_task_definition_id;
  if nullif(btrim(p_title),'') is not null and btrim(p_title)<>v_definition.title
    and v_definition.task_kind<>'transport' and v_definition.code not in ('dropoff','pickup') then
    for v_instance in
      select ti.id from public.task_instances ti
      where ti.household_id=v_household and ti.task_definition_id=p_task_definition_id
        and ti.scheduled_date>=v_today and ti.test_context_id is null
        and (ti.status='todo' or (ti.status='cancelled' and ti.source_context ? 'routine_definition_pause'))
      order by ti.id for update of ti
    loop
    update public.task_instances ti set title=btrim(p_title),revision=revision+1
    where ti.household_id=v_household and ti.id=v_instance.id
      and ti.scheduled_date>=v_today and ti.test_context_id is null and ti.title=v_definition.title
      and (ti.status='todo' or (ti.status='cancelled' and ti.source_context ? 'routine_definition_pause'))
      and ti.active_claimant_actor_ref_id is null
      and ti.source_context->'routine_definition_pause'->>'active_claimant_actor_ref_id' is null
      and not exists(select 1 from public.task_events e where e.household_id=ti.household_id and e.task_instance_id=ti.id
        and not (e.source='routine_editor' and coalesce(e.payload->>'reason','') in ('routine_definition_paused','routine_definition_restarted')))
      and not exists(select 1 from public.task_subtask_instances s where s.household_id=ti.household_id and s.task_instance_id=ti.id and s.is_completed);
    end loop;
  end if;
  v_result:=jsonb_build_object('ok',true);
  update private.mutation_receipts set result_type='task_definition',result_id=p_task_definition_id,result_payload=v_result
    where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end $$;
revoke all on function public.server_tx_edit_task_definition(uuid,uuid,uuid,text,text,text,text,int) from public,anon,authenticated;
grant execute on function public.server_tx_edit_task_definition(uuid,uuid,uuid,text,text,text,text,int) to service_role;

-- 2. Checklist items of any routine except a transport leg (was: app-added routines only).
create or replace function public.server_tx_replace_routine_subtasks(
  p_actor_id uuid,p_operation_id uuid,p_task_definition_id uuid,p_subtasks jsonb
) returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  v_household uuid; v_hash text; v_receipt record; v_result jsonb; v_subtask jsonb;
  v_existing_id uuid; v_seen_ids uuid[] := '{}'; v_count integer := 0;
  v_code text; v_task_kind text; v_instance record; v_definition record;
  v_today date := (now() at time zone 'Asia/Tokyo')::date;
begin
  if p_actor_id is null or p_operation_id is null or p_task_definition_id is null
     or jsonb_typeof(p_subtasks) is distinct from 'array' then raise exception 'INVALID_INPUT'; end if;
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
    if jsonb_typeof(v_subtask) is distinct from 'object'
       or jsonb_typeof(v_subtask->'title') is distinct from 'string'
       or coalesce(btrim(v_subtask->>'title'),'')=''
       or length(btrim(v_subtask->>'title'))>240
       or (v_subtask ? 'required' and jsonb_typeof(v_subtask->'required') is distinct from 'boolean')
       or (v_subtask ? 'id' and jsonb_typeof(v_subtask->'id') not in ('string','null')) then
      raise exception 'INVALID_INPUT';
    end if;
    if v_subtask ? 'id' and nullif(v_subtask->>'id','') is not null then
      begin v_existing_id := (v_subtask->>'id')::uuid; exception when invalid_text_representation then raise exception 'INVALID_INPUT'; end;
      if v_existing_id=any(v_seen_ids) then raise exception 'INVALID_INPUT'; end if;
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

  -- Materialized tasks hold checklist snapshots. Update only untouched work,
  -- retaining its task and subtask IDs so open LINE sessions remain valid.
  -- A paused untouched occurrence follows the edit when it is restarted;
  -- completed checks, claims, and other recorded actions retain their snapshots.
  for v_instance in
    select ti.id from public.task_instances ti
    where ti.household_id=v_household and ti.task_definition_id=p_task_definition_id
      and ti.scheduled_date>=v_today and ti.test_context_id is null
      and (ti.status='todo' or (ti.status='cancelled' and ti.source_context ? 'routine_definition_pause'))
      and ti.active_claimant_actor_ref_id is null
      and ti.source_context->'routine_definition_pause'->>'active_claimant_actor_ref_id' is null
      and not exists(select 1 from public.task_events e
        where e.household_id=ti.household_id and e.task_instance_id=ti.id
          and not (e.source='routine_editor' and coalesce(e.payload->>'reason','') in ('routine_definition_paused','routine_definition_restarted')))
      and not exists(select 1 from public.task_subtask_instances s
        where s.household_id=ti.household_id and s.task_instance_id=ti.id and s.is_completed)
    order by ti.id for update of ti
  loop
    if exists(select 1 from public.task_events e where e.household_id=v_household and e.task_instance_id=v_instance.id
      and not (e.source='routine_editor' and coalesce(e.payload->>'reason','') in ('routine_definition_paused','routine_definition_restarted')))
      or exists(select 1 from public.task_subtask_instances s where s.household_id=v_household and s.task_instance_id=v_instance.id and s.is_completed) then
      continue;
    end if;
    delete from public.task_subtask_instances
    where household_id=v_household and task_instance_id=v_instance.id
      and (source_definition_id is null or not (source_definition_id=any(v_seen_ids)));
    for v_definition in
      select * from public.task_subtask_definitions
      where household_id=v_household and task_definition_id=p_task_definition_id and is_active
      order by sort_order,id
    loop
      update public.task_subtask_instances
      set title=v_definition.title,required=v_definition.required,sort_order=v_definition.sort_order
      where household_id=v_household and task_instance_id=v_instance.id and source_definition_id=v_definition.id;
      if not found then
        insert into public.task_subtask_instances(household_id,task_instance_id,source_definition_id,title,required,sort_order)
        values(v_household,v_instance.id,v_definition.id,v_definition.title,v_definition.required,v_definition.sort_order);
      end if;
    end loop;
    update public.task_instances
    set completion_mode=case when v_count>0 then 'subtasks' else 'whole' end,revision=revision+1
    where household_id=v_household and id=v_instance.id;
  end loop;
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
declare
  v_household uuid; v_receipt record; v_hash text; v_result jsonb;
  v_today date := (now() at time zone 'Asia/Tokyo')::date;
  v_task record; v_pause jsonb; v_rule record;
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
  if not p_include_in_routine_line then
    delete from public.routine_checkin_session_items si using public.routine_checkin_sessions s, public.task_instances ti
    where si.household_id=v_household and si.session_id=s.id and si.task_instance_id=ti.id and ti.task_definition_id=p_task_definition_id and s.status='open' and s.scheduled_date>=v_today;
  end if;
  if not p_enabled then
    -- is_active on the definition is the pause gate. Keep the exact active
    -- weekday set, including its times and date boundaries, for a later restart.
    -- Cancellation preserves referenced LINE snapshots and recorded actions;
    -- deleting these rows would fail their foreign keys or erase user work.
    for v_task in
      select * from public.task_instances
      where household_id=v_household and task_definition_id=p_task_definition_id
        and scheduled_date>=v_today and status='todo' and test_context_id is null
      order by id for update
    loop
      update public.task_instances
      set source_context=source_context||jsonb_build_object('routine_definition_pause',jsonb_build_object(
            'logical_occurrence_key',v_task.logical_occurrence_key,
            'active_claimant_actor_ref_id',v_task.active_claimant_actor_ref_id,
            'claimed_at',v_task.claimed_at,'attention_state',v_task.attention_state)),
          status='cancelled',logical_occurrence_key=null,
          active_claimant_actor_ref_id=null,claimed_at=null,attention_state='active',revision=revision+1
      where household_id=v_household and id=v_task.id;
      insert into public.task_events(household_id,task_instance_id,actor_id,event_type,payload,source,idempotency_key)
      values(v_household,v_task.id,p_actor_id,'edited',jsonb_build_object('reason','routine_definition_paused'),
             'routine_editor','routine-pause:'||p_operation_id::text||':'||v_task.id::text);
    end loop;
  else
    -- Restore the same occurrence when its schedule is unchanged. If the user
    -- edited a stopped routine, keep the old cancelled snapshot and materialize
    -- the replacement rule instead; never resurrect a removed weekday.
    for v_task in
      select ti.* from public.task_instances ti
      where ti.household_id=v_household and ti.task_definition_id=p_task_definition_id
        and ti.scheduled_date>=v_today and ti.status='cancelled' and ti.test_context_id is null
        and ti.source_context ? 'routine_definition_pause'
      order by ti.id for update of ti
    loop
      v_pause:=v_task.source_context->'routine_definition_pause';
      if (v_task.recurrence_rule_id is null or exists(
        select 1 from public.recurrence_rules rr
        where rr.household_id=v_household and rr.id=v_task.recurrence_rule_id and rr.active
          and rr.weekday=extract(isodow from v_task.scheduled_date)::int
          and rr.effective_from<=v_task.scheduled_date
          and (rr.effective_to is null or rr.effective_to>=v_task.scheduled_date)
      )) and not exists(
        select 1 from public.task_instances ti
        where ti.household_id=v_household and ti.id<>v_task.id
          and ti.logical_occurrence_key=v_pause->>'logical_occurrence_key'
      ) then
        update public.task_instances
        set status='todo',logical_occurrence_key=v_pause->>'logical_occurrence_key',
            active_claimant_actor_ref_id=nullif(v_pause->>'active_claimant_actor_ref_id','')::uuid,
            claimed_at=nullif(v_pause->>'claimed_at','')::timestamptz,
            attention_state=coalesce(v_pause->>'attention_state','active'),
            source_context=source_context-'routine_definition_pause',revision=revision+1
        where household_id=v_household and id=v_task.id;
        insert into public.task_events(household_id,task_instance_id,actor_id,event_type,payload,source,idempotency_key)
        values(v_household,v_task.id,p_actor_id,'edited',jsonb_build_object('reason','routine_definition_restarted'),
               'routine_editor','routine-restart:'||p_operation_id::text||':'||v_task.id::text);
      else
        update public.task_instances set source_context=source_context-'routine_definition_pause'
        where household_id=v_household and id=v_task.id;
      end if;
    end loop;
    for v_rule in
      select id from public.recurrence_rules
      where household_id=v_household and task_definition_id=p_task_definition_id and active
      order by id
    loop
      perform private.materialize_recurrence_rule(v_household,v_rule.id,v_today,v_today+14);
    end loop;
  end if;
  if p_default_expectation is not null then
    update public.task_instances
    set expectation=case when p_default_expectation='optional' then 'optional' else null end,
        revision=revision+1
    where household_id=v_household and task_definition_id=p_task_definition_id and scheduled_date>=v_today and status='todo'
      and case when p_default_expectation='optional' then expectation is distinct from 'optional' else expectation='optional' end;
  end if;
  v_result:=jsonb_build_object('ok',true); update private.mutation_receipts set result_payload=v_result,result_type='task_definition',result_id=p_task_definition_id where actor_id=p_actor_id and operation_id=p_operation_id; return v_result;
end $$;
revoke all on function public.server_tx_set_routine_definition_options(uuid,uuid,uuid,boolean,boolean,text) from public,anon,authenticated;
grant execute on function public.server_tx_set_routine_definition_options(uuid,uuid,uuid,boolean,boolean,text) to service_role;
