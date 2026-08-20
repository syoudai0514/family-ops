-- WP3: recurrence engine — role-based assignee resolution, change-recurrence
-- (version-bump-on-change / future-todo-only reconciliation / in_progress
-- preservation / RECURRENCE_OVERLAP), reassign-task-once.
-- supabase/migrations/20260819000023_recurrence_role_resolver.sql,
-- 20260819000024_change_recurrence.sql, 20260819000025_reassign_task_once.sql.
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('70000000-0000-0000-0000-000000000001'),
  ('70000000-0000-0000-0000-000000000002');

set role service_role;

-- ---------------------------------------------------------------------------
-- Setup: one household, two adults.
-- ---------------------------------------------------------------------------
do $$
declare
  v_hh jsonb;
begin
  v_hh := public.server_tx_create_household('70000000-0000-0000-0000-000000000001', gen_random_uuid(), 'Recurrence Engine HH', 'Owner');
  insert into public.household_members (household_id, user_id, member_role)
  values ((v_hh->>'household_id')::uuid, '70000000-0000-0000-0000-000000000002', 'adult');
end;
$$;

-- ---------------------------------------------------------------------------
-- Block 1: dropoff_assignee resolves to that day's dropoff assignee.
-- ---------------------------------------------------------------------------
do $$
declare
  v_hh_id uuid;
  v_dinner_def uuid;
  v_owner uuid := '70000000-0000-0000-0000-000000000001';
  v_partner uuid := '70000000-0000-0000-0000-000000000002';
  v_dropoff_result jsonb;
  v_dinner_result jsonb;
  v_dinner_instance record;
begin
  select id into v_hh_id from public.households where name = 'Recurrence Engine HH';
  select id into v_dinner_def from public.task_definitions where household_id = v_hh_id and code = 'dinner';

  -- dropoff fixed to owner on weekday 1
  v_dropoff_result := public.server_tx_change_recurrence(
    v_owner, gen_random_uuid(),
    (select id from public.task_definitions where household_id = v_hh_id and code = 'dropoff'),
    1, 'default', 'fixed', v_owner, '07:30', 60, null
  );

  -- dinner follows the dropoff assignee on weekday 1
  v_dinner_result := public.server_tx_change_recurrence(
    v_owner, gen_random_uuid(), v_dinner_def, 1, 'default', 'dropoff_assignee', null, '18:00', 60, null
  );

  select * into v_dinner_instance
  from public.task_instances
  where recurrence_rule_id = (v_dinner_result->>'rule_id')::uuid and status = 'todo'
  limit 1;

  if v_dinner_instance.planned_assignee_id is distinct from v_owner then
    raise exception 'FAIL recurrence-engine: dropoff_assignee-strategy dinner instance must resolve to the dropoff assignee, got %', v_dinner_instance.planned_assignee_id;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Block 2: role strategy with no same-day dropoff/pickup instance falls
-- back to null (never guess).
-- ---------------------------------------------------------------------------
do $$
declare
  v_hh_id uuid;
  v_bath_def uuid;
  v_owner uuid := '70000000-0000-0000-0000-000000000001';
  v_result jsonb;
  v_instance record;
begin
  select id into v_hh_id from public.households where name = 'Recurrence Engine HH';
  select id into v_bath_def from public.task_definitions where household_id = v_hh_id and code = 'bath';

  -- weekday 2 has no pickup rule configured at all for this household.
  v_result := public.server_tx_change_recurrence(
    v_owner, gen_random_uuid(), v_bath_def, 2, 'default', 'pickup_assignee', null, '19:00', 60, null
  );

  select * into v_instance
  from public.task_instances
  where recurrence_rule_id = (v_result->>'rule_id')::uuid and status = 'todo'
  limit 1;

  if v_instance.planned_assignee_id is not null then
    raise exception 'FAIL recurrence-engine: pickup_assignee with no same-day pickup instance must resolve to null, got %', v_instance.planned_assignee_id;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Block 3: nonpickup_adult resolves to the OTHER adult relative to that
