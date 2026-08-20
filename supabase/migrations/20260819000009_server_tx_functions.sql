-- WP1: public.server_tx_* — the only way Edge Functions perform atomic
-- client-originated DB transactions. SECURITY INVOKER; EXECUTE revoked from
-- PUBLIC/anon/authenticated; granted only to service_role (Edge always calls
-- these via the service-role supabase-js client, never the anon/user client).
-- docs/design/v6/09_API_AND_EDGE_FUNCTIONS.md #3,#5; 18_MUTATION_CONTRACT_MATRIX.md
-- #0,#0A,#0B; 15_DDL_CONTRACT.md #8

-- ---------------------------------------------------------------------------
-- household create
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_create_household(
  p_actor_id uuid,
  p_operation_id uuid,
  p_household_name text,
  p_display_name text
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
  if p_actor_id is null or p_operation_id is null then
    raise exception 'INVALID_INPUT';
  end if;
  if coalesce(btrim(p_household_name), '') = '' or coalesce(btrim(p_display_name), '') = '' then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to('create-household|' || p_household_name || '|' || p_display_name, 'UTF8')),
    'hex'
  );

  -- Claim-then-fill mutation receipt (private.mutation_receipts has nullable
  -- result_* columns exactly to support this pattern): the first caller for
  -- a given (actor_id, operation_id) wins the INSERT and fills the receipt
  -- after the business mutation; any concurrent/retried caller blocks on the
  -- row lock until that transaction commits or rolls back, then replays.
  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'create-household', v_request_hash)
    on conflict (actor_id, operation_id) do nothing;

    if found then
      exit; -- we own this receipt row; proceed to business mutation
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
    -- else: the other transaction rolled back and freed the row; retry claim
  end loop;

  -- Serialize any concurrent attempt by this same actor to acquire a
  -- household via create-household or join-household.
  perform pg_advisory_xact_lock(hashtext('fo_membership_actor:' || p_actor_id::text));

  perform 1 from public.household_members where user_id = p_actor_id;
  if found then
    raise exception 'HOUSEHOLD_ALREADY_JOINED';
  end if;

  insert into public.households (name, timezone)
  values (p_household_name, 'Asia/Tokyo')
  returning id into v_household_id;

  insert into public.profiles (user_id, display_name)
  values (p_actor_id, p_display_name)
  on conflict (user_id) do update set display_name = excluded.display_name;

  insert into public.household_members (household_id, user_id, member_role, joined_at)
  values (v_household_id, p_actor_id, 'adult', now());

  -- v6 review fix (P1-1): 9-kind model, weekly_digest/Sunday 12:00 retired.
  insert into public.household_routine_schedules
    (household_id, schedule_kind, weekday, local_time, updated_by)
  values
    (v_household_id, 'daily_assignment', null, time '07:00', p_actor_id),
    (v_household_id, 'dropoff_checklist', null, time '07:00', p_actor_id),
    (v_household_id, 'dropoff_checkin', null, time '08:30', p_actor_id),
    (v_household_id, 'pickup_checklist', null, time '16:00', p_actor_id),
    (v_household_id, 'pickup_checkin', null, time '20:30', p_actor_id),
    (v_household_id, 'nonpickup_evening_checklist', null, time '20:00', p_actor_id),
    (v_household_id, 'nonpickup_evening_checkin', null, time '22:00', p_actor_id),
    (v_household_id, 'nonworkday_morning_digest', null, time '09:00', p_actor_id),
    (v_household_id, 'nonworkday_checkin', null, time '20:00', p_actor_id);

  insert into public.notification_preferences (household_id, user_id)
  values (v_household_id, p_actor_id);

  v_result := jsonb_build_object('household_id', v_household_id);

  update private.mutation_receipts
  set result_type = 'household', result_id = v_household_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_create_household(uuid, uuid, text, text) from public;
