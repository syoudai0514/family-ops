-- Household routine refinement + actionable next-day preparation handoff.
-- Forward-only. Historical completed task/subtask snapshots are never rewritten.

-- Optional-only checklist groups (for example laundry: do only the applicable
-- methods today) must not auto-complete after the first optional item. Required
-- checklists retain the existing auto-complete/reopen semantics.
create or replace function public.server_tx_set_subtask_completion(
  p_actor_id uuid,
  p_operation_id uuid,
  p_subtask_instance_id uuid,
  p_completed boolean,
  p_completion_actor text
) returns jsonb
language plpgsql
set search_path to ''
as $$
declare
  v_request_hash text;
  v_receipt record;
  v_household_id uuid;
  v_subtask record;
  v_task record;
  v_resolved_actor uuid;
  v_required_total int;
  v_remaining_required int;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_subtask_instance_id is null or p_completed is null then
    raise exception 'INVALID_INPUT';
  end if;
  if p_completion_actor not in ('self', 'partner') then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to(
      'set-subtask-completion|' || p_subtask_instance_id::text || '|' || p_completed::text
        || '|' || p_completion_actor,
      'UTF8'
    )),
    'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'set-subtask-completion', v_request_hash)
    on conflict (actor_id, operation_id) do nothing;

    if found then
      exit;
    end if;

    select * into v_receipt
    from private.mutation_receipts
    where actor_id = p_actor_id and operation_id = p_operation_id
    for update;

    if found then
      if v_receipt.request_hash <> v_request_hash then
        raise exception 'IDEMPOTENCY_CONFLICT';
      end if;
      return v_receipt.result_payload;
    end if;
  end loop;

  select household_id into v_household_id
  from public.household_members
  where user_id = p_actor_id;

  if v_household_id is null then
    raise exception 'NOT_HOUSEHOLD_MEMBER';
  end if;

  if p_completion_actor = 'self' then
    v_resolved_actor := p_actor_id;
  else
    select user_id into v_resolved_actor
    from public.household_members
    where household_id = v_household_id and user_id <> p_actor_id
    limit 1;
    if v_resolved_actor is null then
      raise exception 'INVALID_INPUT';
    end if;
  end if;

  select * into v_subtask
  from public.task_subtask_instances
  where household_id = v_household_id and id = p_subtask_instance_id
  for update;

  if not found then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  select * into v_task
  from public.task_instances
  where household_id = v_household_id and id = v_subtask.task_instance_id
  for update;

  if not found then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;
  if v_task.status not in ('todo', 'in_progress', 'completed') then
    raise exception 'TASK_TERMINAL';
  end if;

  if p_completed then
    update public.task_subtask_instances
    set is_completed = true, completed_by = v_resolved_actor, completed_at = now()
    where household_id = v_household_id and id = p_subtask_instance_id;
  else
    update public.task_subtask_instances
    set is_completed = false, completed_by = null, completed_at = null
    where household_id = v_household_id and id = p_subtask_instance_id;
  end if;

  select
    count(*) filter (where required),
    count(*) filter (where required and not is_completed)
  into v_required_total, v_remaining_required
  from public.task_subtask_instances
  where household_id = v_household_id and task_instance_id = v_task.id;

  if v_required_total > 0 and v_remaining_required = 0 and v_task.status <> 'completed' then
    update public.task_instances
    set status = 'completed', completed_at = now(), actual_completed_by_id = v_resolved_actor
    where household_id = v_household_id and id = v_task.id;
  elsif v_required_total > 0 and v_remaining_required > 0 and v_task.status = 'completed' then
    update public.task_instances
    set status = 'in_progress', completed_at = null, actual_completed_by_id = null
    where household_id = v_household_id and id = v_task.id;
  end if;

  insert into public.task_events
    (household_id, task_instance_id, actor_id, event_type, source, idempotency_key)
  values
    (v_household_id, v_task.id, p_actor_id, 'subtask_completed', 'pwa', p_operation_id::text || ':subtask');

  v_result := jsonb_build_object('ok', true);

  update private.mutation_receipts
  set result_type = 'task_subtask_instance', result_id = p_subtask_instance_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;
