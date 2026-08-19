-- WP2: task_definitions CRUD — create/edit/deactivate.
-- docs/design/v6/18_MUTATION_CONTRACT_MATRIX.md #2.
\set ON_ERROR_STOP on

insert into auth.users (id) values ('50000000-0000-0000-0000-000000000001');

set role service_role;

do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_def_id uuid;
  v_result jsonb;
begin
  v_hh := public.server_tx_create_household('50000000-0000-0000-0000-000000000001', gen_random_uuid(), 'Task Def HH', 'Owner');
  v_hh_id := (v_hh->>'household_id')::uuid;

  -- create-task-definition happy path with subtasks
  v_result := public.server_tx_create_task_definition(
    '50000000-0000-0000-0000-000000000001', gen_random_uuid(), 'vacuum', 'Vacuum', 'chore', 'anytime', 'subtasks', 0,
    jsonb_build_array(jsonb_build_object('title', 'Living room', 'required', true, 'sort_order', 1))
  );
  v_def_id := (v_result->>'task_definition_id')::uuid;
  if v_def_id is null then
    raise exception 'FAIL task-def-mutations: create-task-definition must return a task_definition_id';
  end if;
  if (select count(*) from public.task_subtask_definitions where task_definition_id = v_def_id) <> 1 then
    raise exception 'FAIL task-def-mutations: subtask definitions must be persisted';
  end if;

  -- duplicate code is rejected as INVALID_INPUT (DB 23505 translated)
  begin
    perform public.server_tx_create_task_definition(
      '50000000-0000-0000-0000-000000000001', gen_random_uuid(), 'vacuum', 'Vacuum again', 'chore', 'anytime', 'whole', 0, null
    );
    raise exception 'FAIL task-def-mutations: duplicate code must be rejected';
  exception
    when others then
      if sqlerrm <> 'INVALID_INPUT' then
        raise exception 'FAIL task-def-mutations: expected INVALID_INPUT for duplicate code, got %', sqlerrm;
      end if;
  end;

  -- edit-task-definition happy path; code is not an accepted input at all
  perform public.server_tx_edit_task_definition(
    '50000000-0000-0000-0000-000000000001', gen_random_uuid(), v_def_id, 'Vacuum (weekly)', null, null, null, null
  );
  if (select title from public.task_definitions where id = v_def_id) <> 'Vacuum (weekly)' then
    raise exception 'FAIL task-def-mutations: edit-task-definition did not update title';
  end if;
  if (select code from public.task_definitions where id = v_def_id) <> 'vacuum' then
    raise exception 'FAIL task-def-mutations: code must remain immutable';
  end if;

  -- deactivate-task-definition happy path (no active recurrence rule references it)
  perform public.server_tx_deactivate_task_definition('50000000-0000-0000-0000-000000000001', gen_random_uuid(), v_def_id);
  if (select is_active from public.task_definitions where id = v_def_id) <> false then
    raise exception 'FAIL task-def-mutations: deactivate-task-definition did not set is_active=false';
  end if;
end;
$$;

-- deactivate is blocked while an active recurrence_rules row still references the definition
do $$
declare
  v_hh_id uuid;
  v_def_id uuid;
begin
  select id into v_hh_id from public.households where name = 'Task Def HH';
  select id into v_def_id from public.task_definitions where household_id = v_hh_id and code = 'dinner';

  insert into public.recurrence_rules
    (household_id, task_definition_id, weekday, slot_key, assignee_strategy, planned_assignee_id, effective_from, active, created_by)
  values
    (v_hh_id, v_def_id, 2, 'default', 'fixed', '50000000-0000-0000-0000-000000000001', current_date, true, '50000000-0000-0000-0000-000000000001');

  begin
    perform public.server_tx_deactivate_task_definition('50000000-0000-0000-0000-000000000001', gen_random_uuid(), v_def_id);
    raise exception 'FAIL task-def-mutations: deactivate must be rejected while an active recurrence_rules row references the definition';
  exception
    when others then
      if sqlerrm <> 'INVALID_INPUT' then
        raise exception 'FAIL task-def-mutations: expected INVALID_INPUT, got %', sqlerrm;
      end if;
  end;
end;
$$;

reset role;
select 'task_definition_mutations: PASS' as result;
