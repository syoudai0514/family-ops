-- WP2: task_definitions CRUD — create/edit/deactivate a household's task
-- templates. Same server_tx_* pattern as WP1.
--
-- Implementation decisions not pinned down by the v6 docs:
--   - a duplicate `code` on create-task-definition has no dedicated error
--     code in the catalogue; the DB's own unique(household_id, code)
--     violation (23505) is caught and translated to INVALID_INPUT.
--   - edit-task-definition never rewrites already-materialized
--     task_instances (those are permanent snapshots taken at materialize
--     time) — only the definition row itself changes.
--   - `code` is immutable after creation; edit-task-definition does not
--     accept it as an input at all.
--   - deactivate-task-definition is rejected while any active
--     recurrence_rules row still references the definition, forcing the
--     caller to retire the recurrence first — no v6 text specifies this,
--     but leaving is_active=false reachable while automation still
--     materializes instances from it would silently defeat the deactivation.

-- ---------------------------------------------------------------------------
-- create-task-definition
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_create_task_definition(
  p_actor_id uuid,
  p_operation_id uuid,
  p_code text,
  p_title text,
  p_category text,
  p_routine_phase text,
  p_completion_mode text,
  p_sort_order int,
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
  v_task_definition_id uuid;
  v_subtask jsonb;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null then
    raise exception 'INVALID_INPUT';
  end if;
  if coalesce(btrim(p_code), '') = '' or coalesce(btrim(p_title), '') = ''
     or coalesce(btrim(p_category), '') = '' then
    raise exception 'INVALID_INPUT';
  end if;
  if p_routine_phase not in ('morning', 'evening', 'anytime') then
    raise exception 'INVALID_INPUT';
  end if;
  if p_completion_mode not in ('whole', 'subtasks') then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to('create-task-definition|' || p_code || '|' || p_title, 'UTF8')),
    'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'create-task-definition', v_request_hash)
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

  begin
    insert into public.task_definitions
      (household_id, code, title, category, routine_phase, completion_mode, sort_order, created_by)
    values
      (v_household_id, btrim(p_code), btrim(p_title), btrim(p_category), p_routine_phase,
       p_completion_mode, coalesce(p_sort_order, 0), p_actor_id)
    returning id into v_task_definition_id;
  exception
    when unique_violation then
      raise exception 'INVALID_INPUT';
  end;

  if p_subtasks is not null and jsonb_typeof(p_subtasks) = 'array' then
    for v_subtask in select * from jsonb_array_elements(p_subtasks)
    loop
      if coalesce(btrim(v_subtask->>'title'), '') = '' then
        raise exception 'INVALID_INPUT';
      end if;
      insert into public.task_subtask_definitions
        (household_id, task_definition_id, title, required, sort_order)
      values (
        v_household_id, v_task_definition_id, btrim(v_subtask->>'title'),
        coalesce((v_subtask->>'required')::boolean, true),
        coalesce((v_subtask->>'sort_order')::int, 0)
      );
    end loop;
  end if;

  v_result := jsonb_build_object('task_definition_id', v_task_definition_id);

  update private.mutation_receipts
  set result_type = 'task_definition', result_id = v_task_definition_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_create_task_definition(uuid, uuid, text, text, text, text, text, int, jsonb) from public;
revoke all on function public.server_tx_create_task_definition(uuid, uuid, text, text, text, text, text, int, jsonb) from anon;
revoke all on function public.server_tx_create_task_definition(uuid, uuid, text, text, text, text, text, int, jsonb) from authenticated;
grant execute on function public.server_tx_create_task_definition(uuid, uuid, text, text, text, text, text, int, jsonb) to service_role;

-- ---------------------------------------------------------------------------
-- edit-task-definition
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_edit_task_definition(
  p_actor_id uuid,
  p_operation_id uuid,
  p_task_definition_id uuid,
  p_title text,
  p_category text,
  p_routine_phase text,
  p_completion_mode text,
  p_sort_order int
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
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_task_definition_id is null then
    raise exception 'INVALID_INPUT';
  end if;
  if p_routine_phase is not null and p_routine_phase not in ('morning', 'evening', 'anytime') then
    raise exception 'INVALID_INPUT';
  end if;
  if p_completion_mode is not null and p_completion_mode not in ('whole', 'subtasks') then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to(
      'edit-task-definition|' || p_task_definition_id::text || '|' || coalesce(p_title, '') || '|'
        || coalesce(p_category, '') || '|' || coalesce(p_routine_phase, '') || '|'
        || coalesce(p_completion_mode, '') || '|' || coalesce(p_sort_order::text, ''),
      'UTF8'
    )),
    'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'edit-task-definition', v_request_hash)
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

  if not exists (
    select 1 from public.task_definitions
    where household_id = v_household_id and id = p_task_definition_id
  ) then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  update public.task_definitions
  set
    title = coalesce(nullif(btrim(p_title), ''), title),
    category = coalesce(nullif(btrim(p_category), ''), category),
    routine_phase = coalesce(p_routine_phase, routine_phase),
    completion_mode = coalesce(p_completion_mode, completion_mode),
    sort_order = coalesce(p_sort_order, sort_order)
  where household_id = v_household_id and id = p_task_definition_id;

  v_result := jsonb_build_object('ok', true);

  update private.mutation_receipts
  set result_type = 'task_definition', result_id = p_task_definition_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_edit_task_definition(uuid, uuid, uuid, text, text, text, text, int) from public;
revoke all on function public.server_tx_edit_task_definition(uuid, uuid, uuid, text, text, text, text, int) from anon;
revoke all on function public.server_tx_edit_task_definition(uuid, uuid, uuid, text, text, text, text, int) from authenticated;
grant execute on function public.server_tx_edit_task_definition(uuid, uuid, uuid, text, text, text, text, int) to service_role;

-- ---------------------------------------------------------------------------
-- deactivate-task-definition
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_deactivate_task_definition(
  p_actor_id uuid,
  p_operation_id uuid,
  p_task_definition_id uuid
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
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_task_definition_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to('deactivate-task-definition|' || p_task_definition_id::text, 'UTF8')),
    'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'deactivate-task-definition', v_request_hash)
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

  if not exists (
    select 1 from public.task_definitions
    where household_id = v_household_id and id = p_task_definition_id
  ) then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  if exists (
    select 1 from public.recurrence_rules
    where household_id = v_household_id and task_definition_id = p_task_definition_id and active
  ) then
    raise exception 'INVALID_INPUT';
  end if;

  update public.task_definitions
  set is_active = false
  where household_id = v_household_id and id = p_task_definition_id;

  v_result := jsonb_build_object('ok', true);

  update private.mutation_receipts
  set result_type = 'task_definition', result_id = p_task_definition_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_deactivate_task_definition(uuid, uuid, uuid) from public;
revoke all on function public.server_tx_deactivate_task_definition(uuid, uuid, uuid) from anon;
revoke all on function public.server_tx_deactivate_task_definition(uuid, uuid, uuid) from authenticated;
grant execute on function public.server_tx_deactivate_task_definition(uuid, uuid, uuid) to service_role;
