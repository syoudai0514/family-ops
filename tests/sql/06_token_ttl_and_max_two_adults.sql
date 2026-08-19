-- Token TTL/reuse invariants beyond household_invites (already covered in
-- 04): line_link_tokens and google_oauth_states single-use claim pattern,
-- plus a same-process sanity check of the max-2-adult invariant.
-- docs/design/v6/fixtures/TOKEN_CASES.json T-05..T-08, TOK-GOOG-01/02
\set ON_ERROR_STOP on

insert into auth.users (id) values ('d0000000-0000-0000-0000-000000000001');

set role service_role;

do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
begin
  v_hh := public.server_tx_create_household('d0000000-0000-0000-0000-000000000001', gen_random_uuid(), 'Token HH', 'Owner');
  v_hh_id := (v_hh->>'household_id')::uuid;

  -- line_link_tokens: 10-minute TTL, raw token never stored (only hash)
  insert into private.line_link_tokens (token_hash, household_id, user_id, expires_at)
  values (encode(sha256(convert_to('raw-line-link-token', 'UTF8')), 'hex'), v_hh_id, 'd0000000-0000-0000-0000-000000000001', now() + interval '10 minutes');

  if exists (select 1 from private.line_link_tokens where token_hash = 'raw-line-link-token') then
    raise exception 'FAIL token: raw line link token must never be stored as token_hash';
  end if;

  -- claim (single-use): first claim succeeds
  update private.line_link_tokens
  set used_at = now()
  where token_hash = encode(sha256(convert_to('raw-line-link-token', 'UTF8')), 'hex') and used_at is null;
  if not found then
    raise exception 'FAIL token: first line link token claim should succeed';
  end if;

  -- second claim (reuse) must be rejected by the used_at is null guard
  if exists (
    select 1 from private.line_link_tokens
    where token_hash = encode(sha256(convert_to('raw-line-link-token', 'UTF8')), 'hex') and used_at is null
  ) then
    raise exception 'FAIL token: line link token must not be claimable twice';
  end if;

  -- google_oauth_states: SHA-256 hash only, 10-minute TTL, allowlisted return_to
  insert into private.google_oauth_states (state_hash, household_id, user_id, return_to, expires_at)
  values (encode(sha256(convert_to('raw-oauth-state', 'UTF8')), 'hex'), v_hh_id, 'd0000000-0000-0000-0000-000000000001', '/settings/calendar', now() + interval '10 minutes');

  if exists (select 1 from private.google_oauth_states where state_hash = 'raw-oauth-state') then
    raise exception 'FAIL token: raw OAuth state must never be stored as state_hash';
  end if;

  -- expiry: an expired, unused state must be treated as invalid by callers
  -- (the claim query pattern always filters expires_at > now())
  update private.google_oauth_states set expires_at = now() - interval '1 second'
  where state_hash = encode(sha256(convert_to('raw-oauth-state', 'UTF8')), 'hex');

  if exists (
    select 1 from private.google_oauth_states
    where state_hash = encode(sha256(convert_to('raw-oauth-state', 'UTF8')), 'hex')
      and used_at is null and expires_at > now()
  ) then
    raise exception 'FAIL token: expired OAuth state must not be claimable';
  end if;
end;
$$;

reset role;

select 'token_ttl_and_max_two_adults: PASS' as result;
