-- WP2: task instance mutations — create/edit/cancel/complete a manual task,
-- and per-subtask completion. Same server_tx_* pattern as WP1
-- (private.mutation_receipts claim-then-fill idempotency, SECURITY INVOKER,
-- EXECUTE revoked from public/anon/authenticated, granted to service_role
-- only). docs/design/v6/18_MUTATION_CONTRACT_MATRIX.md #1.
--
-- Implementation decisions not pinned down by the v6 docs (flagged here,
-- not silently assumed):
--   - task_instances.category is NOT NULL but 18_MUTATION_CONTRACT_MATRIX's
--     create-task input list omits it; category is accepted as an optional
--     input and defaults to 'todo' when omitted.
--   - edit-task is restricted to origin='manual' tasks (recurring/request/
--     calendar_assist-origin instances only ever get reassigned via the
--     WP3 reassign-once endpoint, never retitled/rescheduled here).
--   - edit-task/cancel-task treat any status other than 'todo'/'in_progress'
--     as terminal (completed/cancelled/skipped all reject with TASK_TERMINAL),
--     even though the doc text only names completed/cancelled explicitly.
--   - edit-task's optional fields use NULL = "leave unchanged" (coalesce);
--     there is no way to clear an existing due time or unassign via
--     edit-task in WP2 — an explicit "unassign" affordance is out of scope.
--   - set-subtask-completion's parent-recalculation-on-uncomplete target is
--     'in_progress' (not 'todo'): at least one subtask is still done, so
--     the task is not literally untouched.

-- ---------------------------------------------------------------------------
-- create-task
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_create_task(
  p_actor_id uuid,
  p_operation_id uuid,
  p_title text,
  p_category text,
  p_scheduled_date date,
  p_due_local_time time,
  p_planned_assignee_user_id uuid,
  p_completion_mode text,
  p_routine_phase text,
  p_subtasks jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_request_hash text;
  v_receipt record;
  v_household_id uuid;
  v_category text := coalesce(nullif(btrim(p_category), ''), 'todo');
  v_routine_phase text := coalesce(p_routine_phase, 'anytime');
  v_due_at timestamptz;
  v_task_id uuid;
  v_subtask jsonb;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null then
    raise exception 'INVALID_INPUT';
  end if;
  if coalesce(btrim(p_title), '') = '' or p_scheduled_date is null then
    raise exception 'INVALID_INPUT';
  end if;
  if p_completion_mode not in ('whole', 'subtasks') then
    raise exception 'INVALID_INPUT';
  end if;
  if v_routine_phase not in ('morning', 'evening', 'anytime') then
    raise exception 'INVALID_INPUT';
  end if;
  if p_completion_mode = 'subtasks'
     and (p_subtasks is null or jsonb_typeof(p_subtasks) <> 'array' or jsonb_array_length(p_subtasks) = 0) then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to(
      'create-task|' || p_title || '|' || p_scheduled_date::text || '|' || p_completion_mode
        || '|' || coalesce(p_subtasks::text, ''),
      'UTF8'
    )),
    'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'create-task', v_request_hash)
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

  if p_planned_assignee_user_id is not null and not exists (
    select 1 from public.household_members
    where household_id = v_household_id and user_id = p_planned_assignee_user_id
  ) then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  if p_due_local_time is not null then
    v_due_at := (p_scheduled_date::text || ' ' || p_due_local_time::text)::timestamp
      at time zone 'Asia/Tokyo';
  end if;

  insert into public.task_instances (
    household_id, task_definition_id, recurrence_rule_id, logical_occurrence_key,
    origin, title, category, routine_phase, scheduled_date, due_at,
    planned_assignee_id, completion_mode, status, source, created_by
  )
  values (
    v_household_id, null, null, null,
    'manual', btrim(p_title), v_category, v_routine_phase, p_scheduled_date, v_due_at,
    p_planned_assignee_user_id, p_completion_mode, 'todo', 'manual', p_actor_id
  )
  returning id into v_task_id;

  if p_completion_mode = 'subtasks' then
    for v_subtask in select * from jsonb_array_elements(p_subtasks)
    loop
      if coalesce(btrim(v_subtask->>'title'), '') = '' then
        raise exception 'INVALID_INPUT';
      end if;
      insert into public.task_subtask_instances
        (household_id, task_instance_id, source_definition_id, title, required, sort_order)
      values (
        v_household_id, v_task_id, null, btrim(v_subtask->>'title'),
        coalesce((v_subtask->>'required')::boolean, true),
        coalesce((v_subtask->>'sort_order')::int, 0)
      );
    end loop;
  end if;

  insert into public.task_events
    (household_id, task_instance_id, actor_id, event_type, source, idempotency_key)
  values
    (v_household_id, v_task_id, p_actor_id, 'created', 'pwa', p_operation_id::text || ':created');

  v_result := jsonb_build_object('task_id', v_task_id);

  update private.mutation_receipts
  set result_type = 'task_instance', result_id = v_task_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_create_task(uuid, uuid, text, text, date, time, uuid, text, text, jsonb) from public;
