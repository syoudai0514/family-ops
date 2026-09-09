-- Lane B / CF-06 + CF-07: duplicate resolution must update the matched
-- canonical entity with CAS and stable idempotency. A failed/stale update is
-- never allowed to fall through to create.

create or replace function public.server_tx_commit_concierge_duplicate_update(
  p_actor_id uuid,
  p_operation_id uuid,
  p_entity_kind text,
  p_entity_id uuid,
  p_expected_revision bigint,
  p_title text,
  p_scheduled_date date,
  p_due_local_time time,
  p_planned_assignee_user_id uuid default null
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_context jsonb;
  v_household_id uuid;
  v_request_hash text;
  v_receipt private.mutation_receipts%rowtype;
  v_task public.task_instances%rowtype;
  v_item public.shopping_items%rowtype;
  v_sub_operation_id uuid;
  v_revision bigint;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_entity_id is null
     or p_expected_revision is null or p_expected_revision < 1
     or coalesce(btrim(p_title), '') = ''
     or p_entity_kind not in ('task', 'shopping') then
    raise exception 'INVALID_INPUT';
  end if;

  v_context := private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id := (v_context->>'household_id')::uuid;

  if p_planned_assignee_user_id is not null and not exists (
    select 1 from public.household_members
    where household_id = v_household_id and user_id = p_planned_assignee_user_id
  ) then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  v_request_hash := encode(sha256(convert_to(
    'concierge-duplicate-update|' || p_entity_kind || '|' || p_entity_id::text || '|'
      || p_expected_revision::text || '|' || btrim(p_title) || '|'
      || coalesce(p_scheduled_date::text, '') || '|'
      || coalesce(p_due_local_time::text, '') || '|'
      || coalesce(p_planned_assignee_user_id::text, ''),
    'UTF8'
  )), 'hex');

  -- Claim before CAS. A response-lost retry therefore replays the original
  -- canonical result before looking at the now-advanced aggregate revision.
  loop
    insert into private.mutation_receipts(actor_id, operation_id, action_type, request_hash)
    values(p_actor_id, p_operation_id, 'concierge-duplicate-update', v_request_hash)
    on conflict(actor_id, operation_id) do nothing;
    if found then exit; end if;

    select * into v_receipt
    from private.mutation_receipts
    where actor_id = p_actor_id and operation_id = p_operation_id
    for update;

    if found then
      if v_receipt.action_type <> 'concierge-duplicate-update'
         or v_receipt.request_hash <> v_request_hash then
        raise exception 'IDEMPOTENCY_CONFLICT';
      end if;
      if v_receipt.result_payload is null then
        raise exception 'IDEMPOTENCY_INCOMPLETE';
      end if;
      return v_receipt.result_payload || jsonb_build_object('receipt', 'replay');
    end if;
  end loop;

  if p_entity_kind = 'task' then
    select * into v_task
    from public.task_instances
    where household_id = v_household_id
      and id = p_entity_id
      and test_context_id is null
    for update;
    if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
    if v_task.revision <> p_expected_revision then
      raise exception 'AGGREGATE_REVISION_CONFLICT';
    end if;
    if v_task.status not in ('todo', 'in_progress') then
      raise exception 'TASK_NOT_OPEN';
    end if;

    -- Keep the existing task/calendar mutation as the canonical writer. The
    -- derived operation is stable but private to this parent receipt.
    v_sub_operation_id := (md5(p_operation_id::text || ':concierge-task-edit'))::uuid;
    perform public.server_tx_edit_task_with_calendar(
      p_actor_id => p_actor_id,
      p_operation_id => v_sub_operation_id,
      p_task_id => p_entity_id,
      p_title => btrim(p_title),
      p_scheduled_date => p_scheduled_date,
      p_due_local_time => p_due_local_time,
      p_calendar_end_local_time => null,
      p_category => null,
      p_planned_assignee_user_id => p_planned_assignee_user_id,
      p_calendar_visibility => null
    );

    -- Legacy adapter revisions varied over the migration history. Guarantee
    -- the canonical CAS revision advances exactly when it did not already.
    update public.task_instances
    set revision = revision + 1
    where household_id = v_household_id
      and id = p_entity_id
      and revision = p_expected_revision;

    select revision into v_revision
    from public.task_instances
    where household_id = v_household_id and id = p_entity_id;
  else
    select * into v_item
    from public.shopping_items
    where household_id = v_household_id
      and id = p_entity_id
      and test_context_id is null
    for update;
    if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
    if v_item.revision <> p_expected_revision then
      raise exception 'AGGREGATE_REVISION_CONFLICT';
    end if;
    if v_item.status not in ('wanted', 'assigned', 'ordered') then
      raise exception 'INVALID_SHOPPING_TRANSITION';
    end if;

    update public.shopping_items
    set title = btrim(p_title),
        due_at = case
          when p_scheduled_date is null then due_at
          else (p_scheduled_date::text || ' 23:59:00+09')::timestamptz
        end,
        revision = revision + 1
    where household_id = v_household_id and id = p_entity_id
    returning revision into v_revision;
  end if;

  v_result := jsonb_build_object(
    'entity_kind', p_entity_kind,
    'entity_id', p_entity_id,
    'revision', v_revision
  );

  update private.mutation_receipts
  set result_type = p_entity_kind,
      result_id = p_entity_id,
      result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result || jsonb_build_object('receipt', 'committed');
end;
$$;

revoke all on function public.server_tx_commit_concierge_duplicate_update(
  uuid, uuid, text, uuid, bigint, text, date, time, uuid
) from public, anon, authenticated;
grant execute on function public.server_tx_commit_concierge_duplicate_update(
  uuid, uuid, text, uuid, bigint, text, date, time, uuid
) to service_role;
