-- WP6: LINE account linking (docs/design/v6/06_LINE_INTEGRATION.md #2) and
-- webhook-side actor resolution. Mirrors the household-invite claim pattern
-- in 20260819000009_server_tx_functions.sql (token issue -> SHA-256 hash
-- stored, single-use, TTL, claim-then-fill mutation_receipts idempotency).
--
-- server_tx_create_line_link_token / server_tx_unlink_line_account are the
-- two client-facing (verify_jwt=true) RPCs behind create-line-link-token /
-- unlink-line-account. server_tx_claim_line_link_token and
-- server_tx_resolve_line_actor are internal, called only from the
-- process-line-inbox worker (service_role, no user JWT) — the claim happens
-- when the *verified LINE webhook* source.userId sends the pasted token as
-- a text message, per #2 step 1 "verified LINE webhook source.userId取得".
-- All four are service_role-only, same as every public.server_tx_* (15_DDL_
-- CONTRACT.md #8).

-- ---------------------------------------------------------------------------
-- create-line-link-token
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_create_line_link_token(
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
  v_token_id uuid;
  v_expires_at timestamptz;
  v_stored_result jsonb;
  v_caller_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to('create-line-link-token|' || p_actor_id::text, 'UTF8')), 'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'create-line-link-token', v_request_hash)
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
      -- The raw token is never persisted, so a retry of the same
      -- operation_id cannot replay it (unlike most server_tx_* replays).
      -- Callers must mint a fresh operation_id to get a new token; this is
      -- an accepted MVP limitation for a low-frequency, user-initiated flow.
      raise exception 'INVALID_INPUT';
    end if;
  end loop;

  select household_id into v_household_id
  from public.household_members
  where user_id = p_actor_id;

  if v_household_id is null then
    raise exception 'NOT_HOUSEHOLD_MEMBER';
  end if;

  -- 256-bit raw token: two concatenated gen_random_uuid() outputs (32
  -- bytes), hex-encoded (64 hex chars). Only its SHA-256 hash is stored —
  -- matches #2 "DB stores SHA-256 hash only".
  v_raw_token := replace(gen_random_uuid()::text, '-', '') || replace(gen_random_uuid()::text, '-', '');
  v_token_hash := encode(sha256(convert_to(v_raw_token, 'UTF8')), 'hex');
  v_expires_at := now() + interval '10 minutes'; -- #2 "TTL 10m"

  insert into private.line_link_tokens (token_hash, household_id, user_id, expires_at)
  values (v_token_hash, v_household_id, p_actor_id, v_expires_at)
  returning id into v_token_id;

  v_stored_result := jsonb_build_object('token_id', v_token_id, 'household_id', v_household_id);
  update private.mutation_receipts
  set result_type = 'line_link_token', result_id = v_token_id, result_payload = v_stored_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  v_caller_result := v_stored_result
    || jsonb_build_object('raw_token', v_raw_token, 'expires_at', v_expires_at);
  return v_caller_result;
end;
$$;

revoke all on function public.server_tx_create_line_link_token(uuid, uuid) from public;
revoke all on function public.server_tx_create_line_link_token(uuid, uuid) from anon;
revoke all on function public.server_tx_create_line_link_token(uuid, uuid) from authenticated;
grant execute on function public.server_tx_create_line_link_token(uuid, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- unlink-line-account
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_unlink_line_account(
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
  v_row record;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to('unlink-line-account|' || p_actor_id::text, 'UTF8')), 'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'unlink-line-account', v_request_hash)
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

  select * into v_row from private.line_user_links where user_id = p_actor_id for update;

  -- Idempotent: unlinking an already-unlinked (or never-linked) account is
  -- a success no-op, not an error — the caller's desired end state (not
  -- linked) already holds.
  if not found or v_row.status = 'unlinked' then
    v_result := jsonb_build_object(
      'was_linked', false,
      'unlinked_at', case when found then v_row.unlinked_at else null end
    );
  else
    update private.line_user_links
    set status = 'unlinked', unlinked_at = now()
    where user_id = p_actor_id;

    v_result := jsonb_build_object('was_linked', true, 'unlinked_at', now());
  end if;

  update private.mutation_receipts
  set result_type = 'line_user_link', result_id = null, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_unlink_line_account(uuid, uuid) from public;
revoke all on function public.server_tx_unlink_line_account(uuid, uuid) from anon;
revoke all on function public.server_tx_unlink_line_account(uuid, uuid) from authenticated;
grant execute on function public.server_tx_unlink_line_account(uuid, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- claim-line-link-token (internal — called by process-line-inbox only, when
-- a verified LINE text message's body is exactly a pasted link token)
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_claim_line_link_token(
  p_source_external_user_id text,
  p_raw_token text
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_token_hash text;
  v_token record;
  v_own_row record;
  v_conflict record;
begin
  if coalesce(p_source_external_user_id, '') = '' or coalesce(p_raw_token, '') = '' then
    raise exception 'INVALID_INPUT';
  end if;

  v_token_hash := encode(sha256(convert_to(p_raw_token, 'UTF8')), 'hex');

  select * into v_token
  from private.line_link_tokens
  where token_hash = v_token_hash
  for update;

  if not found then
    raise exception 'INVALID_INPUT'; -- unknown token: never issued
  end if;

  if v_token.used_at is not null then
    -- Idempotent replay path (06_LINE_INTEGRATION.md #13 "duplicate webhook
    -- -> one mutation" / #3 "dedup by provider + webhookEventId" alone isn't
    -- enough once a *lease reclaim* re-runs this same event after a worker
    -- crash that happened after the claim committed but before the webhook
    -- row was marked done): if this token's owner is already actively
    -- linked to this exact LINE user id, report success rather than error.
    select * into v_own_row from private.line_user_links where user_id = v_token.user_id;
    if found and v_own_row.status = 'active' and v_own_row.line_user_id = p_source_external_user_id then
      return jsonb_build_object(
        'user_id', v_token.user_id, 'household_id', v_token.household_id,
        'line_user_id', p_source_external_user_id, 'already_linked', true
      );
    end if;
    raise exception 'LINE_LINK_TOKEN_USED';
  end if;

  if v_token.expires_at <= now() then
    raise exception 'LINE_LINK_TOKEN_EXPIRED';
  end if;

  if not exists (
    select 1 from public.household_members
    where household_id = v_token.household_id and user_id = v_token.user_id
  ) then
    raise exception 'NOT_HOUSEHOLD_MEMBER';
  end if;

  -- Own existing link, if any (private.line_user_links has UNIQUE(user_id)
  -- — at most one row per Family Ops user, ever; re-link updates it).
  select * into v_own_row from private.line_user_links where user_id = v_token.user_id for update;

  if found and v_own_row.status = 'active' then
    -- #2 claim step 6: "existing user linkがunlinkedならre-link、active別
    -- IDなら拒否". Same-id-while-active can't reach here (used_at would
    -- already be set, handled above), so any active row here is a
    -- different id.
    raise exception 'LINE_USER_ID_ALREADY_LINKED';
  end if;

  -- Global uniqueness (private.line_user_links UNIQUE(line_user_id)): this
  -- LINE user id must not belong to a *different* Family Ops user. The
  -- unique index is unconditional (not partial on status='active'), so an
  -- unlinked row for a different user also blocks this — reassigning a
  -- freed LINE id to a different user is out of MVP scope (only same-user
  -- re-link after unlink is a documented/tested flow); surfaced as the same
  -- conflict code rather than an opaque unique_violation.
  select * into v_conflict
  from private.line_user_links
  where line_user_id = p_source_external_user_id and user_id <> v_token.user_id;

  if found then
    raise exception 'LINE_USER_ID_ALREADY_LINKED';
  end if;

  if v_own_row.user_id is not null then
    update private.line_user_links
    set status = 'active', line_user_id = p_source_external_user_id,
        linked_at = now(), unlinked_at = null
    where user_id = v_token.user_id;
  else
    insert into private.line_user_links (household_id, user_id, line_user_id, status)
    values (v_token.household_id, v_token.user_id, p_source_external_user_id, 'active');
  end if;

  update private.line_link_tokens set used_at = now() where id = v_token.id;

  return jsonb_build_object(
    'user_id', v_token.user_id, 'household_id', v_token.household_id,
    'line_user_id', p_source_external_user_id, 'already_linked', false
  );
end;
$$;

revoke all on function public.server_tx_claim_line_link_token(text, text) from public;
revoke all on function public.server_tx_claim_line_link_token(text, text) from anon;
revoke all on function public.server_tx_claim_line_link_token(text, text) from authenticated;
grant execute on function public.server_tx_claim_line_link_token(text, text) to service_role;

-- ---------------------------------------------------------------------------
-- resolve-line-actor (internal — every other webhook event's actor
-- resolution: #2 MVP invariant "actorはverified source.userId -> active
-- line_user_links でderive")
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_resolve_line_actor(
  p_source_external_user_id text
)
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select jsonb_build_object('user_id', user_id, 'household_id', household_id)
  from private.line_user_links
  where line_user_id = p_source_external_user_id and status = 'active';
$$;

revoke all on function public.server_tx_resolve_line_actor(text) from public;
revoke all on function public.server_tx_resolve_line_actor(text) from anon;
revoke all on function public.server_tx_resolve_line_actor(text) from authenticated;
grant execute on function public.server_tx_resolve_line_actor(text) to service_role;
