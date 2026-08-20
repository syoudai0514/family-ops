-- WP7F: deterministic-ID create/update writes — google_write_operations
-- idempotency ledger.
-- docs/design/v6/07_GOOGLE_CALENDAR.md #11 "Create idempotency", #12 "Update
-- idempotency/concurrency". private.google_write_operations (WP1) is keyed
-- by operation_id PRIMARY KEY plus UNIQUE(calendar_connection_id,
-- google_event_id) — the claim-then-fill loop below plays the same role
-- private.mutation_receipts plays for ordinary mutations, but reuses this
-- purpose-built table per #11 ("private.google_write_operations claimed
-- before provider call") instead of the generic one, since it also needs to
-- carry the provider event id + result etag that ordinary mutations don't.

-- Deterministic Google event ID: 'fo' + operation UUID lowercase hex,
-- hyphens stripped. Every hex digit (0-9a-f) is already inside Google's
-- allowed id charset (base32hex: 0-9a-v), so no re-encoding is needed (#11
-- "UUID hex uses only allowed base32hex subset and length is valid").
create or replace function private.google_deterministic_event_id(p_operation_id uuid)
returns text
language sql
immutable
set search_path = ''
as $$
  select 'fo' || replace(lower(p_operation_id::text), '-', '');
$$;

revoke all on function private.google_deterministic_event_id(uuid) from public;
revoke all on function private.google_deterministic_event_id(uuid) from anon;
revoke all on function private.google_deterministic_event_id(uuid) from authenticated;
grant execute on function private.google_deterministic_event_id(uuid) to service_role;

-- Claims a write operation before any Google API call is made. Same actor +
-- operation_id + different request payload is rejected as IDEMPOTENCY_CONFLICT
-- (#11 "Same operation ID + different local payload is blocked earlier by
-- mutation receipt" — here, by this ledger's own request_hash check, since
-- writes don't also go through private.mutation_receipts).
-- p_target_google_event_id: null for 'create' (the id is *derived*
-- deterministically from p_operation_id, per #11); required and passed
-- through verbatim for 'update' (the id of the already-existing event being
-- patched — an update's own operation_id has nothing to do with which
-- event it targets, so it must never be used to (re)derive one).
create or replace function public.server_tx_claim_google_write(
  p_actor_id uuid,
  p_operation_id uuid,
  p_calendar_connection_id uuid,
  p_action text,
  p_request_hash text,
  p_target_google_event_id text
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_google_event_id text;
  v_row record;
begin
  if p_actor_id is null or p_operation_id is null or p_calendar_connection_id is null
     or p_action is null or p_request_hash is null then
    raise exception 'INVALID_INPUT';
  end if;
  if p_action not in ('create', 'update') then
    raise exception 'INVALID_INPUT';
  end if;
  if p_action = 'update' and (p_target_google_event_id is null or length(p_target_google_event_id) = 0) then
    raise exception 'INVALID_INPUT';
  end if;
  if p_action = 'create' and p_target_google_event_id is not null then
    raise exception 'INVALID_INPUT';
  end if;

  select household_id into v_household_id
  from public.household_members
  where user_id = p_actor_id;

  if v_household_id is null then
    raise exception 'NOT_HOUSEHOLD_MEMBER';
  end if;

  if not exists (
    select 1 from public.calendar_connections
    where id = p_calendar_connection_id and household_id = v_household_id
  ) then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  v_google_event_id := case
    when p_action = 'create' then private.google_deterministic_event_id(p_operation_id)
    else p_target_google_event_id
  end;

  insert into private.google_write_operations (
    operation_id, household_id, calendar_connection_id, google_event_id, action, request_hash, status
  ) values (
    p_operation_id, v_household_id, p_calendar_connection_id, v_google_event_id, p_action, p_request_hash, 'pending'
  )
  on conflict (operation_id) do nothing;

  select * into v_row
  from private.google_write_operations
  where operation_id = p_operation_id
  for update;

  if v_row.request_hash <> p_request_hash then
    raise exception 'IDEMPOTENCY_CONFLICT';
  end if;
  if v_row.calendar_connection_id <> p_calendar_connection_id then
    raise exception 'IDEMPOTENCY_CONFLICT';
  end if;

  return jsonb_build_object(
    'google_event_id', v_row.google_event_id,
    'status', v_row.status,
    'result_etag', v_row.result_etag,
    'action', v_row.action
  );
end;
$$;

revoke all on function public.server_tx_claim_google_write(uuid, uuid, uuid, text, text, text) from public;
revoke all on function public.server_tx_claim_google_write(uuid, uuid, uuid, text, text, text) from anon;
revoke all on function public.server_tx_claim_google_write(uuid, uuid, uuid, text, text, text) from authenticated;
grant execute on function public.server_tx_claim_google_write(uuid, uuid, uuid, text, text, text) to service_role;

-- Records the outcome of the provider call the claim above authorized.
-- Idempotent: retrying with the same terminal status/etag after a response
-- was lost (#11 "response lost" -> "retry uses same remote event ID") is a
-- no-op, not an error.
create or replace function public.server_tx_finalize_google_write(
  p_operation_id uuid,
  p_status text,
  p_result_etag text,
  p_last_error text
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_row record;
begin
  if p_operation_id is null or p_status is null then
    raise exception 'INVALID_INPUT';
  end if;
  if p_status not in ('pending', 'succeeded', 'conflict', 'dead') then
    raise exception 'INVALID_INPUT';
  end if;

  select * into v_row
  from private.google_write_operations
  where operation_id = p_operation_id
  for update;

  if not found then
    raise exception 'INVALID_INPUT';
  end if;

  update private.google_write_operations
  set status = p_status, result_etag = coalesce(p_result_etag, result_etag), last_error = p_last_error
  where operation_id = p_operation_id;

  return jsonb_build_object('google_event_id', v_row.google_event_id, 'status', p_status);
end;
$$;

revoke all on function public.server_tx_finalize_google_write(uuid, text, text, text) from public;
revoke all on function public.server_tx_finalize_google_write(uuid, text, text, text) from anon;
revoke all on function public.server_tx_finalize_google_write(uuid, text, text, text) from authenticated;
grant execute on function public.server_tx_finalize_google_write(uuid, text, text, text) to service_role;
