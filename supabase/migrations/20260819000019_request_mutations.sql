-- WP2: request lifecycle — send/accept/decline/cancel.
-- docs/design/v6/18_MUTATION_CONTRACT_MATRIX.md request section;
-- 03_DOMAIN_AND_DATA_MODEL.md requests state machine.
--
-- "Pending-only cancel" is enforced twice, deliberately: the RPC checks
-- status='pending' before mutating (raising REQUEST_CANCEL_NOT_ALLOWED
-- otherwise), AND the requests table's own CHECK constraint makes
-- 'cancelled' structurally unreachable once accepted_at is set — so even a
-- bug in this RPC's status check could never produce a request that is
-- both cancelled and previously-accepted.
--
-- accept-request auto-creates the linked task; field mapping is an
-- implementation decision not pinned down by any v6 doc:
--   - planned_assignee_id = the accepting recipient (they're the one
--     taking it on)
--   - scheduled_date = requests.due_at's Asia/Tokyo date if present, else
--     today (Asia/Tokyo)
--   - completion_mode = 'whole' (requests have no subtask concept)
--   - category = 'todo', routine_phase = 'anytime' (same default as
--     create-task's own undocumented category input)

-- ---------------------------------------------------------------------------
-- send-request
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_send_request(
  p_actor_id uuid,
  p_operation_id uuid,
  p_recipient_user_id uuid,
  p_shared_title text,
  p_shared_message text,
  p_due_at timestamptz
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
  v_request_id uuid;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_recipient_user_id is null then
    raise exception 'INVALID_INPUT';
  end if;
  if coalesce(btrim(p_shared_title), '') = '' then
    raise exception 'INVALID_INPUT';
  end if;
  if p_recipient_user_id = p_actor_id then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to(
      'send-request|' || p_recipient_user_id::text || '|' || p_shared_title,
      'UTF8'
    )),
    'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'send-request', v_request_hash)
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
    select 1 from public.household_members
    where household_id = v_household_id and user_id = p_recipient_user_id
  ) then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  insert into public.requests
    (household_id, requester_id, recipient_id, shared_title, shared_message, due_at, status)
  values
    (v_household_id, p_actor_id, p_recipient_user_id, btrim(p_shared_title),
     nullif(btrim(coalesce(p_shared_message, '')), ''), p_due_at, 'pending')
  returning id into v_request_id;

  insert into public.user_notifications
    (household_id, recipient_user_id, type, title, body, dedup_key)
  values
    (v_household_id, p_recipient_user_id, 'request_received', p_shared_title,
     coalesce(nullif(btrim(p_shared_message), ''), p_shared_title),
     p_operation_id::text || ':request_received');

  v_result := jsonb_build_object('request_id', v_request_id);

  update private.mutation_receipts
  set result_type = 'request', result_id = v_request_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_send_request(uuid, uuid, uuid, text, text, timestamptz) from public;
revoke all on function public.server_tx_send_request(uuid, uuid, uuid, text, text, timestamptz) from anon;
revoke all on function public.server_tx_send_request(uuid, uuid, uuid, text, text, timestamptz) from authenticated;
grant execute on function public.server_tx_send_request(uuid, uuid, uuid, text, text, timestamptz) to service_role;

-- ---------------------------------------------------------------------------
-- accept-request
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_accept_request(
  p_actor_id uuid,
  p_operation_id uuid,
  p_request_id uuid
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
  v_request record;
  v_task_id uuid;
  v_scheduled_date date;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_request_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(sha256(convert_to('accept-request|' || p_request_id::text, 'UTF8')), 'hex');

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'accept-request', v_request_hash)
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

  select * into v_request
  from public.requests
  where household_id = v_household_id and id = p_request_id
  for update;

  if not found then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;
  if v_request.recipient_id <> p_actor_id then
    raise exception 'REQUEST_NOT_RECIPIENT';
  end if;
  if v_request.status <> 'pending' then
    raise exception 'REQUEST_NOT_PENDING';
  end if;

  if v_request.due_at is not null then
    v_scheduled_date := (v_request.due_at at time zone 'Asia/Tokyo')::date;
  else
    v_scheduled_date := (now() at time zone 'Asia/Tokyo')::date;
  end if;

  insert into public.task_instances (
    household_id, task_definition_id, recurrence_rule_id, logical_occurrence_key,
    origin, title, category, routine_phase, scheduled_date, due_at,
    planned_assignee_id, completion_mode, status, source, created_by
  )
  values (
    v_household_id, null, null, null,
    'request', v_request.shared_title, 'todo', 'anytime', v_scheduled_date, v_request.due_at,
    p_actor_id, 'whole', 'todo', 'request', p_actor_id
  )
  returning id into v_task_id;

  update public.requests
  set status = 'accepted', accepted_at = now(), linked_task_instance_id = v_task_id
  where household_id = v_household_id and id = p_request_id;

  insert into public.task_events
    (household_id, task_instance_id, actor_id, event_type, source, idempotency_key)
  values
    (v_household_id, v_task_id, p_actor_id, 'created', 'request', p_operation_id::text || ':created');

  insert into public.user_notifications
    (household_id, recipient_user_id, type, title, body, dedup_key)
  values
    (v_household_id, v_request.requester_id, 'request_accepted', v_request.shared_title,
     v_request.shared_title, p_operation_id::text || ':request_accepted');

  v_result := jsonb_build_object('task_id', v_task_id);

  update private.mutation_receipts
  set result_type = 'request', result_id = p_request_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_accept_request(uuid, uuid, uuid) from public;