-- day's pickup assignee.
-- ---------------------------------------------------------------------------
do $$
declare
  v_hh_id uuid;
  v_laundry_def uuid;
  v_owner uuid := '70000000-0000-0000-0000-000000000001';
  v_partner uuid := '70000000-0000-0000-0000-000000000002';
  v_laundry_result jsonb;
  v_instance record;
begin
  select id into v_hh_id from public.households where name = 'Recurrence Engine HH';
  select id into v_laundry_def from public.task_definitions where household_id = v_hh_id and code = 'laundry';

  -- pickup fixed to partner on weekday 3
  perform public.server_tx_change_recurrence(
    v_owner, gen_random_uuid(),
    (select id from public.task_definitions where household_id = v_hh_id and code = 'pickup'),
    3, 'default', 'fixed', v_partner, '16:30', 60, null
  );

  v_laundry_result := public.server_tx_change_recurrence(
    v_owner, gen_random_uuid(), v_laundry_def, 3, 'default', 'nonpickup_adult', null, '20:00', 60, null
  );

  select * into v_instance
  from public.task_instances
  where recurrence_rule_id = (v_laundry_result->>'rule_id')::uuid and status = 'todo'
  limit 1;

  if v_instance.planned_assignee_id is distinct from v_owner then
    raise exception 'FAIL recurrence-engine: nonpickup_adult must resolve to the adult who is NOT that day''s pickup assignee, got %', v_instance.planned_assignee_id;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Block 4: change-recurrence version-bump-on-change, future-todo-only
-- reconciliation, in_progress preservation.
-- ---------------------------------------------------------------------------
do $$
declare
  v_hh_id uuid;
  v_dishes_def uuid;
  v_owner uuid := '70000000-0000-0000-0000-000000000001';
  v_partner uuid := '70000000-0000-0000-0000-000000000002';
  v_v1_result jsonb;
  v_v2_result jsonb;
  v_v1_rule_id uuid;
  v_v2_rule_id uuid;
  v_in_progress_instance_id uuid;
  v_todo_instance_id uuid;
  v_old_rule record;
  v_new_todo record;
  v_preserved record;
begin
  select id into v_hh_id from public.households where name = 'Recurrence Engine HH';
  select id into v_dishes_def from public.task_definitions where household_id = v_hh_id and code = 'dishes';

  v_v1_result := public.server_tx_change_recurrence(
    v_owner, gen_random_uuid(), v_dishes_def, 4, 'default', 'fixed', v_owner, '19:30', 60, null
  );
  v_v1_rule_id := (v_v1_result->>'rule_id')::uuid;

  -- weekday 4 occurs (at least) twice inside the 14-day horizon; mark the
  -- earliest occurrence in_progress and leave the rest todo.
  select id into v_in_progress_instance_id
  from public.task_instances
  where recurrence_rule_id = v_v1_rule_id and status = 'todo'
  order by scheduled_date asc
  limit 1;

  update public.task_instances set status = 'in_progress' where id = v_in_progress_instance_id;

  select id into v_todo_instance_id
  from public.task_instances
  where recurrence_rule_id = v_v1_rule_id and status = 'todo'
  order by scheduled_date asc
  limit 1;

  if v_todo_instance_id is null then
    raise exception 'FAIL recurrence-engine: expected a second (still-todo) weekday-4 occurrence inside the 14-day horizon';
  end if;

  -- version bump: reassign dishes on weekday 4 to the partner.
  v_v2_result := public.server_tx_change_recurrence(
    v_owner, gen_random_uuid(), v_dishes_def, 4, 'default', 'fixed', v_partner, '19:30', 60, null
  );
  v_v2_rule_id := (v_v2_result->>'rule_id')::uuid;

  if v_v2_rule_id = v_v1_rule_id then
    raise exception 'FAIL recurrence-engine: change-recurrence must create a new rule row, not mutate the old one';
  end if;

  select * into v_old_rule from public.recurrence_rules where id = v_v1_rule_id;
  if v_old_rule.active or v_old_rule.effective_to is null or v_old_rule.version <> 1 then
    raise exception 'FAIL recurrence-engine: old rule must be closed (active=false, effective_to set), version unchanged';
  end if;

  select * into v_old_rule from public.recurrence_rules where id = v_v2_rule_id;
  if v_old_rule.version <> 2 or v_old_rule.supersedes_rule_id <> v_v1_rule_id then
    raise exception 'FAIL recurrence-engine: new rule must be version 2 and reference supersedes_rule_id';
  end if;

  -- in_progress instance is untouched: still linked to the OLD rule, still
  -- assigned to the owner, still in_progress.
  select * into v_preserved from public.task_instances where id = v_in_progress_instance_id;
  if v_preserved.status <> 'in_progress' or v_preserved.recurrence_rule_id <> v_v1_rule_id
     or v_preserved.planned_assignee_id is distinct from v_owner then
    raise exception 'FAIL recurrence-engine: in_progress instance must be preserved unchanged by a rule change';
  end if;

  -- the old todo instance must have been deleted and replaced by a new
  -- instance (same logical date) linked to the new rule, assigned to the
  -- partner.
  if exists (select 1 from public.task_instances where id = v_todo_instance_id) then
    raise exception 'FAIL recurrence-engine: old future todo instance must be deleted on rule change';
  end if;

  select * into v_new_todo
  from public.task_instances
  where recurrence_rule_id = v_v2_rule_id and status = 'todo'
  order by scheduled_date asc
  limit 1;
  if v_new_todo.planned_assignee_id is distinct from v_partner then
    raise exception 'FAIL recurrence-engine: reconciled todo instance must carry the new rule''s assignee';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Block 5: reassign-task-once happy path, TASK_TERMINAL, origin restriction.
