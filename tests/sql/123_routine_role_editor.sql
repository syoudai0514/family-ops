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
     or exists (select 1 from public.recurrence_rules where task_definition_id = def and active) then
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
rollback;
