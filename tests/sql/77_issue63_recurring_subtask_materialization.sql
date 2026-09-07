-- Issue #63: recurring materialization must be able to insert child subtask rows.
-- Regression for fn_enforce_dd1b_child_test_context_v1 referencing a
-- table-specific NEW.calendar_connection_id on task_subtask_instances.
\set ON_ERROR_STOP on

insert into auth.users (id) values ('63990000-0000-0000-0000-000000000001');
set role service_role;

do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_def_id uuid := gen_random_uuid();
  v_subdef_id uuid := gen_random_uuid();
  v_rule_id uuid := gen_random_uuid();
  v_task_id uuid;
begin
  v_hh := public.server_tx_create_household(
    '63990000-0000-0000-0000-000000000001',
    gen_random_uuid(),
    'Issue63 Recurrence HH',
    'Owner'
  );
  v_hh_id := (v_hh ->> 'household_id')::uuid;

  insert into public.task_definitions (
    id, household_id, code, title, category, routine_phase,
    completion_mode, is_active, sort_order, created_by
  ) values (
    v_def_id, v_hh_id, 'issue63_laundry', '洗濯', 'housework', 'evening',
    'subtasks', true, 1, '63990000-0000-0000-0000-000000000001'
  );

  insert into public.task_subtask_definitions (
    id, household_id, task_definition_id, title, required, sort_order
  ) values (
    v_subdef_id, v_hh_id, v_def_id, '畳む', true, 1
  );

  insert into public.recurrence_rules (
    id, household_id, task_definition_id, weekday, slot_key,
    assignee_strategy, planned_assignee_id, scheduled_local_time,
    effective_from, effective_to, active, created_by
  ) values (
    v_rule_id, v_hh_id, v_def_id, 2, 'issue63',
    'fixed', '63990000-0000-0000-0000-000000000001', '20:00',
    '2026-09-01', null, true, '63990000-0000-0000-0000-000000000001'
  );

  perform private.materialize_recurrence_rule(
    v_hh_id, v_rule_id, '2026-09-08'::date, '2026-09-08'::date
  );

  select id into v_task_id
    from public.task_instances
   where household_id = v_hh_id
     and recurrence_rule_id = v_rule_id
     and scheduled_date = '2026-09-08'::date;

  if v_task_id is null then
    raise exception 'FAIL issue63: recurrence did not create parent task';
  end if;

  if (select count(*) from public.task_subtask_instances where task_instance_id = v_task_id) <> 1 then
    raise exception 'FAIL issue63: recurrence did not create the child checklist row';
  end if;

  if not exists (
    select 1 from public.task_subtask_instances
     where task_instance_id = v_task_id
       and title = '畳む'
       and not is_completed
  ) then
    raise exception 'FAIL issue63: expected fine-grained child checklist content';
  end if;
end;
$$;

reset role;
select 'issue63_recurring_subtask_materialization: PASS' as result;
