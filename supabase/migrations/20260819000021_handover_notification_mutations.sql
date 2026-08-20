-- WP2: handover (create/mark-read) and notification (mark-read/preferences)
-- mutations. docs/design/v6/03_DOMAIN_AND_DATA_MODEL.md #7 (handovers),
-- #8/#19 (notifications).

-- ---------------------------------------------------------------------------
-- create-handover
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_create_handover(
  p_actor_id uuid,
  p_operation_id uuid,
  p_shared_text text,
  p_period text,
  p_categories text[],
  p_occurred_on date
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
  v_handover_id uuid;
  v_recipient record;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null then
    raise exception 'INVALID_INPUT';
  end if;
  if coalesce(btrim(p_shared_text), '') = '' or p_occurred_on is null then
    raise exception 'INVALID_INPUT';
  end if;
  if p_period not in ('morning', 'day', 'evening', 'other') then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to('create-handover|' || p_shared_text || '|' || p_occurred_on::text, 'UTF8')),
    'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'create-handover', v_request_hash)
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

  insert into public.handovers
    (household_id, author_id, shared_text, period, categories, occurred_on)
  values
    (v_household_id, p_actor_id, btrim(p_shared_text), p_period, coalesce(p_categories, '{}'), p_occurred_on)
  returning id into v_handover_id;

  for v_recipient in
    select user_id from public.household_members
    where household_id = v_household_id and user_id <> p_actor_id
  loop
    insert into public.user_notifications
      (household_id, recipient_user_id, type, title, body, dedup_key)
    values
      (v_household_id, v_recipient.user_id, 'handover_created', '引き継ぎ', p_shared_text,
       p_operation_id::text || ':handover_created:' || v_recipient.user_id::text);
  end loop;

  v_result := jsonb_build_object('handover_id', v_handover_id);

  update private.mutation_receipts
  set result_type = 'handover', result_id = v_handover_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_create_handover(uuid, uuid, text, text, text[], date) from public;
revoke all on function public.server_tx_create_handover(uuid, uuid, text, text, text[], date) from anon;
revoke all on function public.server_tx_create_handover(uuid, uuid, text, text, text[], date) from authenticated;
grant execute on function public.server_tx_create_handover(uuid, uuid, text, text, text[], date) to service_role;

-- ---------------------------------------------------------------------------
-- mark-handover-read
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_mark_handover_read(
  p_actor_id uuid,
  p_operation_id uuid,
  p_handover_id uuid
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
  if p_actor_id is null or p_operation_id is null or p_handover_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(sha256(convert_to('mark-handover-read|' || p_handover_id::text, 'UTF8')), 'hex');

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'mark-handover-read', v_request_hash)
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
    select 1 from public.handovers where household_id = v_household_id and id = p_handover_id
  ) then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  -- replay-safe: on conflict do nothing preserves the *first* read_at, per
  -- the unread-badge "since X" semantics.
  insert into public.handover_reads (household_id, handover_id, user_id, read_at)
  values (v_household_id, p_handover_id, p_actor_id, now())
  on conflict (handover_id, user_id) do nothing;

  v_result := jsonb_build_object('ok', true);

  update private.mutation_receipts
  set result_type = 'handover', result_id = p_handover_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_mark_handover_read(uuid, uuid, uuid) from public;
revoke all on function public.server_tx_mark_handover_read(uuid, uuid, uuid) from anon;
revoke all on function public.server_tx_mark_handover_read(uuid, uuid, uuid) from authenticated;
grant execute on function public.server_tx_mark_handover_read(uuid, uuid, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- mark-notification-read
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_mark_notification_read(
  p_actor_id uuid,
  p_operation_id uuid,
  p_notification_id uuid
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_request_hash text;
  v_receipt record;
  v_notification record;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_notification_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(sha256(convert_to('mark-notification-read|' || p_notification_id::text, 'UTF8')), 'hex');

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'mark-notification-read', v_request_hash)
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

  select * into v_notification
  from public.user_notifications
  where id = p_notification_id
  for update;

  if not found or v_notification.recipient_user_id <> p_actor_id then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  -- set once; replay returns the already-set value (coalesce keeps the
  -- first read_at, matching mark-handover-read's replay semantics).
  update public.user_notifications
  set read_at = coalesce(read_at, now())
  where id = p_notification_id;

  v_result := jsonb_build_object('ok', true);

  update private.mutation_receipts
  set result_type = 'user_notification', result_id = p_notification_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_mark_notification_read(uuid, uuid, uuid) from public;
revoke all on function public.server_tx_mark_notification_read(uuid, uuid, uuid) from anon;
revoke all on function public.server_tx_mark_notification_read(uuid, uuid, uuid) from authenticated;
grant execute on function public.server_tx_mark_notification_read(uuid, uuid, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- update-notification-preferences (partial update: jsonb of only the
-- fields the caller wants to change)
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_update_notification_preferences(
  p_actor_id uuid,
  p_operation_id uuid,
  p_fields jsonb
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
  v_allowed_keys text[] := array[
    'request_line', 'handover_line', 'calendar_line', 'conflict_line',
    'routine_completion_line', 'shopping_minor_line', 'weekly_digest_line',
    'daily_assignment_line', 'routine_checklist_line', 'routine_checkin_prompt_line',
    'in_app'
  ];
  v_key text;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_fields is null
     or jsonb_typeof(p_fields) <> 'object' then
    raise exception 'INVALID_INPUT';
  end if;

  for v_key in select jsonb_object_keys(p_fields)
  loop
    if not (v_key = any(v_allowed_keys)) or jsonb_typeof(p_fields->v_key) <> 'boolean' then
      raise exception 'INVALID_INPUT';
    end if;
  end loop;

  v_request_hash := encode(
    sha256(convert_to('update-notification-preferences|' || p_fields::text, 'UTF8')),
    'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'update-notification-preferences', v_request_hash)
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

  update public.notification_preferences
  set
    request_line = coalesce((p_fields->>'request_line')::boolean, request_line),
    handover_line = coalesce((p_fields->>'handover_line')::boolean, handover_line),
    calendar_line = coalesce((p_fields->>'calendar_line')::boolean, calendar_line),
    conflict_line = coalesce((p_fields->>'conflict_line')::boolean, conflict_line),
    routine_completion_line = coalesce((p_fields->>'routine_completion_line')::boolean, routine_completion_line),
    shopping_minor_line = coalesce((p_fields->>'shopping_minor_line')::boolean, shopping_minor_line),
    weekly_digest_line = coalesce((p_fields->>'weekly_digest_line')::boolean, weekly_digest_line),
    daily_assignment_line = coalesce((p_fields->>'daily_assignment_line')::boolean, daily_assignment_line),
    routine_checklist_line = coalesce((p_fields->>'routine_checklist_line')::boolean, routine_checklist_line),
    routine_checkin_prompt_line = coalesce((p_fields->>'routine_checkin_prompt_line')::boolean, routine_checkin_prompt_line),
    in_app = coalesce((p_fields->>'in_app')::boolean, in_app)
  where household_id = v_household_id and user_id = p_actor_id;

  v_result := jsonb_build_object('ok', true);

  update private.mutation_receipts
  set result_type = 'notification_preferences', result_id = v_household_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_update_notification_preferences(uuid, uuid, jsonb) from public;
revoke all on function public.server_tx_update_notification_preferences(uuid, uuid, jsonb) from anon;
revoke all on function public.server_tx_update_notification_preferences(uuid, uuid, jsonb) from authenticated;
grant execute on function public.server_tx_update_notification_preferences(uuid, uuid, jsonb) to service_role;