revoke all on function public.server_tx_accept_request(uuid, uuid, uuid) from anon;
revoke all on function public.server_tx_accept_request(uuid, uuid, uuid) from authenticated;
grant execute on function public.server_tx_accept_request(uuid, uuid, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- decline-request
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_decline_request(
  p_actor_id uuid,
  p_operation_id uuid,
  p_request_id uuid
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
  v_request record;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_request_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(sha256(convert_to('decline-request|' || p_request_id::text, 'UTF8')), 'hex');

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'decline-request', v_request_hash)
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

  select * into v_request
  from public.requests
  where household_id = v_household_id and id = p_request_id
  for update;

  if not found then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;
  if v_request.recipient_id <> p_actor_id then
    raise exception 'REQUEST_NOT_RECIPIENT';
  end if;
  if v_request.status <> 'pending' then
    raise exception 'REQUEST_NOT_PENDING';
  end if;

  update public.requests
  set status = 'declined', declined_at = now()
  where household_id = v_household_id and id = p_request_id;

  insert into public.user_notifications
    (household_id, recipient_user_id, type, title, body, dedup_key)
  values
    (v_household_id, v_request.requester_id, 'request_declined', v_request.shared_title,
     v_request.shared_title, p_operation_id::text || ':request_declined');

  v_result := jsonb_build_object('ok', true);

  update private.mutation_receipts
  set result_type = 'request', result_id = p_request_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_decline_request(uuid, uuid, uuid) from public;
revoke all on function public.server_tx_decline_request(uuid, uuid, uuid) from anon;
revoke all on function public.server_tx_decline_request(uuid, uuid, uuid) from authenticated;
grant execute on function public.server_tx_decline_request(uuid, uuid, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- cancel-request (requester-only, pending-only)
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_cancel_request(
  p_actor_id uuid,
  p_operation_id uuid,
  p_request_id uuid
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
  v_request record;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_request_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(sha256(convert_to('cancel-request|' || p_request_id::text, 'UTF8')), 'hex');

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'cancel-request', v_request_hash)
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

  select * into v_request
  from public.requests
  where household_id = v_household_id and id = p_request_id
  for update;

  if not found then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;
  if v_request.requester_id <> p_actor_id then
    raise exception 'REQUEST_NOT_REQUESTER';
  end if;
  -- The DB's own CHECK constraint on requests already makes 'cancelled'
  -- structurally unreachable once accepted_at is set — this explicit
  -- status check exists to raise the typed error code instead of letting
  -- a stale/already-resolved request fall through to a raw constraint
  -- violation.
  if v_request.status <> 'pending' then
    raise exception 'REQUEST_CANCEL_NOT_ALLOWED';
  end if;

  update public.requests
  set status = 'cancelled', cancelled_at = now()
  where household_id = v_household_id and id = p_request_id;

  v_result := jsonb_build_object('ok', true);

  update private.mutation_receipts
  set result_type = 'request', result_id = p_request_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_cancel_request(uuid, uuid, uuid) from public;
revoke all on function public.server_tx_cancel_request(uuid, uuid, uuid) from anon;
revoke all on function public.server_tx_cancel_request(uuid, uuid, uuid) from authenticated;
grant execute on function public.server_tx_cancel_request(uuid, uuid, uuid) to service_role;
