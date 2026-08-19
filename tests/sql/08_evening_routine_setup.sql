-- v6 review fix P1-4: configure-evening-routines transaction RPC.
-- docs/design/v6/fixtures/EVENING_SETUP_CASES.json EV01-EV04 (EV05 is
-- routine_checkin_sessions reassignment — WP8 dispatch-worker scope, not
-- reachable from this RPC and not tested here).
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('f0000000-0000-0000-0000-000000000001'), -- owner/adult 1
  ('f0000000-0000-0000-0000-000000000002'); -- adult 2 (fixed assignee target)

set role service_role;

do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_task_id uuid;
  v_result jsonb;
  v_op uuid;
  v_rule record;
  v_instance_count int;
begin
  v_hh := public.server_tx_create_household('f0000000-0000-0000-0000-000000000001', gen_random_uuid(), 'Evening Setup HH', 'Owner');
  v_hh_id := (v_hh->>'household_id')::uuid;

  -- second adult so 'fixed' assignee validation has a same-household target
  insert into public.household_members (household_id, user_id, member_role)
  values (v_hh_id, 'f0000000-0000-0000-0000-000000000002', 'adult');

  -- EV01: fresh household before setup -> setup_required (null completion marker)
  if (select evening_routine_setup_completed_at from public.households where id = v_hh_id) is not null then
    raise exception 'FAIL evening-setup: EV01 fresh household must not already be setup-complete';
  end if;

  insert into public.task_definitions (id, household_id, code, title, category, routine_phase, completion_mode, created_by)
  values (gen_random_uuid(), v_hh_id, 'dinner_prep', '夕食準備', 'chore', 'evening', 'whole', 'f0000000-0000-0000-0000-000000000001')
  returning id into v_task_id;

  -- EV02: confirm_nonpickup -> rules_materialized
  v_op := gen_random_uuid();
  v_result := public.server_tx_configure_evening_routines(
    'f0000000-0000-0000-0000-000000000001',
    v_op,
    jsonb_build_array(jsonb_build_object(
      'task_code', 'dinner_prep',
      'weekdays', jsonb_build_array(1, 2, 3),
      'assignee_strategy', 'nonpickup_adult',
      'enabled', true
    ))
  );

  if (v_result->>'evening_routine_setup_completed_at') is null then
    raise exception 'FAIL evening-setup: EV02 result must include evening_routine_setup_completed_at';
  end if;
  if (select evening_routine_setup_completed_at from public.households where id = v_hh_id) is null then
    raise exception 'FAIL evening-setup: EV02 households.evening_routine_setup_completed_at must be set';
  end if;

  select count(*) into v_instance_count
  from public.recurrence_rules
  where household_id = v_hh_id and task_definition_id = v_task_id and active;
  if v_instance_count <> 3 then
    raise exception 'FAIL evening-setup: EV02 expected 3 active recurrence rules (Mon/Tue/Wed), got %', v_instance_count;
  end if;

  select count(*) into v_instance_count
  from public.task_instances
  where household_id = v_hh_id and task_definition_id = v_task_id and status = 'todo';
  if v_instance_count = 0 then
    raise exception 'FAIL evening-setup: EV02 targeted materialization must have created task_instances';
  end if;

  -- nonpickup_adult resolver is WP3, not WP1: planned_assignee_id must stay
  -- null rather than guessing (03_DOMAIN_AND_DATA_MODEL.md #3).
  if exists (
    select 1 from public.task_instances
    where household_id = v_hh_id and task_definition_id = v_task_id and planned_assignee_id is not null
  ) then
    raise exception 'FAIL evening-setup: EV02 nonpickup_adult must not guess an assignee in WP1';
  end if;

  -- replay: same operation_id returns the same stored result, no duplicate rules
  v_result := public.server_tx_configure_evening_routines(
    'f0000000-0000-0000-0000-000000000001',
    v_op,
    jsonb_build_array(jsonb_build_object(
      'task_code', 'dinner_prep',
      'weekdays', jsonb_build_array(1, 2, 3),
      'assignee_strategy', 'nonpickup_adult',
      'enabled', true
    ))
  );
  select count(*) into v_instance_count
  from public.recurrence_rules
  where household_id = v_hh_id and task_definition_id = v_task_id and active;
  if v_instance_count <> 3 then
    raise exception 'FAIL evening-setup: replay must not create duplicate recurrence rules, got %', v_instance_count;
  end if;
end;
$$;

-- EV04: pickup_change -> role_future_recomputed (strategy change closes the
-- old rule version, removes its future todo instances, opens a new one)
do $$
declare
  v_hh_id uuid;
  v_task_id uuid;
  v_old_rule_id uuid;
  v_new_rule_id uuid;
  v_old_future_todo int;
begin
  select id into v_hh_id from public.households where name = 'Evening Setup HH';
  select id into v_task_id from public.task_definitions where household_id = v_hh_id and code = 'dinner_prep';

  select id into v_old_rule_id from public.recurrence_rules
  where household_id = v_hh_id and task_definition_id = v_task_id and weekday = 1 and active;

  perform public.server_tx_configure_evening_routines(
    'f0000000-0000-0000-0000-000000000001',
    gen_random_uuid(),
    jsonb_build_array(jsonb_build_object(
      'task_code', 'dinner_prep',
      'weekdays', jsonb_build_array(1, 2, 3),
      'assignee_strategy', 'fixed',
      'fixed_assignee_id', 'f0000000-0000-0000-0000-000000000002',
      'enabled', true
    ))
  );

  if (select active from public.recurrence_rules where id = v_old_rule_id) then
    raise exception 'FAIL evening-setup: EV04 old rule version must be deactivated on strategy change';
  end if;

  select id into v_new_rule_id from public.recurrence_rules
  where household_id = v_hh_id and task_definition_id = v_task_id and weekday = 1 and active;
  if v_new_rule_id is null or v_new_rule_id = v_old_rule_id then
    raise exception 'FAIL evening-setup: EV04 a new rule version must exist for weekday 1';
  end if;
  if (select planned_assignee_id from public.recurrence_rules where id = v_new_rule_id)
     <> 'f0000000-0000-0000-0000-000000000002'::uuid then
    raise exception 'FAIL evening-setup: EV04 new rule must carry the fixed assignee';
  end if;

  select count(*) into v_old_future_todo
  from public.task_instances
  where recurrence_rule_id = v_old_rule_id and scheduled_date >= current_date and status = 'todo';
  if v_old_future_todo <> 0 then
    raise exception 'FAIL evening-setup: EV04 future todo instances tied to the old rule must be reconciled away, found %', v_old_future_todo;
  end if;

  if not exists (
    select 1 from public.task_instances
    where recurrence_rule_id = v_new_rule_id and planned_assignee_id = 'f0000000-0000-0000-0000-000000000002'::uuid
  ) then
    raise exception 'FAIL evening-setup: EV04 new fixed-strategy instances must carry the resolved assignee';
  end if;
end;
$$;

-- EV03: disabled_task -> no_instance
do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_task_id uuid;
begin
  insert into auth.users (id) values ('f0000000-0000-0000-0000-000000000003');
  v_hh := public.server_tx_create_household('f0000000-0000-0000-0000-000000000003', gen_random_uuid(), 'EV03 HH', 'Owner');
  v_hh_id := (v_hh->>'household_id')::uuid;

  insert into public.task_definitions (id, household_id, code, title, category, routine_phase, completion_mode, created_by)
  values (gen_random_uuid(), v_hh_id, 'bath', 'お風呂', 'chore', 'evening', 'whole', 'f0000000-0000-0000-0000-000000000003')
  returning id into v_task_id;

  perform public.server_tx_configure_evening_routines(
    'f0000000-0000-0000-0000-000000000003',
    gen_random_uuid(),
    jsonb_build_array(jsonb_build_object(
      'task_code', 'bath',
      'weekdays', jsonb_build_array(1, 2, 3, 4, 5),
      'assignee_strategy', 'nonpickup_adult',
      'enabled', false
    ))
  );

  if exists (
    select 1 from public.recurrence_rules where household_id = v_hh_id and task_definition_id = v_task_id and active
  ) then
    raise exception 'FAIL evening-setup: EV03 disabled task must not create any active recurrence rule';
  end if;
  if exists (
    select 1 from public.task_instances where household_id = v_hh_id and task_definition_id = v_task_id
  ) then
    raise exception 'FAIL evening-setup: EV03 disabled task must not materialize any instance';
  end if;
  if exists (
    select 1 from public.evening_routine_preferences
    where household_id = v_hh_id and task_definition_id = v_task_id and enabled
  ) then
    raise exception 'FAIL evening-setup: EV03 evening_routine_preferences must record enabled=false';
  end if;
end;
$$;

-- cross-household fixed_assignee_id is rejected
do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_outsider uuid := 'f0000000-0000-0000-0000-000000000099';
begin
  insert into auth.users (id) values (v_outsider) on conflict do nothing;
  insert into auth.users (id) values ('f0000000-0000-0000-0000-000000000004');
  v_hh := public.server_tx_create_household('f0000000-0000-0000-0000-000000000004', gen_random_uuid(), 'Cross HH Guard', 'Owner');
  v_hh_id := (v_hh->>'household_id')::uuid;

  insert into public.task_definitions (household_id, code, title, category, routine_phase, completion_mode, created_by)
  values (v_hh_id, 'dishes', '食器洗い', 'chore', 'evening', 'whole', 'f0000000-0000-0000-0000-000000000004');

  begin
    perform public.server_tx_configure_evening_routines(
      'f0000000-0000-0000-0000-000000000004',
      gen_random_uuid(),
      jsonb_build_array(jsonb_build_object(
        'task_code', 'dishes',
        'weekdays', jsonb_build_array(1),
        'assignee_strategy', 'fixed',
        'fixed_assignee_id', v_outsider::text,
        'enabled', true
      ))
    );
    raise exception 'FAIL evening-setup: fixed_assignee_id outside the household must be rejected';
  exception
    when others then
      if sqlerrm <> 'CROSS_HOUSEHOLD_RESOURCE' then
        raise exception 'FAIL evening-setup: expected CROSS_HOUSEHOLD_RESOURCE, got %', sqlerrm;
      end if;
  end;
end;
$$;

-- anon/authenticated cannot execute this RPC directly
reset role;
set role authenticated;
set request.jwt.claim.sub = 'f0000000-0000-0000-0000-000000000001';
do $$
begin
  begin
    perform public.server_tx_configure_evening_routines(
      'f0000000-0000-0000-0000-000000000001', gen_random_uuid(), '[]'::jsonb
    );
    raise exception 'FAIL evening-setup: authenticated must not execute server_tx_configure_evening_routines directly';
  exception
    when insufficient_privilege then null;
  end;
end;
$$;
reset role;
reset request.jwt.claim.sub;

select 'evening_routine_setup: PASS' as result;
