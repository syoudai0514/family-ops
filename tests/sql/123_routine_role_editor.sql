-- Owner instruction 2026-10-11: every routine can be changed in the app, grouped by who does it.
-- The assignment rules the household uses (誰でもOK・前の晩の担当・翌朝送らない人) can be saved,
-- a transport leg still cannot depend on a transport role, any non-transport routine can be
-- stopped, and 「余裕があれば」 follows the setting on future open occurrences.
\set ON_ERROR_STOP on
begin;
set role service_role;
do $$
declare
  u1 uuid := gen_random_uuid(); u2 uuid := gen_random_uuid();
  hh uuid; def uuid; dropoff_def uuid; r jsonb; rejected boolean;
  today date := (now() at time zone 'Asia/Tokyo')::date;
  wd int := extract(isodow from (now() at time zone 'Asia/Tokyo')::date + 1)::int;
begin
  insert into auth.users(id) values (u1), (u2);
  hh := (public.server_tx_create_household(u1, gen_random_uuid(), 'Role editor', 'Owner')->>'household_id')::uuid;
  insert into public.household_members(household_id, user_id, member_role) values (hh, u2, 'adult');
  def := (public.server_tx_create_task_definition(u1, gen_random_uuid(), 'evening_chore_custom_123', 'トイレ掃除',
    'household', 'evening', 'whole', null, null)->>'task_definition_id')::uuid;

  -- 誰でもOK, then 翌朝送らない人, then 前の晩の担当: each saved as chosen.
  foreach r in array array['"anyone_adult"'::jsonb, '"next_day_nondropoff_adult"'::jsonb, '"previous_evening_assignee"'::jsonb] loop
    perform public.server_tx_replace_recurrence_schedule(u1, gen_random_uuid(), jsonb_build_array(jsonb_build_object(
      'task_definition_id', def, 'rules', jsonb_build_array(jsonb_build_object('weekday', wd, 'assignee_strategy', r #>> '{}', 'scheduled_local_time', '20:00')))));
    if (select assignee_strategy from public.recurrence_rules where task_definition_id = def and weekday = wd and active) <> r #>> '{}' then
      raise exception 'FAIL: % was not saved', r;
    end if;
  end loop;

  -- Keep actual open occurrences in the fixture (previous-evening rules only
  -- materialize on their own day); option assertions must never be vacuous.
  perform public.server_tx_replace_recurrence_schedule(u1, gen_random_uuid(), jsonb_build_array(jsonb_build_object(
    'task_definition_id', def, 'rules', (select jsonb_agg(jsonb_build_object('weekday', d, 'assignee_strategy', 'anyone_adult', 'scheduled_local_time', '20:00')) from generate_series(1,7) d))));
  if not exists(select 1 from public.task_instances where task_definition_id=def and status='todo') then
    raise exception 'FAIL: options fixture has no open occurrences';
  end if;

  -- A transport leg cannot follow a transport role.
  insert into public.task_definitions(household_id, code, title, category, routine_phase, completion_mode, task_kind, created_by)
  values (hh, 'dropoff', '送り', 'transport', 'morning', 'whole', 'transport', u1)
  on conflict do nothing;
  select id into dropoff_def from public.task_definitions where household_id = hh and code = 'dropoff';
  rejected := false;
  begin
    perform public.server_tx_change_recurrence(u1, gen_random_uuid(), dropoff_def, wd, 'default', 'next_day_nondropoff_adult', null, '08:00', 60, null);
  exception when others then rejected := sqlerrm = 'INVALID_INPUT';
  end;
  if not rejected then raise exception 'FAIL: a transport leg accepted a transport-role rule'; end if;

  -- 余裕があれば on: definition and tomorrow's open occurrence; off again: back to normal.
  perform public.server_tx_set_routine_definition_options(u1, gen_random_uuid(), def, true, true, 'optional');
  if (select default_expectation from public.task_definitions where id = def) <> 'optional'
     or exists (select 1 from public.task_instances where task_definition_id = def and scheduled_date >= today and status = 'todo' and expectation is distinct from 'optional') then
    raise exception 'FAIL: 余裕があれば was not applied';
  end if;
  perform public.server_tx_set_routine_definition_options(u1, gen_random_uuid(), def, true, true, 'required');
  if (select default_expectation from public.task_definitions where id = def) is not null
     or exists (select 1 from public.task_instances where task_definition_id = def and scheduled_date >= today and expectation = 'optional') then
    raise exception 'FAIL: 余裕があれば was not taken off';
  end if;
  -- The old five-argument call (edge function before this change) still works and keeps the expectation.
  update public.task_definitions set default_expectation = 'required' where id = def;
  perform public.server_tx_set_routine_definition_options(u1, gen_random_uuid(), def, true, false);
  if (select default_expectation from public.task_definitions where id = def) <> 'required'
     or (select include_in_routine_line from public.task_definitions where id = def) then
    raise exception 'FAIL: five-argument options call changed the expectation';
  end if;

  -- A routine that is not a morning/evening chore can be stopped; a transport leg cannot.
  update public.task_definitions set task_kind = 'generic_once', routine_phase = 'anytime' where id = def;
  perform public.server_tx_set_routine_definition_options(u1, gen_random_uuid(), def, false, true);
  if (select is_active from public.task_definitions where id = def)
     or not exists (select 1 from public.recurrence_rules where task_definition_id = def and active)
     or exists (select 1 from public.task_instances where task_definition_id = def and scheduled_date>=today and status='todo') then
    raise exception 'FAIL: an anytime routine could not be stopped';
  end if;
  rejected := false;
  begin
    perform public.server_tx_set_routine_definition_options(u1, gen_random_uuid(), dropoff_def, false, true);
  exception when others then rejected := sqlerrm = 'CROSS_HOUSEHOLD_RESOURCE';
  end;
  if not rejected then raise exception 'FAIL: a transport leg was stopped from the routine editor'; end if;
  rejected := false;
  begin
    perform public.server_tx_set_routine_definition_options(u1, gen_random_uuid(), def, true, true, 'sometimes');
  exception when others then rejected := sqlerrm = 'INVALID_INPUT';
  end;
  if not rejected then raise exception 'FAIL: an unknown expectation was accepted'; end if;
end $$;

-- Checklist snapshots, LINE references, claims, partial completion and pause/restart.
do $$
declare
  owner_id uuid := gen_random_uuid(); hh uuid; def uuid; actor_ref uuid;
  today date := (now() at time zone 'Asia/Tokyo')::date;
  open_task uuid; partial_task uuid; done_task uuid; claimed_task uuid; edited_task uuid; line_task uuid;
  first_definition uuid; first_instance uuid; v_session_id uuid; partial_check uuid; old_key text;
  op uuid := gen_random_uuid(); payload jsonb; before_count int; rejected boolean; bad jsonb;
begin
  insert into auth.users(id) values(owner_id);
  hh := (public.server_tx_create_household(owner_id,gen_random_uuid(),'Checklist editor','Owner')->>'household_id')::uuid;
  select id into actor_ref from public.domain_actor_refs where household_id=hh and real_user_id=owner_id and test_context_id is null;
  def := (public.server_tx_create_task_definition(owner_id,gen_random_uuid(),'evening_chore_custom_123_snapshots','編集前',
    'household','evening','whole',null,null)->>'task_definition_id')::uuid;
  perform public.server_tx_replace_routine_subtasks(owner_id,gen_random_uuid(),def,
    '[{"title":"元の項目A","required":true},{"title":"元の項目B","required":true}]'::jsonb);
  select id into first_definition from public.task_subtask_definitions where task_definition_id=def and title='元の項目A';
  perform public.server_tx_replace_recurrence_schedule(owner_id,gen_random_uuid(),jsonb_build_array(jsonb_build_object(
    'task_definition_id',def,'rules',(select jsonb_agg(jsonb_build_object('weekday',d,'assignee_strategy','anyone_adult','scheduled_local_time','20:00')) from generate_series(1,7) d))));
  select id into open_task from public.task_instances where task_definition_id=def and scheduled_date=today;
  select id into partial_task from public.task_instances where task_definition_id=def and scheduled_date=today+1;
  select id into done_task from public.task_instances where task_definition_id=def and scheduled_date=today+2;
  select id into claimed_task from public.task_instances where task_definition_id=def and scheduled_date=today+3;
  select id into edited_task from public.task_instances where task_definition_id=def and scheduled_date=today+4;
  select id into line_task from public.task_instances where task_definition_id=def and scheduled_date=today+5;
  if open_task is null or line_task is null then raise exception 'FAIL: daily snapshot fixture was not materialized'; end if;
  select id into first_instance from public.task_subtask_instances where task_instance_id=open_task and source_definition_id=first_definition;
  select id into partial_check from public.task_subtask_instances where task_instance_id=partial_task and source_definition_id=first_definition;
  perform public.server_tx_set_subtask_completion(owner_id,gen_random_uuid(),partial_check,true,'self');
  perform public.server_tx_complete_task(owner_id,gen_random_uuid(),done_task,'self',true);
  update public.task_instances set active_claimant_actor_ref_id=actor_ref,claimed_at=now(),attention_state='waiting'
    where id=claimed_task;
  insert into public.task_events(household_id,task_instance_id,actor_id,event_type,payload,source,idempotency_key)
    values(hh,edited_task,owner_id,'edited','{"reason":"user_changed_task"}'::jsonb,'web','sql123-user-edit');
  insert into public.routine_checkin_sessions(household_id,session_type,scheduled_date,assignee_id,status)
    values(hh,'pickup',today+5,owner_id,'open') returning id into v_session_id;
  insert into public.routine_checkin_session_items(household_id,session_id,task_instance_id,display_order)
    values(hh,v_session_id,line_task,0);

  -- A name-only edit affects today's untouched snapshots without touching
  -- the weekly rules or completed/partial/claimed/individually edited work.
  update public.task_instances set title='この日だけの名前'
    where task_definition_id=def and scheduled_date=today+6;
  perform public.server_tx_edit_task_definition(owner_id,gen_random_uuid(),def,'編集後',null,null,null,null);
  if (select title from public.task_instances where id=open_task)<>'編集後'
    or (select title from public.task_instances where id=line_task)<>'編集後'
    or exists(select 1 from public.task_instances where id in(partial_task,done_task,claimed_task,edited_task) and title<>'編集前')
    or not exists(select 1 from public.task_instances where task_definition_id=def and scheduled_date=today+6 and title='この日だけの名前')
    or (select count(*) from public.recurrence_rules where task_definition_id=def and active)<>7 then
    raise exception 'FAIL: name-only edit missed untouched snapshots or changed recorded/individual work and schedule';
  end if;

  payload := jsonb_build_array(jsonb_build_object('id',first_definition,'title','新しい項目A','required',false),
    jsonb_build_object('title','新しい項目C','required',true));
  perform public.server_tx_replace_routine_subtasks(owner_id,op,def,payload);
  if not exists(select 1 from public.task_subtask_instances where id=first_instance and title='新しい項目A' and not required)
    or (select count(*) from public.task_subtask_instances where task_instance_id=open_task)<>2
    or not exists(select 1 from public.task_subtask_instances where task_instance_id=line_task and title='新しい項目C')
    or not exists(select 1 from public.routine_checkin_session_items where session_id=v_session_id and task_instance_id=line_task) then
    raise exception 'FAIL: untouched today/LINE checklists did not follow the edit while retaining IDs';
  end if;
  if not exists(select 1 from public.task_subtask_instances where id=partial_check and is_completed and title='元の項目A')
    or (select count(*) from public.task_subtask_instances where task_instance_id=partial_task)<>2
    or not exists(select 1 from public.task_instances where id=done_task and status='completed')
    or exists(select 1 from public.task_subtask_instances where task_instance_id in (partial_task,done_task,claimed_task,edited_task) and title like '新しい%') then
    raise exception 'FAIL: checklist edit changed recorded, claimed, or partial work';
  end if;
  select count(*) into before_count from public.task_subtask_definitions where task_definition_id=def;
  perform public.server_tx_replace_routine_subtasks(owner_id,op,def,payload);
  if (select count(*) from public.task_subtask_definitions where task_definition_id=def)<>before_count then
    raise exception 'FAIL: retry created duplicate checklist definitions';
  end if;
  foreach bad in array array['null'::jsonb,'{}'::jsonb,'[null]'::jsonb,'[{"title":12}]'::jsonb,
    '[{"title":"invalid","required":"false"}]'::jsonb,
    jsonb_build_array(jsonb_build_object('id',first_definition,'title','A'),jsonb_build_object('id',first_definition,'title','B'))]
  loop
    rejected:=false;
    begin perform public.server_tx_replace_routine_subtasks(owner_id,gen_random_uuid(),def,bad);
    exception when others then rejected:=sqlerrm='INVALID_INPUT'; end;
    if not rejected then raise exception 'FAIL: malformed checklist accepted: %',bad; end if;
  end loop;

  -- Removing all checks changes untouched occurrences to whole completion,
  -- but keeps the old subtask completion mode and snapshots of started work.
  perform public.server_tx_replace_routine_subtasks(owner_id,gen_random_uuid(),def,'[]'::jsonb);
  if (select completion_mode from public.task_instances where id=open_task)<>'whole'
    or exists(select 1 from public.task_subtask_instances where task_instance_id=open_task)
    or (select completion_mode from public.task_instances where id=partial_task)<>'subtasks'
    or not exists(select 1 from public.task_subtask_instances where id=partial_check and is_completed) then
    raise exception 'FAIL: removing checklist changed recorded work or missed untouched work';
  end if;

  select logical_occurrence_key into old_key from public.task_instances where id=partial_task;
  perform public.server_tx_set_routine_definition_options(owner_id,gen_random_uuid(),def,false,true);
  if (select count(*) from public.recurrence_rules where task_definition_id=def and active)<>7
    or exists(select 1 from public.task_instances where task_definition_id=def and status='todo')
    or not exists(select 1 from public.task_instances where id=partial_task and status='cancelled' and logical_occurrence_key is null)
    or not exists(select 1 from public.task_subtask_instances where id=partial_check and is_completed)
    or not exists(select 1 from public.task_instances where id=done_task and status='completed') then
    raise exception 'FAIL: pause did not preserve exact schedule, partial checks, or completed history';
  end if;
  -- An edit while paused is reflected on restart for untouched snapshots.
  perform public.server_tx_replace_routine_subtasks(owner_id,gen_random_uuid(),def,'[{"title":"再開後の項目","required":true}]'::jsonb);
  perform public.server_tx_set_routine_definition_options(owner_id,gen_random_uuid(),def,true,true);
  if not exists(select 1 from public.task_instances where id=partial_task and status='todo' and logical_occurrence_key=old_key)
    or not exists(select 1 from public.task_instances where id=claimed_task and active_claimant_actor_ref_id=actor_ref and claimed_at is not null and attention_state='waiting')
    or not exists(select 1 from public.task_subtask_instances where task_instance_id=line_task and title='再開後の項目')
    or exists(select logical_occurrence_key from public.task_instances where household_id=hh and logical_occurrence_key is not null group by logical_occurrence_key having count(*)>1) then
    raise exception 'FAIL: restart did not restore the same occurrences, claims, and edited untouched checklist';
  end if;

  -- Changing a rule keeps a referenced LINE snapshot as cancelled and creates
  -- its replacement; partial/claimed/user-edited tasks keep their own key.
  select logical_occurrence_key into old_key from public.task_instances where id=line_task;
  perform public.server_tx_change_recurrence(owner_id,gen_random_uuid(),def,extract(isodow from today+5)::int,'default','anyone_adult',null,'21:00',60,null);
  if not exists(select 1 from public.task_instances where id=line_task and status='cancelled' and logical_occurrence_key is null)
    or not exists(select 1 from public.task_instances where task_definition_id=def and logical_occurrence_key=old_key and id<>line_task and status='todo')
    or not exists(select 1 from public.routine_checkin_session_items si where si.session_id=v_session_id and si.task_instance_id=line_task) then
    raise exception 'FAIL: replacing a schedule with an existing LINE reference failed to retain the snapshot and materialize a replacement';
  end if;
  perform public.server_tx_change_recurrence(owner_id,gen_random_uuid(),def,extract(isodow from today+1)::int,'default','anyone_adult',null,'21:00',60,null);
  if not exists(select 1 from public.task_instances where id=partial_task and status='todo' and logical_occurrence_key is not null)
    or not exists(select 1 from public.task_subtask_instances where id=partial_check and is_completed) then
    raise exception 'FAIL: replacing a schedule lost in-progress work';
  end if;

  -- Edit a paused routine before resuming: a removed weekday must never return.
  perform public.server_tx_set_routine_definition_options(owner_id,gen_random_uuid(),def,false,true);
  perform public.server_tx_deactivate_recurrence(owner_id,gen_random_uuid(),def,extract(isodow from today+5)::int,'default');
  perform public.server_tx_set_routine_definition_options(owner_id,gen_random_uuid(),def,true,true);
  if exists(select 1 from public.task_instances where task_definition_id=def and status='todo' and extract(isodow from scheduled_date)::int=extract(isodow from today+5)::int)
    or (select count(*) from public.recurrence_rules where task_definition_id=def and active)<>6 then
    raise exception 'FAIL: restarting resurrected a removed weekday';
  end if;
end $$;
rollback;