revoke all on function public.server_tx_create_household(uuid, uuid, text, text) from anon;
revoke all on function public.server_tx_create_household(uuid, uuid, text, text) from authenticated;
grant execute on function public.server_tx_create_household(uuid, uuid, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- household invite create
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_create_household_invite(
  p_actor_id uuid,
  p_operation_id uuid
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
  v_raw_token text;
  v_token_hash text;
  v_invite_id uuid;
  v_stored_result jsonb;
  v_caller_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to('create-household-invite|' || p_actor_id::text, 'UTF8')),
    'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'create-household-invite', v_request_hash)
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
      -- Replay never re-issues the raw token (it was never persisted).
      raise exception 'INVITE_TOKEN_ALREADY_ISSUED' using detail = v_receipt.result_id::text;
    end if;
  end loop;

  select household_id into v_household_id
  from public.household_members
  where user_id = p_actor_id;

  if v_household_id is null then
    raise exception 'NOT_HOUSEHOLD_MEMBER';
  end if;

  -- 256-bit raw token: two concatenated gen_random_uuid() outputs (32 bytes),
  -- hex-encoded. Only its SHA-256 hash is ever stored.
  v_raw_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  v_token_hash := encode(sha256(convert_to(v_raw_token, 'UTF8')), 'hex');

  insert into private.household_invites (token_hash, household_id, created_by, expires_at)
  values (v_token_hash, v_household_id, p_actor_id, now() + interval '24 hours')
  returning id into v_invite_id;

  -- Receipt stores no raw token — only enough to service INVITE_TOKEN_ALREADY_ISSUED replays.
  v_stored_result := jsonb_build_object('invite_id', v_invite_id, 'household_id', v_household_id);
  update private.mutation_receipts
  set result_type = 'household_invite', result_id = v_invite_id, result_payload = v_stored_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  v_caller_result := v_stored_result || jsonb_build_object(
    'raw_token', v_raw_token,
    'expires_at', (now() + interval '24 hours')
  );
  return v_caller_result;
end;
$$;

revoke all on function public.server_tx_create_household_invite(uuid, uuid) from public;
revoke all on function public.server_tx_create_household_invite(uuid, uuid) from anon;
revoke all on function public.server_tx_create_household_invite(uuid, uuid) from authenticated;
grant execute on function public.server_tx_create_household_invite(uuid, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- household join
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_join_household(
  p_actor_id uuid,
  p_operation_id uuid,
  p_raw_invite_token text,
  p_display_name text
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_request_hash text;
  v_receipt record;
  v_token_hash text;
  v_invite record;
  v_active_adults int;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null
     or coalesce(p_raw_invite_token, '') = ''
     or coalesce(btrim(p_display_name), '') = '' then
    raise exception 'INVALID_INPUT';
  end if;

  v_token_hash := encode(sha256(convert_to(p_raw_invite_token, 'UTF8')), 'hex');
  v_request_hash := encode(
    sha256(convert_to('join-household|' || v_token_hash || '|' || p_display_name, 'UTF8')),
    'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'join-household', v_request_hash)
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

  perform pg_advisory_xact_lock(hashtext('fo_membership_actor:' || p_actor_id::text));

  select * into v_invite
  from private.household_invites
  where token_hash = v_token_hash
  for update;

  if not found then
    raise exception 'INVITE_EXPIRED';
  end if;
  if v_invite.used_at is not null then
    raise exception 'INVITE_USED';
  end if;
  if v_invite.expires_at <= now() then
    raise exception 'INVITE_EXPIRED';
  end if;

  -- Lock the target household's membership set so concurrent joins to the
  -- same household serialize on this row set (the creator's row already
  -- exists, so this always has at least one row to lock).
  perform 1
  from public.household_members
  where household_id = v_invite.household_id
  for update;

  select count(*) into v_active_adults
  from public.household_members
  where household_id = v_invite.household_id and member_role = 'adult';

  if v_active_adults >= 2 then
    raise exception 'HOUSEHOLD_FULL';
  end if;

  perform 1 from public.household_members where user_id = p_actor_id;
  if found then
    raise exception 'HOUSEHOLD_ALREADY_JOINED';
  end if;

  insert into public.profiles (user_id, display_name)
  values (p_actor_id, p_display_name)
  on conflict (user_id) do update set display_name = excluded.display_name;

  insert into public.household_members (household_id, user_id, member_role, joined_at)
  values (v_invite.household_id, p_actor_id, 'adult', now());

  insert into public.notification_preferences (household_id, user_id)
  values (v_invite.household_id, p_actor_id);

  update private.household_invites
  set used_at = now(), used_by = p_actor_id
  where id = v_invite.id;

  v_result := jsonb_build_object('household_id', v_invite.household_id);

  update private.mutation_receipts
  set result_type = 'household', result_id = v_invite.household_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_join_household(uuid, uuid, text, text) from public;
revoke all on function public.server_tx_join_household(uuid, uuid, text, text) from anon;
revoke all on function public.server_tx_join_household(uuid, uuid, text, text) from authenticated;
grant execute on function public.server_tx_join_household(uuid, uuid, text, text) to service_role;

-- ---------------------------------------------------------------------------
-- LINE quota — atomic reservation / commit / release / ambiguous
-- docs/design/v6/03_DOMAIN_AND_DATA_MODEL.md #16 (line_quota_state/reservations);
-- fixtures/LINE_QUOTA_ATOMIC_CASES.json
--
-- Concurrency model: private.line_quota_state has one row per billing_month
-- and every reserve/commit/release/mark-ambiguous call locks that row FOR
-- UPDATE first. That single row is the mutex for the whole month's budget,
-- so "atomic reservation" falls directly out of normal Postgres row locking
-- with no separate advisory lock needed.
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_reserve_line_quota(
  p_notification_outbox_id uuid,
  p_priority text
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_billing_month date := date_trunc('month', (now() at time zone 'Asia/Tokyo'))::date;
  v_state record;
  v_active_reserved int;
  v_effective_hard_limit int;
  v_effective_usage int;
  v_threshold int;
  v_permitted boolean;
  v_reservation_id uuid;
  v_existing record;
begin
  if p_priority not in ('critical', 'normal', 'reminder') then
    raise exception 'INVALID_INPUT';
  end if;
  if p_notification_outbox_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  -- v6 review fix (P2): idempotent replay. notification_outbox_id is UNIQUE
  -- on line_quota_reservations, so a retried reserve call for the same
  -- outbox row (e.g. after the Edge Function's own response was lost) must
  -- return the already-decided outcome instead of erroring on the unique
  -- violation or re-deciding admission against a now-different quota state.
  select * into v_existing
  from private.line_quota_reservations
  where notification_outbox_id = p_notification_outbox_id
  for update;

  if found then
    return jsonb_build_object(
      'permitted', v_existing.status in ('reserved', 'ambiguous', 'committed'),
      'reservation_id', v_existing.id,
      'billing_month', v_existing.billing_month,
      'replay', true
    );
  end if;

  insert into private.line_quota_state (billing_month, provider_limit, provider_consumed)
  values (v_billing_month, 200, 0)
  on conflict (billing_month) do nothing;

  select * into v_state
  from private.line_quota_state
  where billing_month = v_billing_month
  for update;

  select count(*) into v_active_reserved
  from private.line_quota_reservations
  where billing_month = v_billing_month
    and status in ('reserved', 'ambiguous');

  v_effective_hard_limit := least(v_state.provider_limit, v_state.app_hard_cap);
  v_effective_usage := greatest(v_state.provider_consumed, v_state.local_counted_success) + v_active_reserved;
  -- v6 review fix (P2): reminder/normal priority reads soft_budget directly
  -- rather than deriving an equivalent value from hard_limit - reserve, so
  -- the two columns can be tuned independently without silently drifting
  -- from the documented "reminder actually uses soft_budget" contract.
  v_threshold := case when p_priority = 'critical' then v_effective_hard_limit
                       else v_state.soft_budget end;
  v_permitted := (v_effective_usage + 1) <= v_threshold;

  if v_permitted then
    insert into private.line_quota_reservations
      (billing_month, notification_outbox_id, status, provider_consumed_snapshot)
    values
      (v_billing_month, p_notification_outbox_id, 'reserved', v_state.provider_consumed)
    returning id into v_reservation_id;

    update private.notification_outbox
    set quota_reservation_id = v_reservation_id
    where id = p_notification_outbox_id;
  end if;

  return jsonb_build_object(
    'permitted', v_permitted,
    'reservation_id', v_reservation_id,
    'effective_usage_before', v_effective_usage,
    'effective_hard_limit', v_effective_hard_limit,
    'billing_month', v_billing_month,
    'replay', false
  );
end;
$$;

revoke all on function public.server_tx_reserve_line_quota(uuid, text) from public;
revoke all on function public.server_tx_reserve_line_quota(uuid, text) from anon;
revoke all on function public.server_tx_reserve_line_quota(uuid, text) from authenticated;
grant execute on function public.server_tx_reserve_line_quota(uuid, text) to service_role;

-- v6 review fix (P2): explicit state machine — reserved/ambiguous can
-- transition to committed or released; committed/released are terminal.
-- Re-calling commit on an already-committed reservation is an idempotent
-- no-op (must NOT double-increment local_counted_success); calling it on a
-- released reservation is a genuine conflict, not a replay.
create or replace function public.server_tx_commit_line_quota_reservation(p_reservation_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_status text;
  v_month date;
begin
  select status, billing_month into v_status, v_month
  from private.line_quota_reservations
  where id = p_reservation_id
  for update;

  if not found then
    raise exception 'INVALID_INPUT';
  end if;

  if v_status = 'committed' then
    return; -- idempotent replay
  end if;

  if v_status not in ('reserved', 'ambiguous') then
    raise exception 'INVALID_STATE_TRANSITION';
  end if;

  perform 1 from private.line_quota_state where billing_month = v_month for update;

  update private.line_quota_reservations
  set status = 'committed', committed_at = now()
  where id = p_reservation_id;

  update private.line_quota_state
  set local_counted_success = local_counted_success + 1
  where billing_month = v_month;
end;
$$;

revoke all on function public.server_tx_commit_line_quota_reservation(uuid) from public;
revoke all on function public.server_tx_commit_line_quota_reservation(uuid) from anon;
revoke all on function public.server_tx_commit_line_quota_reservation(uuid) from authenticated;
grant execute on function public.server_tx_commit_line_quota_reservation(uuid) to service_role;

create or replace function public.server_tx_release_line_quota_reservation(p_reservation_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_status text;
begin
  select status into v_status
  from private.line_quota_reservations
  where id = p_reservation_id
  for update;

  if not found then
    raise exception 'INVALID_INPUT';
  end if;

  if v_status = 'released' then
    return; -- idempotent replay
  end if;

  if v_status not in ('reserved', 'ambiguous') then
    raise exception 'INVALID_STATE_TRANSITION';
  end if;

  update private.line_quota_reservations
  set status = 'released', released_at = now()
  where id = p_reservation_id;
end;
$$;

revoke all on function public.server_tx_release_line_quota_reservation(uuid) from public;
revoke all on function public.server_tx_release_line_quota_reservation(uuid) from anon;
revoke all on function public.server_tx_release_line_quota_reservation(uuid) from authenticated;
grant execute on function public.server_tx_release_line_quota_reservation(uuid) to service_role;

-- Timeout / ambiguous provider response: stays counted against budget
-- (fixtures/LINE_QUOTA_ATOMIC_CASES.json LQA06) until a later reconcile
-- (WP6) definitively commits or releases it.
create or replace function public.server_tx_mark_line_quota_ambiguous(p_reservation_id uuid)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_status text;
begin
  select status into v_status
  from private.line_quota_reservations
  where id = p_reservation_id
  for update;

  if not found then
    raise exception 'INVALID_INPUT';
  end if;

  if v_status = 'ambiguous' then
    return; -- idempotent replay
  end if;

  if v_status <> 'reserved' then
    raise exception 'INVALID_STATE_TRANSITION';
  end if;

  update private.line_quota_reservations
  set status = 'ambiguous'
  where id = p_reservation_id;
end;
$$;

revoke all on function public.server_tx_mark_line_quota_ambiguous(uuid) from public;
revoke all on function public.server_tx_mark_line_quota_ambiguous(uuid) from anon;
revoke all on function public.server_tx_mark_line_quota_ambiguous(uuid) from authenticated;
grant execute on function public.server_tx_mark_line_quota_ambiguous(uuid) to service_role;
