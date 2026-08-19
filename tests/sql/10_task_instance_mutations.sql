-- WP2: task instance mutations — create/edit/cancel/complete-task,
-- set-subtask-completion. docs/design/v6/18_MUTATION_CONTRACT_MATRIX.md #1.
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('60000000-0000-0000-0000-000000000001'), -- owner
  ('60000000-0000-0000-0000-000000000002'); -- partner

set role service_role;

do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_task_id uuid;
  v_result jsonb;
  v_op uuid;
  v_row record;
begin
  v_hh := public.server_tx_create_household('60000000-0000-0000-0000-000000000001', gen_random_uuid(), 'Task Mutations HH', 'Owner');
  v_hh_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role)
  values (v_hh_id, '60000000-0000-0000-0000-000000000002', 'adult');

  -- create-task: whole mode, happy path
  v_op := gen_random_uuid();
  v_result := public.server_tx_create_task(
    '60000000-0000-0000-0000-000000000001', v_op, 'Take out trash', 'chore',
    (now() at time zone 'Asia/Tokyo')::date, '18:00'::time,
    '60000000-0000-0000-0000-000000000002', 'whole', 'anytime', null
  );
  v_task_id := (v_result->>'task_id')::uuid;
  if v_task_id is null then
    raise exception 'FAIL task-mutations: create-task must return a task_id';
  end if;
  select * into v_row from public.task_instances where id = v_task_id;
  if v_row.origin <> 'manual' or v_row.status <> 'todo' or v_row.planned_assignee_id <> '60000000-0000-0000-0000-000000000002'::uuid then
    raise exception 'FAIL task-mutations: create-task did not persist the expected row shape';
  end if;

  -- replay: same operation_id returns the same task, no duplicate row
  perform public.server_tx_create_task(
    '60000000-0000-0000-0000-000000000001', v_op, 'Take out trash', 'chore',
    (now() at time zone 'Asia/Tokyo')::date, '18:00'::time,
    '60000000-0000-0000-0000-000000000002', 'whole', 'anytime', null
  );
  if (select count(*) from public.task_instances where household_id = v_hh_id and title = 'Take out trash') <> 1 then
    raise exception 'FAIL task-mutations: replay of create-task must not create a duplicate row';
  end if;

  -- cross-household assignee rejected
  begin
    perform public.server_tx_create_task(
      '60000000-0000-0000-0000-000000000001', gen_random_uuid(), 'Bad assignee', 'chore',
      (now() at time zone 'Asia/Tokyo')::date, null, 'f0000000-0000-0000-0000-000000000099', 'whole', 'anytime', null
    );
    raise exception 'FAIL task-mutations: cross-household planned_assignee_user_id must be rejected';
  exception
    when others then
      if sqlerrm <> 'CROSS_HOUSEHOLD_RESOURCE' then
        raise exception 'FAIL task-mutations: expected CROSS_HOUSEHOLD_RESOURCE, got %', sqlerrm;
      end if;
  end;

  -- edit-task: happy path
  perform public.server_tx_edit_task(
    '60000000-0000-0000-0000-000000000001', gen_random_uuid(), v_task_id, 'Take out recycling', '19:00'::time, null
  );
  if (select title from public.task_instances where id = v_task_id) <> 'Take out recycling' then
    raise exception 'FAIL task-mutations: edit-task did not update title';
  end if;

  -- complete-task: whole mode
  perform public.server_tx_complete_task(
    '60000000-0000-0000-0000-000000000002', gen_random_uuid(), v_task_id, 'self', null
  );
  select * into v_row from public.task_instances where id = v_task_id;
  if v_row.status <> 'completed' or v_row.actual_completed_by_id <> '60000000-0000-0000-0000-000000000002'::uuid then
    raise exception 'FAIL task-mutations: complete-task (whole) did not set status/actual_completed_by_id correctly';
  end if;

  -- edit/cancel/complete on a terminal (completed) task is rejected
  begin
    perform public.server_tx_edit_task('60000000-0000-0000-0000-000000000001', gen_random_uuid(), v_task_id, 'x', null, null);
    raise exception 'FAIL task-mutations: edit-task on a completed task must be rejected';
  exception
    when others then
      if sqlerrm <> 'TASK_TERMINAL' then
        raise exception 'FAIL task-mutations: expected TASK_TERMINAL for edit on completed, got %', sqlerrm;
      end if;
  end;
  begin
    perform public.server_tx_cancel_task('60000000-0000-0000-0000-000000000001', gen_random_uuid(), v_task_id);
    raise exception 'FAIL task-mutations: cancel-task on a completed task must be rejected';
  exception
    when others then
      if sqlerrm <> 'TASK_TERMINAL' then
        raise exception 'FAIL task-mutations: expected TASK_TERMINAL for cancel on completed, got %', sqlerrm;
      end if;
  end;

  -- 'partner' resolves to the *other* household member
  v_op := gen_random_uuid();
  v_result := public.server_tx_create_task(
    '60000000-0000-0000-0000-000000000001', v_op, 'Partner task', 'chore',
    (now() at time zone 'Asia/Tokyo')::date, null, null, 'whole', 'anytime', null
  );
  v_task_id := (v_result->>'task_id')::uuid;
  perform public.server_tx_complete_task('60000000-0000-0000-0000-000000000001', gen_random_uuid(), v_task_id, 'partner', null);
  if (select actual_completed_by_id from public.task_instances where id = v_task_id) <> '60000000-0000-0000-0000-000000000002'::uuid then
    raise exception 'FAIL task-mutations: completion_actor=partner must resolve to the other household member';
  end if;

  -- cancel-task happy path
  v_result := public.server_tx_create_task(
    '60000000-0000-0000-0000-000000000001', gen_random_uuid(), 'Cancel me', 'chore',
    (now() at time zone 'Asia/Tokyo')::date, null, null, 'whole', 'anytime', null
  );
  v_task_id := (v_result->>'task_id')::uuid;
  perform public.server_tx_cancel_task('60000000-0000-0000-0000-000000000001', gen_random_uuid(), v_task_id);
  if (select status from public.task_instances where id = v_task_id) <> 'cancelled' then
    raise exception 'FAIL task-mutations: cancel-task did not set status=cancelled';
  end if;