revoke all on function public.server_tx_create_task(uuid, uuid, text, text, date, time, uuid, text, text, jsonb) from anon;
revoke all on function public.server_tx_create_task(uuid, uuid, text, text, date, time, uuid, text, text, jsonb) from authenticated;
grant execute on function public.server_tx_create_task(uuid, uuid, text, text, date, time, uuid, text, text, jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- edit-task
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_edit_task(
  p_actor_id uuid,
  p_operation_id uuid,
  p_task_id uuid,
  p_title text,
  p_due_local_time time,
  p_planned_assignee_user_id uuid
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_request_hash text;
  v_receipt record;
  v_household_id uuid;
  v_task record;
  v_due_at timestamptz;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_task_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to(
      'edit-task|' || p_task_id::text || '|' || coalesce(p_title, '') || '|'
        || coalesce(p_due_local_time::text, '') || '|' || coalesce(p_planned_assignee_user_id::text, ''),
      'UTF8'
    )),
    'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'edit-task', v_request_hash)
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

  if p_planned_assignee_user_id is not null and not exists (
    select 1 from public.household_members
    where household_id = v_household_id and user_id = p_planned_assignee_user_id
  ) then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  select * into v_task
  from public.task_instances
  where household_id = v_household_id and id = p_task_id
  for update;

  if not found then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;
  if v_task.origin <> 'manual' then
    raise exception 'INVALID_INPUT';
  end if;
  if v_task.status not in ('todo', 'in_progress') then
    raise exception 'TASK_TERMINAL';
  end if;

  if p_due_local_time is not null then
    v_due_at := (v_task.scheduled_date::text || ' ' || p_due_local_time::text)::timestamp
      at time zone 'Asia/Tokyo';
  else
    v_due_at := v_task.due_at;
  end if;

  update public.task_instances
  set
    title = coalesce(nullif(btrim(p_title), ''), title),
    due_at = v_due_at,
    planned_assignee_id = coalesce(p_planned_assignee_user_id, planned_assignee_id)
  where household_id = v_household_id and id = p_task_id;

  insert into public.task_events
    (household_id, task_instance_id, actor_id, event_type, source, idempotency_key)
  values
    (v_household_id, p_task_id, p_actor_id, 'edited', 'pwa', p_operation_id::text || ':edited');

  v_result := jsonb_build_object('ok', true);

  update private.mutation_receipts
  set result_type = 'task_instance', result_id = p_task_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_edit_task(uuid, uuid, uuid, text, time, uuid) from public;
revoke all on function public.server_tx_edit_task(uuid, uuid, uuid, text, time, uuid) from anon;
revoke all on function public.server_tx_edit_task(uuid, uuid, uuid, text, time, uuid) from authenticated;
grant execute on function public.server_tx_edit_task(uuid, uuid, uuid, text, time, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- cancel-task
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_cancel_task(
  p_actor_id uuid,
  p_operation_id uuid,
  p_task_id uuid
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_request_hash text;
  v_receipt record;
  v_household_id uuid;
  v_task record;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_task_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(sha256(convert_to('cancel-task|' || p_task_id::text, 'UTF8')), 'hex');

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'cancel-task', v_request_hash)
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

  select * into v_task
  from public.task_instances
  where household_id = v_household_id and id = p_task_id
  for update;

  if not found then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;
  if v_task.status not in ('todo', 'in_progress') then
    raise exception 'TASK_TERMINAL';
  end if;

  update public.task_instances
  set status = 'cancelled'
  where household_id = v_household_id and id = p_task_id;

  insert into public.task_events
    (household_id, task_instance_id, actor_id, event_type, source, idempotency_key)
  values
    (v_household_id, p_task_id, p_actor_id, 'cancelled', 'pwa', p_operation_id::text || ':cancelled');

  v_result := jsonb_build_object('ok', true);

  update private.mutation_receipts
  set result_type = 'task_instance', result_id = p_task_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_cancel_task(uuid, uuid, uuid) from public;
revoke all on function public.server_tx_cancel_task(uuid, uuid, uuid) from anon;
revoke all on function public.server_tx_cancel_task(uuid, uuid, uuid) from authenticated;
grant execute on function public.server_tx_cancel_task(uuid, uuid, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- complete-task
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_complete_task(
  p_actor_id uuid,
  p_operation_id uuid,
  p_task_id uuid,
  p_completion_actor text,
  p_complete_remaining_subtasks boolean
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_request_hash text;
  v_receipt record;
  v_household_id uuid;
  v_task record;
  v_resolved_actor uuid;
  v_result jsonb;
  v_request record;
begin
  if p_actor_id is null or p_operation_id is null or p_task_id is null then
    raise exception 'INVALID_INPUT';
  end if;
  if p_completion_actor not in ('self', 'partner') then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to(
      'complete-task|' || p_task_id::text || '|' || p_completion_actor || '|'
        || coalesce(p_complete_remaining_subtasks::text, ''),
      'UTF8'
    )),
    'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'complete-task', v_request_hash)
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

  select * into v_task
  from public.task_instances
  where household_id = v_household_id and id = p_task_id
  for update;

  if not found then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;
  if v_task.status not in ('todo', 'in_progress') then
    raise exception 'TASK_TERMINAL';
  end if;

  if v_task.completion_mode = 'whole' then
    update public.task_instances
    set status = 'completed', completed_at = now(), actual_completed_by_id = v_resolved_actor
    where household_id = v_household_id and id = p_task_id;
  else
    if coalesce(p_complete_remaining_subtasks, false) is not true then
      raise exception 'INVALID_INPUT';
    end if;

    perform 1 from public.task_subtask_instances
    where household_id = v_household_id and task_instance_id = p_task_id
    for update;

    update public.task_subtask_instances
    set is_completed = true, completed_by = v_resolved_actor, completed_at = now()
    where household_id = v_household_id and task_instance_id = p_task_id
      and required and not is_completed;

    -- completion_mode='subtasks' requires actual_completed_by_id to stay
    -- null (DB CHECK constraint) — the parent is "who did the last bit"
    -- only in the per-subtask completed_by columns, never here.
    update public.task_instances
    set status = 'completed', completed_at = now()
    where household_id = v_household_id and id = p_task_id;
  end if;

  -- an accepted request linked to this task follows the task's lifecycle
  select * into v_request
  from public.requests
  where household_id = v_household_id and linked_task_instance_id = p_task_id and status = 'accepted'
  for update;

  if found then
    update public.requests
    set status = 'completed', completed_at = now()
    where household_id = v_household_id and id = v_request.id;
  end if;

  insert into public.task_events
    (household_id, task_instance_id, actor_id, event_type, source, idempotency_key)
  values
    (v_household_id, p_task_id, p_actor_id, 'completed', 'pwa', p_operation_id::text || ':completed');

  v_result := jsonb_build_object('ok', true);

  update private.mutation_receipts
  set result_type = 'task_instance', result_id = p_task_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_complete_task(uuid, uuid, uuid, text, boolean) from public;
revoke all on function public.server_tx_complete_task(uuid, uuid, uuid, text, boolean) from anon;
revoke all on function public.server_tx_complete_task(uuid, uuid, uuid, text, boolean) from authenticated;
grant execute on function public.server_tx_complete_task(uuid, uuid, uuid, text, boolean) to service_role;

-- ---------------------------------------------------------------------------
-- set-subtask-completion
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_set_subtask_completion(
  p_actor_id uuid,
  p_operation_id uuid,
  p_subtask_instance_id uuid,
  p_completed boolean,
  p_completion_actor text
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_request_hash text;
  v_receipt record;
  v_household_id uuid;
  v_subtask record;
  v_task record;
  v_resolved_actor uuid;
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
    -- Uncompleting is allowed even when the parent is already 'completed'
    -- (status in ('todo','in_progress','completed') is already enforced
    -- above): that is exactly the case that must revert a subtasks-mode
    -- task back to 'in_progress' below. 'cancelled'/'skipped' parents are
    -- already excluded by the check above.
    update public.task_subtask_instances
    set is_completed = false, completed_by = null, completed_at = null
    where household_id = v_household_id and id = p_subtask_instance_id;
  end if;

  select count(*) into v_remaining_required
  from public.task_subtask_instances
  where household_id = v_household_id and task_instance_id = v_task.id
    and required and not is_completed;

  if v_remaining_required = 0 and v_task.status <> 'completed' then
    update public.task_instances
    set status = 'completed', completed_at = now()
    where household_id = v_household_id and id = v_task.id;
  elsif v_remaining_required > 0 and v_task.status = 'completed' then
    update public.task_instances
    set status = 'in_progress', completed_at = null
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

revoke all on function public.server_tx_set_subtask_completion(uuid, uuid, uuid, boolean, text) from public;
revoke all on function public.server_tx_set_subtask_completion(uuid, uuid, uuid, boolean, text) from anon;
revoke all on function public.server_tx_set_subtask_completion(uuid, uuid, uuid, boolean, text) from authenticated;
grant execute on function public.server_tx_set_subtask_completion(uuid, uuid, uuid, boolean, text) to service_role;