revoke all on function public.server_tx_set_subtask_completion(uuid,uuid,uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.server_tx_set_subtask_completion(uuid,uuid,uuid,boolean,text) to service_role;

-- One mutation for the pickup -> next morning handoff. It creates the actual
-- morning checklist task and the communication record together, so there is
-- no state where a message exists but the morning task was forgotten.
create or replace function public.server_tx_create_preparation_handoff(
  p_actor_id uuid,
  p_operation_id uuid,
  p_title text,
  p_scheduled_date date,
  p_planned_assignee_id uuid
) returns jsonb
language plpgsql
set search_path to ''
as $$
declare
  v_request_hash text;
  v_receipt record;
  v_household_id uuid;
  v_today date := (now() at time zone 'Asia/Tokyo')::date;
  v_task_id uuid;
  v_handover_id uuid;
  v_shared_text text;
  v_recipient record;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or coalesce(btrim(p_title), '') = '' or p_scheduled_date is null then
    raise exception 'INVALID_INPUT';
  end if;
  if p_scheduled_date < v_today or p_scheduled_date > v_today + 30 then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to(
      'preparation-handoff|' || btrim(p_title) || '|' || p_scheduled_date::text || '|'
        || coalesce(p_planned_assignee_id::text, ''),
      'UTF8'
    )),
    'hex'
  );

  loop
    insert into private.mutation_receipts(actor_id, operation_id, action_type, request_hash)
    values(p_actor_id, p_operation_id, 'create-preparation-handoff', v_request_hash)
    on conflict(actor_id, operation_id) do nothing;
    if found then exit; end if;

    select * into v_receipt
    from private.mutation_receipts
    where actor_id = p_actor_id and operation_id = p_operation_id
    for update;
    if found then
      if v_receipt.request_hash <> v_request_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
      return v_receipt.result_payload;
    end if;
  end loop;

  select household_id into v_household_id
  from public.household_members
  where user_id = p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;

  if p_planned_assignee_id is not null and not exists(
    select 1 from public.household_members
    where household_id = v_household_id and user_id = p_planned_assignee_id
  ) then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  insert into public.task_instances(
    household_id, task_definition_id, recurrence_rule_id, logical_occurrence_key,
    origin, title, category, routine_phase, scheduled_date, due_at,
    planned_assignee_id, completion_mode, status, source, created_by,
    calendar_visibility, calendar_ends_at, task_kind
  ) values (
    v_household_id, null, null, null,
    'manual', btrim(p_title), 'handover_preparation', 'morning', p_scheduled_date,
    ((p_scheduled_date + time '07:00') at time zone 'Asia/Tokyo'),
    p_planned_assignee_id, 'whole', 'todo', 'pwa', p_actor_id,
    'hidden', null, 'generic_once'
  ) returning id into v_task_id;

  v_shared_text := to_char(p_scheduled_date, 'MM/DD') || ' 朝：' || btrim(p_title);
  insert into public.handovers(household_id, author_id, shared_text, period, categories, occurred_on)
  values(v_household_id, p_actor_id, v_shared_text, 'morning', array['tomorrow_preparation'], v_today)
  returning id into v_handover_id;

  for v_recipient in
    select user_id
    from public.household_members
    where household_id = v_household_id
      and user_id <> p_actor_id
      and (p_planned_assignee_id is null or user_id = p_planned_assignee_id)
  loop
    insert into public.user_notifications(
      household_id, recipient_user_id, type, title, body, payload, dedup_key
    ) values (
      v_household_id, v_recipient.user_id, 'handover_created', '明日の準備', v_shared_text,
      jsonb_build_object('task_id', v_task_id, 'scheduled_date', p_scheduled_date),
      p_operation_id::text || ':preparation_handoff:' || v_recipient.user_id::text
    );
  end loop;

  v_result := jsonb_build_object('task_id', v_task_id, 'handover_id', v_handover_id);
  update private.mutation_receipts
  set result_type='task_instance', result_id=v_task_id, result_payload=v_result
  where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end;
$$;
revoke all on function public.server_tx_create_preparation_handoff(uuid,uuid,text,date,uuid) from public,anon,authenticated;
grant execute on function public.server_tx_create_preparation_handoff(uuid,uuid,text,date,uuid) to service_role;

-- Seed the concrete household routine discussed with the user. The migration
-- intentionally addresses existing households only; future households keep
-- the normal onboarding defaults. Generated IDs are never hardcoded.
do $$
declare
  v_household record;
  v_household_id uuid;
  v_actor_id uuid;
  v_def_id uuid;
  v_weekday int;
  v_today date := (now() at time zone 'Asia/Tokyo')::date;
  v_rule record;