-- ---------------------------------------------------------------------------
do $$
declare
  v_hh_id uuid;
  v_cleaning_def uuid;
  v_owner uuid := '70000000-0000-0000-0000-000000000001';
  v_partner uuid := '70000000-0000-0000-0000-000000000002';
  v_rule_result jsonb;
  v_instance_id uuid;
  v_manual_result jsonb;
  v_manual_task_id uuid;
  v_reassign_result jsonb;
  v_instance record;
begin
  select id into v_hh_id from public.households where name = 'Recurrence Engine HH';
  select id into v_cleaning_def from public.task_definitions where household_id = v_hh_id and code = 'cleaning';

  v_rule_result := public.server_tx_change_recurrence(
    v_owner, gen_random_uuid(), v_cleaning_def, 5, 'default', 'fixed', v_owner, null, 60, null
  );

  select id into v_instance_id
  from public.task_instances
  where recurrence_rule_id = (v_rule_result->>'rule_id')::uuid and status = 'todo'
  order by scheduled_date asc
  limit 1;

  v_reassign_result := public.server_tx_reassign_task_once(v_owner, gen_random_uuid(), v_instance_id, v_partner);
  if (v_reassign_result->>'new_assignee_user_id')::uuid <> v_partner then
    raise exception 'FAIL recurrence-engine: reassign-task-once result must echo the new assignee';
  end if;

  select * into v_instance from public.task_instances where id = v_instance_id;
  if v_instance.planned_assignee_id <> v_partner then
    raise exception 'FAIL recurrence-engine: reassign-task-once must update planned_assignee_id, got %', v_instance.planned_assignee_id;
  end if;
  if not exists (
    select 1 from public.task_events
    where task_instance_id = v_instance_id and event_type = 'reassigned_once'
  ) then
    raise exception 'FAIL recurrence-engine: reassign-task-once must emit a reassigned_once task_event';
  end if;

  -- the recurrence_rule itself must be untouched by a once-reassignment.
  if exists (
    select 1 from public.recurrence_rules
    where id = (v_rule_result->>'rule_id')::uuid and planned_assignee_id is distinct from v_owner
  ) then
    raise exception 'FAIL recurrence-engine: reassign-task-once must never modify the recurrence_rule';
  end if;

  -- TASK_TERMINAL once completed
  update public.task_instances set status = 'completed', completed_at = now() where id = v_instance_id;
  begin
    perform public.server_tx_reassign_task_once(v_owner, gen_random_uuid(), v_instance_id, v_owner);
    raise exception 'FAIL recurrence-engine: reassign-task-once on a completed task must raise TASK_TERMINAL';
  exception
    when others then
      if sqlerrm <> 'TASK_TERMINAL' then
        raise exception 'FAIL recurrence-engine: expected TASK_TERMINAL, got %', sqlerrm;
      end if;
  end;

  -- origin restriction: origin='manual' tasks are edit-task's territory, not reassign-once's.
  v_manual_result := public.server_tx_create_task(
    v_owner, gen_random_uuid(), 'Manual errand', 'todo', current_date, null, v_owner, 'whole', 'anytime', null
  );
  v_manual_task_id := (v_manual_result->>'task_id')::uuid;

  begin
    perform public.server_tx_reassign_task_once(v_owner, gen_random_uuid(), v_manual_task_id, v_partner);
    raise exception 'FAIL recurrence-engine: reassign-task-once on a manual-origin task must raise INVALID_INPUT';
  exception
    when others then
      if sqlerrm <> 'INVALID_INPUT' then
        raise exception 'FAIL recurrence-engine: expected INVALID_INPUT for manual-origin task, got %', sqlerrm;
      end if;
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- Block 6: RECURRENCE_OVERLAP surfaces through change-recurrence.
--
-- change-recurrence's own logic always closes the single currently-active
-- rule for a tuple before inserting a new version, so it can never
-- self-conflict in the common case (the true-parallel race that DOES
-- produce two genuinely concurrent active rows is covered separately by
-- scripts/run_concurrency_tests.sh). To exercise the RECURRENCE_OVERLAP
-- catch/translation path here, this directly constructs the (legal, if
-- unusual) state of two non-overlapping active rule windows for the same
-- tuple — e.g. one already-scheduled future change plus a nearer-term one
-- with a higher version number, which is exactly the shape a resolved
-- concurrent-insert race or a manual correction can leave behind — then
-- proves a further change-recurrence call whose new window overlaps the
-- still-active future one is rejected with RECURRENCE_OVERLAP rather than
-- silently violating the one-active-rule invariant.
-- ---------------------------------------------------------------------------
do $$
declare
  v_hh_id uuid;
  v_media_def uuid;
  v_owner uuid := '70000000-0000-0000-0000-000000000001';
  v_future_rule_id uuid := gen_random_uuid();
  v_nearterm_rule_id uuid := gen_random_uuid();