end;
$$;

-- subtasks-mode: create, per-subtask completion, auto-complete/auto-revert
do $$
declare
  v_hh_id uuid;
  v_task_id uuid;
  v_result jsonb;
  v_subtask_1 uuid;
  v_subtask_2 uuid;
begin
  select id into v_hh_id from public.households where name = 'Task Mutations HH';

  v_result := public.server_tx_create_task(
    '60000000-0000-0000-0000-000000000001', gen_random_uuid(), 'Laundry', 'chore',
    (now() at time zone 'Asia/Tokyo')::date, null, null, 'subtasks', 'anytime',
    jsonb_build_array(
      jsonb_build_object('title', 'Wash', 'required', true, 'sort_order', 1),
      jsonb_build_object('title', 'Fold', 'required', true, 'sort_order', 2)
    )
  );
  v_task_id := (v_result->>'task_id')::uuid;

  if (select count(*) from public.task_subtask_instances where task_instance_id = v_task_id) <> 2 then
    raise exception 'FAIL task-mutations: create-task (subtasks) must create 2 subtask rows';
  end if;

  select id into v_subtask_1 from public.task_subtask_instances where task_instance_id = v_task_id and title = 'Wash';
  select id into v_subtask_2 from public.task_subtask_instances where task_instance_id = v_task_id and title = 'Fold';

  -- direct complete-task on a subtasks-mode task without the force flag is rejected
  begin
    perform public.server_tx_complete_task('60000000-0000-0000-0000-000000000001', gen_random_uuid(), v_task_id, 'self', null);
    raise exception 'FAIL task-mutations: complete-task on subtasks-mode without complete_remaining_subtasks must be rejected';
  exception
    when others then
      if sqlerrm <> 'INVALID_INPUT' then
        raise exception 'FAIL task-mutations: expected INVALID_INPUT, got %', sqlerrm;
      end if;
  end;

  -- completing the first (but not last) required subtask leaves the task in_progress
  perform public.server_tx_set_subtask_completion('60000000-0000-0000-0000-000000000001', gen_random_uuid(), v_subtask_1, true, 'self');
  if (select status from public.task_instances where id = v_task_id) = 'completed' then
    raise exception 'FAIL task-mutations: task must not auto-complete while a required subtask remains';
  end if;

  -- completing the last required subtask auto-completes the parent, actual_completed_by_id stays null
  perform public.server_tx_set_subtask_completion('60000000-0000-0000-0000-000000000002', gen_random_uuid(), v_subtask_2, true, 'self');
  if (select status from public.task_instances where id = v_task_id) <> 'completed' then
    raise exception 'FAIL task-mutations: task must auto-complete once every required subtask is done';
  end if;
  if (select actual_completed_by_id from public.task_instances where id = v_task_id) is not null then
    raise exception 'FAIL task-mutations: actual_completed_by_id must stay null for completion_mode=subtasks (DB CHECK invariant)';
  end if;

  -- uncompleting a subtask reverts the auto-completed parent to in_progress
  perform public.server_tx_set_subtask_completion('60000000-0000-0000-0000-000000000002', gen_random_uuid(), v_subtask_2, false, 'self');
  if (select status from public.task_instances where id = v_task_id) <> 'in_progress' then
    raise exception 'FAIL task-mutations: uncompleting a required subtask must revert the parent to in_progress';
  end if;

  -- force-complete via complete_remaining_subtasks=true completes every remaining required subtask
  perform public.server_tx_complete_task('60000000-0000-0000-0000-000000000001', gen_random_uuid(), v_task_id, 'self', true);
  if (select status from public.task_instances where id = v_task_id) <> 'completed' then
    raise exception 'FAIL task-mutations: complete-task with complete_remaining_subtasks=true must complete the task';
  end if;
  if exists (select 1 from public.task_subtask_instances where task_instance_id = v_task_id and required and not is_completed) then
    raise exception 'FAIL task-mutations: complete_remaining_subtasks=true must force-complete every remaining required subtask';
  end if;
end;
$$;

-- anon/authenticated cannot execute these RPCs directly
reset role;
set role authenticated;
set request.jwt.claim.sub = '60000000-0000-0000-0000-000000000001';
do $$
begin
  begin
    perform public.server_tx_create_task(
      '60000000-0000-0000-0000-000000000001', gen_random_uuid(), 'x', 'chore', current_date, null, null, 'whole', 'anytime', null
    );
    raise exception 'FAIL task-mutations: authenticated must not execute server_tx_create_task directly';
  exception
    when insufficient_privilege then null;
  end;
end;
$$;
reset role;
reset request.jwt.claim.sub;

select 'task_instance_mutations: PASS' as result;
