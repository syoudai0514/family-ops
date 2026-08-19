-- v6 re-review fixes: configure-evening-routines transaction RPC tested
-- through the *real* bootstrap path (fresh household -> canonical task
-- definitions already exist -> evening setup), never a manual
-- task_definitions INSERT; complete-batch-only (all 7 canonical evening
-- tasks, each with an explicit enabled flag) enforcement; Asia/Tokyo
-- v_today correctness.
-- docs/design/v6/fixtures/EVENING_SETUP_CASES.json EV01-EV04 (EV05 is
-- routine_checkin_sessions reassignment — WP8 dispatch-worker scope, not
-- reachable from this RPC and not tested here).
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('f0000000-0000-0000-0000-000000000001'), -- owner/adult 1
  ('f0000000-0000-0000-0000-000000000002'); -- adult 2 (fixed assignee target)

set role service_role;

-- helper: build a full 7-row batch where every code gets `enabled:false,
-- weekdays:[]` except the ones explicitly overridden.
-- (implemented inline per test below; PL/pgSQL has no convenient closures)

do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_task_id uuid;
  v_result jsonb;
  v_op uuid;
  v_instance_count int;
  v_full_batch jsonb;
begin
  v_hh := public.server_tx_create_household('f0000000-0000-0000-0000-000000000001', gen_random_uuid(), 'Evening Setup HH', 'Owner');
  v_hh_id := (v_hh->>'household_id')::uuid;

  -- second adult so 'fixed' assignee validation (EV04) has a same-household target
  insert into public.household_members (household_id, user_id, member_role)
  values (v_hh_id, 'f0000000-0000-0000-0000-000000000002', 'adult');

  -- EV01: fresh household before setup -> setup_required (null completion marker)
  if (select evening_routine_setup_completed_at from public.households where id = v_hh_id) is not null then
    raise exception 'FAIL evening-setup: EV01 fresh household must not already be setup-complete';
  end if;

  -- the real bootstrap path: canonical task definitions already exist —
  -- never inserted by hand in this test.
  select id into v_task_id from public.task_definitions where household_id = v_hh_id and code = 'dinner';
  if v_task_id is null then
    raise exception 'FAIL evening-setup: canonical task_definitions must be bootstrapped by server_tx_create_household (dinner missing)';
  end if;
  if (select count(*) from public.task_definitions where household_id = v_hh_id) <> 13 then
    raise exception 'FAIL evening-setup: expected exactly 13 canonical task_definitions, got %',
      (select count(*) from public.task_definitions where household_id = v_hh_id);
  end if;

  -- a single-item batch must be rejected outright — no partial setup completion
  begin
    perform public.server_tx_configure_evening_routines(
      'f0000000-0000-0000-0000-000000000001',
      gen_random_uuid(),
      jsonb_build_array(jsonb_build_object(
        'task_code', 'dinner', 'weekdays', jsonb_build_array(1, 2, 3),
        'assignee_strategy', 'nonpickup_adult', 'enabled', true
      ))
    );
    raise exception 'FAIL evening-setup: a single-task batch must be rejected (INVALID_INPUT)';
  exception
    when others then
      if sqlerrm <> 'INVALID_INPUT' then
        raise exception 'FAIL evening-setup: expected INVALID_INPUT for a partial batch, got %', sqlerrm;
      end if;
  end;

  -- a 7-item batch missing an explicit `enabled` flag must also be rejected
  begin
    perform public.server_tx_configure_evening_routines(
      'f0000000-0000-0000-0000-000000000001',
      gen_random_uuid(),
      jsonb_build_array(
        jsonb_build_object('task_code', 'dinner', 'weekdays', jsonb_build_array(1), 'assignee_strategy', 'nonpickup_adult'), -- no `enabled`
        jsonb_build_object('task_code', 'bath', 'weekdays', '[]'::jsonb, 'assignee_strategy', 'nonpickup_adult', 'enabled', false),
        jsonb_build_object('task_code', 'laundry', 'weekdays', '[]'::jsonb, 'assignee_strategy', 'nonpickup_adult', 'enabled', false),
        jsonb_build_object('task_code', 'dishes', 'weekdays', '[]'::jsonb, 'assignee_strategy', 'nonpickup_adult', 'enabled', false),
        jsonb_build_object('task_code', 'cleaning', 'weekdays', '[]'::jsonb, 'assignee_strategy', 'nonpickup_adult', 'enabled', false),
        jsonb_build_object('task_code', 'smile_zemi', 'weekdays', '[]'::jsonb, 'assignee_strategy', 'nonpickup_adult', 'enabled', false),
        jsonb_build_object('task_code', 'media_30min', 'weekdays', '[]'::jsonb, 'assignee_strategy', 'nonpickup_adult', 'enabled', false)
      )
    );
    raise exception 'FAIL evening-setup: a row missing explicit enabled must be rejected';
  exception
    when others then
      if sqlerrm <> 'INVALID_INPUT' then
        raise exception 'FAIL evening-setup: expected INVALID_INPUT for missing enabled, got %', sqlerrm;
      end if;
  end;

  -- EV02: confirm_nonpickup -> rules_materialized, via a *complete* 7-item batch
  v_full_batch := jsonb_build_array(
    jsonb_build_object('task_code', 'dinner', 'weekdays', jsonb_build_array(1, 2, 3), 'assignee_strategy', 'nonpickup_adult', 'enabled', true),
    jsonb_build_object('task_code', 'bath', 'weekdays', '[]'::jsonb, 'assignee_strategy', 'nonpickup_adult', 'enabled', false),
    jsonb_build_object('task_code', 'laundry', 'weekdays', '[]'::jsonb, 'assignee_strategy', 'nonpickup_adult', 'enabled', false),
    jsonb_build_object('task_code', 'dishes', 'weekdays', '[]'::jsonb, 'assignee_strategy', 'nonpickup_adult', 'enabled', false),
    jsonb_build_object('task_code', 'cleaning', 'weekdays', '[]'::jsonb, 'assignee_strategy', 'nonpickup_adult', 'enabled', false),
    jsonb_build_object('task_code', 'smile_zemi', 'weekdays', '[]'::jsonb, 'assignee_strategy', 'nonpickup_adult', 'enabled', false),
    jsonb_build_object('task_code', 'media_30min', 'weekdays', '[]'::jsonb, 'assignee_strategy', 'nonpickup_adult', 'enabled', false)
  );

  v_op := gen_random_uuid();
  v_result := public.server_tx_configure_evening_routines(
    'f0000000-0000-0000-0000-000000000001', v_op, v_full_batch
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
    raise exception 'FAIL evening-setup: EV02 expected 3 active recurrence rules (Mon/Tue/Wed) for dinner, got %', v_instance_count;
  end if;

  select count(*) into v_instance_count
  from public.task_instances
  where household_id = v_hh_id and task_definition_id = v_task_id and status = 'todo';
  if v_instance_count = 0 then
    raise exception 'FAIL evening-setup: EV02 targeted materialization must have created task_instances for dinner';
  end if;

  -- nonpickup_adult resolver is WP3, not WP1: planned_assignee_id must stay
  -- null rather than guessing (03_DOMAIN_AND_DATA_MODEL.md #3).
  if exists (
    select 1 from public.task_instances
    where household_id = v_hh_id and task_definition_id = v_task_id and planned_assignee_id is not null
  ) then
    raise exception 'FAIL evening-setup: EV02 nonpickup_adult must not guess an assignee in WP1';
  end if;

  -- the other 6 disabled tasks materialized nothing
  if exists (
    select 1 from public.task_instances ti
    join public.task_definitions td on td.id = ti.task_definition_id
    where ti.household_id = v_hh_id and td.code in ('bath', 'laundry', 'dishes', 'cleaning', 'smile_zemi', 'media_30min')
  ) then
    raise exception 'FAIL evening-setup: EV02 disabled tasks in the same batch must not materialize any instance';
  end if;

  -- replay: same operation_id returns the same stored result, no duplicate rules
  v_result := public.server_tx_configure_evening_routines('f0000000-0000-0000-0000-000000000001', v_op, v_full_batch);
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
  v_full_batch jsonb;
begin
  select id into v_hh_id from public.households where name = 'Evening Setup HH';
  select id into v_task_id from public.task_definitions where household_id = v_hh_id and code = 'dinner';

  select id into v_old_rule_id from public.recurrence_rules
  where household_id = v_hh_id and task_definition_id = v_task_id and weekday = 1 and active;

  v_full_batch := jsonb_build_array(
    jsonb_build_object('task_code', 'dinner', 'weekdays', jsonb_build_array(1, 2, 3), 'assignee_strategy', 'fixed', 'fixed_assignee_id', 'f0000000-0000-0000-0000-000000000002', 'enabled', true),
    jsonb_build_object('task_code', 'bath', 'weekdays', '[]'::jsonb, 'assignee_strategy', 'nonpickup_adult', 'enabled', false),
    jsonb_build_object('task_code', 'laundry', 'weekdays', '[]'::jsonb, 'assignee_strategy', 'nonpickup_adult', 'enabled', false),
    jsonb_build_object('task_code', 'dishes', 'weekdays', '[]'::jsonb, 'assignee_strategy', 'nonpickup_adult', 'enabled', false),
    jsonb_build_object('task_code', 'cleaning', 'weekdays', '[]'::jsonb, 'assignee_strategy', 'nonpickup_adult', 'enabled', false),
    jsonb_build_object('task_code', 'smile_zemi', 'weekdays', '[]'::jsonb, 'assignee_strategy', 'nonpickup_adult', 'enabled', false),
    jsonb_build_object('task_code', 'media_30min', 'weekdays', '[]'::jsonb, 'assignee_strategy', 'nonpickup_adult', 'enabled', false)
  );

  perform public.server_tx_configure_evening_routines(
    'f0000000-0000-0000-0000-000000000001', gen_random_uuid(), v_full_batch
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
  where recurrence_rule_id = v_old_rule_id and scheduled_date >= (now() at time zone 'Asia/Tokyo')::date and status = 'todo';
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

-- EV03: disabled_task -> no_instance (a fully-disabled complete batch
-- materializes nothing for any of the 7 canonical evening tasks)
do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_full_batch jsonb;
begin
  insert into auth.users (id) values ('f0000000-0000-0000-0000-000000000003');
  v_hh := public.server_tx_create_household('f0000000-0000-0000-0000-000000000003', gen_random_uuid(), 'EV03 HH', 'Owner');
  v_hh_id := (v_hh->>'household_id')::uuid;

  v_full_batch := jsonb_build_array(
    jsonb_build_object('task_code', 'dinner', 'weekdays', '[]'::jsonb, 'assignee_strategy', 'nonpickup_adult', 'enabled', false),
    jsonb_build_object('task_code', 'bath', 'weekdays', jsonb_build_array(1, 2, 3, 4, 5), 'assignee_strategy', 'nonpickup_adult', 'enabled', false),
    jsonb_build_object('task_code', 'laundry', 'weekdays', '[]'::jsonb, 'assignee_strategy', 'nonpickup_adult', 'enabled', false),
    jsonb_build_object('task_code', 'dishes', 'weekdays', '[]'::jsonb, 'assignee_strategy', 'nonpickup_adult', 'enabled', false),
    jsonb_build_object('task_code', 'cleaning', 'weekdays', '[]'::jsonb, 'assignee_strategy', 'nonpickup_adult', 'enabled', false),
    jsonb_build_object('task_code', 'smile_zemi', 'weekdays', '[]'::jsonb, 'assignee_strategy', 'nonpickup_adult', 'enabled', false),
    jsonb_build_object('task_code', 'media_30min', 'weekdays', '[]'::jsonb, 'assignee_strategy', 'nonpickup_adult', 'enabled', false)
  );

  perform public.server_tx_configure_evening_routines(
    'f0000000-0000-0000-0000-000000000003', gen_random_uuid(), v_full_batch
  );

  if exists (
    select 1 from public.recurrence_rules rr
    join public.task_definitions td on td.id = rr.task_definition_id
    where rr.household_id = v_hh_id and td.code = 'bath' and rr.active
  ) then
    raise exception 'FAIL evening-setup: EV03 disabled bath must not create any active recurrence rule';
  end if;
  if exists (
    select 1 from public.task_instances ti
    join public.task_definitions td on td.id = ti.task_definition_id
    where ti.household_id = v_hh_id and td.code = 'bath'
  ) then
    raise exception 'FAIL evening-setup: EV03 disabled bath must not materialize any instance';
  end if;
  if exists (
    select 1 from public.evening_routine_preferences ep
    join public.task_definitions td on td.id = ep.task_definition_id
    where ep.household_id = v_hh_id and td.code = 'bath' and ep.enabled
  ) then
    raise exception 'FAIL evening-setup: EV03 evening_routine_preferences must record enabled=false for bath';
  end if;
end;
$$;

-- cross-household fixed_assignee_id is rejected
do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_outsider uuid := 'f0000000-0000-0000-0000-000000000099';
  v_full_batch jsonb;
begin
  insert into auth.users (id) values (v_outsider) on conflict do nothing;
  insert into auth.users (id) values ('f0000000-0000-0000-0000-000000000004');
  v_hh := public.server_tx_create_household('f0000000-0000-0000-0000-000000000004', gen_random_uuid(), 'Cross HH Guard', 'Owner');
  v_hh_id := (v_hh->>'household_id')::uuid;

  v_full_batch := jsonb_build_array(
    jsonb_build_object('task_code', 'dishes', 'weekdays', jsonb_build_array(1), 'assignee_strategy', 'fixed', 'fixed_assignee_id', v_outsider::text, 'enabled', true),
    jsonb_build_object('task_code', 'dinner', 'weekdays', '[]'::jsonb, 'assignee_strategy', 'nonpickup_adult', 'enabled', false),
    jsonb_build_object('task_code', 'bath', 'weekdays', '[]'::jsonb, 'assignee_strategy', 'nonpickup_adult', 'enabled', false),
    jsonb_build_object('task_code', 'laundry', 'weekdays', '[]'::jsonb, 'assignee_strategy', 'nonpickup_adult', 'enabled', false),
    jsonb_build_object('task_code', 'cleaning', 'weekdays', '[]'::jsonb, 'assignee_strategy', 'nonpickup_adult', 'enabled', false),
    jsonb_build_object('task_code', 'smile_zemi', 'weekdays', '[]'::jsonb, 'assignee_strategy', 'nonpickup_adult', 'enabled', false),
    jsonb_build_object('task_code', 'media_30min', 'weekdays', '[]'::jsonb, 'assignee_strategy', 'nonpickup_adult', 'enabled', false)
  );

  begin
    perform public.server_tx_configure_evening_routines(
      'f0000000-0000-0000-0000-000000000004', gen_random_uuid(), v_full_batch
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

-- P1 #4: Asia/Tokyo day-boundary correctness. The original bug used
-- `current_date` (the UTC session/transaction date on a UTC-configured
-- server) instead of converting through the household's fixed Asia/Tokyo
-- timezone. This proves the exact conversion the migration now uses
-- (`(now() at time zone 'Asia/Tokyo')::date`) gives the correct JST
-- calendar date at the stated boundary instant, and that it genuinely
-- differs from the naive UTC calendar date — i.e. this is a real boundary
-- the old code would have gotten wrong. (Freezing wall-clock `now()` inside
-- a live RPC call isn't possible in plain PostgreSQL without an extension,
-- so this verifies the formula directly rather than the live call.)
do $$
declare
  v_instant timestamptz := '2026-08-19 15:30:00+00';
  v_jst_date date;
  v_utc_date date;
begin
  v_jst_date := (v_instant at time zone 'Asia/Tokyo')::date;
  v_utc_date := v_instant::date;

  if v_jst_date <> date '2026-08-20' then
    raise exception 'FAIL evening-setup: 2026-08-19 15:30Z must convert to 2026-08-20 in Asia/Tokyo, got %', v_jst_date;
  end if;
  if v_utc_date <> date '2026-08-19' then
    raise exception 'FAIL evening-setup: sanity check failed, expected UTC calendar date 2026-08-19, got %', v_utc_date;
  end if;
  if v_jst_date = v_utc_date then
    raise exception 'FAIL evening-setup: boundary instant must differ between UTC and Asia/Tokyo calendar dates (test setup problem)';
  end if;
end;
$$;

select 'evening_routine_setup: PASS' as result;