begin
  select id into v_hh_id from public.households where name = 'Recurrence Engine HH';
  select id into v_media_def from public.task_definitions where household_id = v_hh_id and code = 'media_30min';

  insert into public.recurrence_rules (
    id, household_id, task_definition_id, weekday, slot_key, assignee_strategy,
    planned_assignee_id, effective_from, effective_to, active, version, created_by
  ) values (
    v_future_rule_id, v_hh_id, v_media_def, 6, 'default', 'unassigned',
    null, current_date + 10, null, true, 1, v_owner
  );

  insert into public.recurrence_rules (
    id, household_id, task_definition_id, weekday, slot_key, assignee_strategy,
    planned_assignee_id, effective_from, effective_to, active, version, supersedes_rule_id, created_by
  ) values (
    v_nearterm_rule_id, v_hh_id, v_media_def, 6, 'default', 'unassigned',
    null, current_date, current_date + 2, true, 2, v_future_rule_id, v_owner
  );

  begin
    perform public.server_tx_change_recurrence(
      v_owner, gen_random_uuid(), v_media_def, 6, 'default', 'fixed', v_owner, null, 60, null
    );
    raise exception 'FAIL recurrence-engine: change-recurrence must raise RECURRENCE_OVERLAP when the new window collides with a still-active rule';
  exception
    when others then
      if sqlerrm <> 'RECURRENCE_OVERLAP' then
        raise exception 'FAIL recurrence-engine: expected RECURRENCE_OVERLAP, got %', sqlerrm;
      end if;
  end;
end;
$$;

reset role;
select 'recurrence_engine: PASS' as result;