begin
  for v_household in
    select h.id,
      (select hm.user_id from public.household_members hm where hm.household_id=h.id order by hm.joined_at limit 1) actor_id
    from public.households h
  loop
    v_household_id := v_household.id;
    v_actor_id := v_household.actor_id;
    if v_actor_id is null then continue; end if;

    -- Morning: Shino constipation medicine.
    insert into public.task_definitions(
      household_id, code, title, category, routine_phase, completion_mode,
      is_active, sort_order, created_by, calendar_visibility, task_kind, include_in_routine_line
    ) values (
      v_household_id, 'med_shino_constipation_am', '詩乃（便秘）の薬', 'health', 'morning', 'whole',
      true, 40, v_actor_id, 'hidden', 'morning_chore', true
    ) on conflict(household_id, code) do update set
      title=excluded.title, category=excluded.category, routine_phase=excluded.routine_phase,
      completion_mode=excluded.completion_mode, is_active=true, sort_order=excluded.sort_order,
      calendar_visibility='hidden', task_kind='morning_chore', include_in_routine_line=true,
      updated_at=now()
    returning id into v_def_id;
    for v_weekday in 1..7 loop
      if not exists(select 1 from public.recurrence_rules where household_id=v_household_id and task_definition_id=v_def_id and weekday=v_weekday and slot_key='default' and active) then
        insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,planned_assignee_id,scheduled_local_time,effective_from,active,version,created_by)
        values(v_household_id,v_def_id,v_weekday,'default','dropoff_assignee',null,time '07:00',v_today,true,1,v_actor_id);
      end if;
    end loop;

    -- Morning: medicine / bowel record checklist.
    insert into public.task_definitions(
      household_id, code, title, category, routine_phase, completion_mode,
      is_active, sort_order, created_by, calendar_visibility, task_kind, include_in_routine_line
    ) values (
      v_household_id, 'health_shino_med_bowel_record_am', '詩乃の薬・便の記録', 'health', 'morning', 'subtasks',
      true, 41, v_actor_id, 'hidden', 'morning_chore', true
    ) on conflict(household_id, code) do update set
      title=excluded.title, category=excluded.category, routine_phase=excluded.routine_phase,
      completion_mode='subtasks', is_active=true, sort_order=excluded.sort_order,
      calendar_visibility='hidden', task_kind='morning_chore', include_in_routine_line=true,
      updated_at=now()
    returning id into v_def_id;
    update public.task_subtask_definitions set is_active=false where household_id=v_household_id and task_definition_id=v_def_id and is_active;
    insert into public.task_subtask_definitions(household_id,task_definition_id,title,required,sort_order,is_active) values
      (v_household_id,v_def_id,'薬を記録する',true,0,true),
      (v_household_id,v_def_id,'便を記録する',true,1,true);
    for v_weekday in 1..7 loop
      if not exists(select 1 from public.recurrence_rules where household_id=v_household_id and task_definition_id=v_def_id and weekday=v_weekday and slot_key='default' and active) then
        insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,planned_assignee_id,scheduled_local_time,effective_from,active,version,created_by)
        values(v_household_id,v_def_id,v_weekday,'default','dropoff_assignee',null,time '07:05',v_today,true,1,v_actor_id);
      end if;
    end loop;

    -- Morning: temporary cold medicines. They are normal definitions so they
    -- can be turned off independently when the course finishes.
    insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,is_active,sort_order,created_by,calendar_visibility,task_kind,include_in_routine_line)
    values(v_household_id,'med_masaki_cold_am','将生（風邪）の薬','health','morning','whole',true,42,v_actor_id,'hidden','morning_chore',true)
    on conflict(household_id,code) do update set title=excluded.title,is_active=true,sort_order=42,task_kind='morning_chore',routine_phase='morning',updated_at=now()
    returning id into v_def_id;
    for v_weekday in 1..7 loop
      if not exists(select 1 from public.recurrence_rules where household_id=v_household_id and task_definition_id=v_def_id and weekday=v_weekday and slot_key='default' and active) then
        insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,scheduled_local_time,effective_from,active,created_by)
        values(v_household_id,v_def_id,v_weekday,'default','dropoff_assignee',time '07:10',v_today,true,v_actor_id);
      end if;
    end loop;

    insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,is_active,sort_order,created_by,calendar_visibility,task_kind,include_in_routine_line)
    values(v_household_id,'med_shino_cold_am','詩乃（風邪）の薬','health','morning','whole',true,43,v_actor_id,'hidden','morning_chore',true)
    on conflict(household_id,code) do update set title=excluded.title,is_active=true,sort_order=43,task_kind='morning_chore',routine_phase='morning',updated_at=now()
    returning id into v_def_id;
    for v_weekday in 1..7 loop
      if not exists(select 1 from public.recurrence_rules where household_id=v_household_id and task_definition_id=v_def_id and weekday=v_weekday and slot_key='default' and active) then
        insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,scheduled_local_time,effective_from,active,created_by)
        values(v_household_id,v_def_id,v_weekday,'default','dropoff_assignee',time '07:15',v_today,true,v_actor_id);
      end if;
    end loop;

    -- Tuesday / Thursday preparations are weekday routines, not vague notes.
    select id into v_def_id from public.task_definitions where household_id=v_household_id and code='prep_tuesday_gym';
    if v_def_id is not null then
      update public.task_definitions set title='将生：体操着の準備・着替え',completion_mode='subtasks',task_kind='morning_preparation',routine_phase='morning',is_active=true,updated_at=now() where id=v_def_id;
      update public.task_subtask_definitions set is_active=false where household_id=v_household_id and task_definition_id=v_def_id and is_active;
      insert into public.task_subtask_definitions(household_id,task_definition_id,title,required,sort_order,is_active) values
        (v_household_id,v_def_id,'体操着を準備する',true,0,true),
        (v_household_id,v_def_id,'体操着に着替える',true,1,true);
      if not exists(select 1 from public.recurrence_rules where household_id=v_household_id and task_definition_id=v_def_id and weekday=2 and slot_key='default' and active) then
        insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,scheduled_local_time,effective_from,active,created_by)
        values(v_household_id,v_def_id,2,'default','dropoff_assignee',time '07:20',v_today,true,v_actor_id);
      end if;
      delete from public.task_instances where household_id=v_household_id and task_definition_id=v_def_id and origin='recurring' and status='todo' and scheduled_date>=v_today;
    end if;

    select id into v_def_id from public.task_definitions where household_id=v_household_id and code='prep_thursday_english';
    if v_def_id is not null then
      update public.task_definitions set title='英語教材の準備',completion_mode='whole',task_kind='morning_preparation',routine_phase='morning',is_active=true,updated_at=now() where id=v_def_id;
      if not exists(select 1 from public.recurrence_rules where household_id=v_household_id and task_definition_id=v_def_id and weekday=4 and slot_key='default' and active) then
        insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,scheduled_local_time,effective_from,active,created_by)
        values(v_household_id,v_def_id,4,'default','dropoff_assignee',time '07:20',v_today,true,v_actor_id);
      end if;
      delete from public.task_instances where household_id=v_household_id and task_definition_id=v_def_id and origin='recurring' and status='todo' and scheduled_date>=v_today;
    end if;

    -- Night: laundry is a choose-what-applies checklist. Every subitem is
    -- optional and the parent has an explicit finish action in the PWA.
    select id into v_def_id from public.task_definitions where household_id=v_household_id and code='laundry';
    if v_def_id is not null then
      update public.task_definitions set completion_mode='subtasks',task_kind='evening_chore',routine_phase='evening',is_active=true,include_in_routine_line=true,updated_at=now() where id=v_def_id;
      update public.task_subtask_definitions set is_active=false where household_id=v_household_id and task_definition_id=v_def_id and is_active;
      insert into public.task_subtask_definitions(household_id,task_definition_id,title,required,sort_order,is_active) values
        (v_household_id,v_def_id,'普通洗濯',false,0,true),
        (v_household_id,v_def_id,'普通洗濯を干す',false,1,true),
        (v_household_id,v_def_id,'オシャレ着洗濯',false,2,true),
        (v_household_id,v_def_id,'オシャレ着を干す',false,3,true),
        (v_household_id,v_def_id,'洗濯乾燥',false,4,true),
        (v_household_id,v_def_id,'洗濯物を畳む',false,5,true);
      for v_weekday in 1..7 loop
        if not exists(select 1 from public.recurrence_rules where household_id=v_household_id and task_definition_id=v_def_id and weekday=v_weekday and slot_key='default' and active) then
          insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,scheduled_local_time,effective_from,active,created_by)
          values(v_household_id,v_def_id,v_weekday,'default','pickup_assignee',time '20:30',v_today,true,v_actor_id);
        end if;
        insert into public.evening_routine_preferences(household_id,task_definition_id,weekday,enabled,assignee_strategy,fixed_assignee_id,scheduled_local_time)
        values(v_household_id,v_def_id,v_weekday,true,'pickup_assignee',null,time '20:30')
        on conflict(household_id,task_definition_id,weekday) do update set enabled=true,assignee_strategy='pickup_assignee',fixed_assignee_id=null,scheduled_local_time=time '20:30',updated_at=now();
      end loop;
      delete from public.task_instances where household_id=v_household_id and task_definition_id=v_def_id and origin='recurring' and status='todo' and scheduled_date>=v_today;
    end if;

    -- Night: child help. Mark whichever child actually helped; none is forced.
    insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,is_active,sort_order,created_by,calendar_visibility,task_kind,include_in_routine_line)
    values(v_household_id,'child_help','こどものお手伝い','child_routine','evening','subtasks',true,115,v_actor_id,'hidden','evening_chore',true)
    on conflict(household_id,code) do update set title=excluded.title,completion_mode='subtasks',is_active=true,sort_order=115,task_kind='evening_chore',routine_phase='evening',updated_at=now()
    returning id into v_def_id;
    update public.task_subtask_definitions set is_active=false where household_id=v_household_id and task_definition_id=v_def_id and is_active;
    insert into public.task_subtask_definitions(household_id,task_definition_id,title,required,sort_order,is_active) values
      (v_household_id,v_def_id,'将生',false,0,true),
      (v_household_id,v_def_id,'詩乃',false,1,true);
    for v_weekday in 1..7 loop
      if not exists(select 1 from public.recurrence_rules where household_id=v_household_id and task_definition_id=v_def_id and weekday=v_weekday and slot_key='default' and active) then
        insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,scheduled_local_time,effective_from,active,created_by)
        values(v_household_id,v_def_id,v_weekday,'default','pickup_assignee',time '20:20',v_today,true,v_actor_id);
      end if;
      insert into public.evening_routine_preferences(household_id,task_definition_id,weekday,enabled,assignee_strategy,fixed_assignee_id,scheduled_local_time)
      values(v_household_id,v_def_id,v_weekday,true,'pickup_assignee',null,time '20:20')
      on conflict(household_id,task_definition_id,weekday) do update set enabled=true,assignee_strategy='pickup_assignee',fixed_assignee_id=null,scheduled_local_time=time '20:20',updated_at=now();
    end loop;

    -- Night medicines / record.
    insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,is_active,sort_order,created_by,calendar_visibility,task_kind,include_in_routine_line)
    values(v_household_id,'med_shino_constipation_pm','詩乃（便秘）の薬','health','evening','whole',true,170,v_actor_id,'hidden','evening_chore',true)
    on conflict(household_id,code) do update set title=excluded.title,is_active=true,sort_order=170,task_kind='evening_chore',routine_phase='evening',updated_at=now()
    returning id into v_def_id;
    for v_weekday in 1..7 loop
      if not exists(select 1 from public.recurrence_rules where household_id=v_household_id and task_definition_id=v_def_id and weekday=v_weekday and slot_key='default' and active) then
        insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,scheduled_local_time,effective_from,active,created_by)
        values(v_household_id,v_def_id,v_weekday,'default','pickup_assignee',time '20:45',v_today,true,v_actor_id);
      end if;
      insert into public.evening_routine_preferences(household_id,task_definition_id,weekday,enabled,assignee_strategy,fixed_assignee_id,scheduled_local_time)
      values(v_household_id,v_def_id,v_weekday,true,'pickup_assignee',null,time '20:45')
      on conflict(household_id,task_definition_id,weekday) do update set enabled=true,assignee_strategy='pickup_assignee',fixed_assignee_id=null,scheduled_local_time=time '20:45',updated_at=now();
    end loop;

    insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,is_active,sort_order,created_by,calendar_visibility,task_kind,include_in_routine_line)
    values(v_household_id,'health_shino_med_bowel_record_pm','詩乃の薬・便の記録','health','evening','subtasks',true,171,v_actor_id,'hidden','evening_chore',true)
    on conflict(household_id,code) do update set title=excluded.title,completion_mode='subtasks',is_active=true,sort_order=171,task_kind='evening_chore',routine_phase='evening',updated_at=now()
    returning id into v_def_id;
    update public.task_subtask_definitions set is_active=false where household_id=v_household_id and task_definition_id=v_def_id and is_active;
    insert into public.task_subtask_definitions(household_id,task_definition_id,title,required,sort_order,is_active) values
      (v_household_id,v_def_id,'薬を記録する',true,0,true),
      (v_household_id,v_def_id,'便を記録する',true,1,true);
    for v_weekday in 1..7 loop
      if not exists(select 1 from public.recurrence_rules where household_id=v_household_id and task_definition_id=v_def_id and weekday=v_weekday and slot_key='default' and active) then
        insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,scheduled_local_time,effective_from,active,created_by)
        values(v_household_id,v_def_id,v_weekday,'default','pickup_assignee',time '20:50',v_today,true,v_actor_id);
      end if;
      insert into public.evening_routine_preferences(household_id,task_definition_id,weekday,enabled,assignee_strategy,fixed_assignee_id,scheduled_local_time)
      values(v_household_id,v_def_id,v_weekday,true,'pickup_assignee',null,time '20:50')
      on conflict(household_id,task_definition_id,weekday) do update set enabled=true,assignee_strategy='pickup_assignee',fixed_assignee_id=null,scheduled_local_time=time '20:50',updated_at=now();
    end loop;

    insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,is_active,sort_order,created_by,calendar_visibility,task_kind,include_in_routine_line)
    values(v_household_id,'med_masaki_cold_pm','将生（風邪）の薬','health','evening','whole',true,172,v_actor_id,'hidden','evening_chore',true)
    on conflict(household_id,code) do update set title=excluded.title,is_active=true,sort_order=172,task_kind='evening_chore',routine_phase='evening',updated_at=now()
    returning id into v_def_id;
    for v_weekday in 1..7 loop
      if not exists(select 1 from public.recurrence_rules where household_id=v_household_id and task_definition_id=v_def_id and weekday=v_weekday and slot_key='default' and active) then
        insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,scheduled_local_time,effective_from,active,created_by)
        values(v_household_id,v_def_id,v_weekday,'default','pickup_assignee',time '20:55',v_today,true,v_actor_id);
      end if;
      insert into public.evening_routine_preferences(household_id,task_definition_id,weekday,enabled,assignee_strategy,fixed_assignee_id,scheduled_local_time)
      values(v_household_id,v_def_id,v_weekday,true,'pickup_assignee',null,time '20:55')
      on conflict(household_id,task_definition_id,weekday) do update set enabled=true,assignee_strategy='pickup_assignee',fixed_assignee_id=null,scheduled_local_time=time '20:55',updated_at=now();
    end loop;

    insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,is_active,sort_order,created_by,calendar_visibility,task_kind,include_in_routine_line)
    values(v_household_id,'med_shino_cold_pm','詩乃（風邪）の薬','health','evening','whole',true,173,v_actor_id,'hidden','evening_chore',true)
    on conflict(household_id,code) do update set title=excluded.title,is_active=true,sort_order=173,task_kind='evening_chore',routine_phase='evening',updated_at=now()
    returning id into v_def_id;
    for v_weekday in 1..7 loop
      if not exists(select 1 from public.recurrence_rules where household_id=v_household_id and task_definition_id=v_def_id and weekday=v_weekday and slot_key='default' and active) then
        insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,scheduled_local_time,effective_from,active,created_by)
        values(v_household_id,v_def_id,v_weekday,'default','pickup_assignee',time '21:00',v_today,true,v_actor_id);
      end if;
      insert into public.evening_routine_preferences(household_id,task_definition_id,weekday,enabled,assignee_strategy,fixed_assignee_id,scheduled_local_time)
      values(v_household_id,v_def_id,v_weekday,true,'pickup_assignee',null,time '21:00')
      on conflict(household_id,task_definition_id,weekday) do update set enabled=true,assignee_strategy='pickup_assignee',fixed_assignee_id=null,scheduled_local_time=time '21:00',updated_at=now();
    end loop;

    -- Materialize now rather than waiting for the next daily worker. This is
    -- idempotent per logical occurrence key and makes the new routine visible
    -- on Today/Week immediately after production deployment.
    for v_rule in
      select rr.id
      from public.recurrence_rules rr
      join public.task_definitions td on td.id=rr.task_definition_id and td.household_id=rr.household_id
      where rr.household_id=v_household_id and rr.active
        and td.code in (
          'med_shino_constipation_am','health_shino_med_bowel_record_am','med_masaki_cold_am','med_shino_cold_am',
          'prep_tuesday_gym','prep_thursday_english','laundry','child_help',
          'med_shino_constipation_pm','health_shino_med_bowel_record_pm','med_masaki_cold_pm','med_shino_cold_pm'
        )
    loop
      perform private.materialize_recurrence_rule(v_household_id, v_rule.id, v_today, v_today + 14);
    end loop;
  end loop;
end;
$$;
