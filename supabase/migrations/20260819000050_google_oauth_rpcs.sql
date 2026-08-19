-- WP7A: Google Calendar OAuth start/callback RPCs.
-- docs/design/v6/07_GOOGLE_CALENDAR.md #2, #2A, #3, #5A.
--
-- Deliberate deviation from the mutation_receipts/operation_id pattern used
-- by every other server_tx_* function: OAuth start/callback is a
-- browser-redirect flow, not a JSON POST mutation, and 07_GOOGLE_CALENDAR.md
-- #2A already specifies its own dedicated idempotency/replay mechanism
-- (state_hash + used_at, single-use, 10m TTL) that plays the same role
-- mutation_receipts plays elsewhere. Documented in
-- docs/adr/0004-google-oauth-state-not-mutation-receipt.md.
--
-- google-calendar-oauth-start is a normal verify_jwt=true user action, so it
-- resolves household_id from auth (household_members), never from client
-- input. google-calendar-oauth-callback is verify_jwt=false (Google's
-- redirect carries no Authorization header) and instead treats the stored
-- state row's household_id/user_id binding as authoritative, per #2A step 4.

create or replace function public.server_tx_start_google_oauth(
  p_actor_id uuid,
  p_state_hash text,
  p_return_to text
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_expires_at timestamptz := now() + interval '10 minutes';
begin
  if p_actor_id is null or p_state_hash is null or length(p_state_hash) <> 64 then
    raise exception 'INVALID_INPUT';
  end if;
  -- allowlisted app-relative path only: leading single slash, no scheme/host.
  if p_return_to is not null and (
    left(p_return_to, 1) <> '/'
    or left(p_return_to, 2) = '//'
    or p_return_to like '%://%'
  ) then
    raise exception 'INVALID_INPUT';
  end if;

  select household_id into v_household_id
  from public.household_members
  where user_id = p_actor_id;

  if v_household_id is null then
    raise exception 'NOT_HOUSEHOLD_MEMBER';
  end if;

  insert into private.google_oauth_states (state_hash, household_id, user_id, return_to, expires_at)
  values (p_state_hash, v_household_id, p_actor_id, p_return_to, v_expires_at);

  return jsonb_build_object('expires_at', v_expires_at);
end;
$$;

revoke all on function public.server_tx_start_google_oauth(uuid, text, text) from public;
revoke all on function public.server_tx_start_google_oauth(uuid, text, text) from anon;
revoke all on function public.server_tx_start_google_oauth(uuid, text, text) from authenticated;
grant execute on function public.server_tx_start_google_oauth(uuid, text, text) to service_role;

-- Consumes the state row (FOR UPDATE, single-use) and upserts the
-- household's Google credential + selected calendar in one transaction.
-- Called by google-calendar-oauth-callback *after* the authorization code
-- has already been exchanged for tokens (so the encrypted refresh token is
-- passed in) and, if a target calendar was resolved via calendarList, its
-- id/summary/timeZone. p_selected_calendar_id may be null when this call is
-- a pure reauth (credential refresh only, calendar already selected).
create or replace function public.server_tx_complete_google_oauth(
  p_state_hash text,
  p_google_subject text,
  p_encrypted_refresh_token text,
  p_encryption_version int,
  p_scopes text[],
  p_selected_calendar_id text,
  p_selected_calendar_summary text,
  p_selected_calendar_timezone text
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_state record;
  v_connection_id uuid;
  v_calendar_connection_id uuid;
  v_result jsonb;
begin
  if p_state_hash is null or p_google_subject is null or p_encrypted_refresh_token is null then
    raise exception 'INVALID_INPUT';
  end if;

  select * into v_state
  from private.google_oauth_states
  where state_hash = p_state_hash
  for update;

  if not found then
    raise exception 'GOOGLE_OAUTH_STATE_INVALID';
  end if;
  if v_state.used_at is not null or v_state.expires_at < now() then
    raise exception 'GOOGLE_OAUTH_STATE_INVALID';
  end if;

  update private.google_oauth_states set used_at = now() where state_hash = p_state_hash;

  if p_selected_calendar_id is not null and p_selected_calendar_timezone is distinct from 'Asia/Tokyo' then
    raise exception 'CALENDAR_TIMEZONE_UNSUPPORTED';
  end if;

  -- Reauth/switch-owner: at most one non-revoked connection per household in
  -- MVP (single shared family calendar); reuse it (updating owner_user_id if
  -- a different household adult completed this OAuth run) rather than
  -- accumulating rows.
  select id into v_connection_id
  from private.google_connections
  where household_id = v_state.household_id and status <> 'revoked'
  order by created_at desc
  limit 1
  for update;

  if v_connection_id is null then
    insert into private.google_connections (
      household_id, owner_user_id, google_subject, encrypted_refresh_token,
      encryption_version, scopes, status
    ) values (
      v_state.household_id, v_state.user_id, p_google_subject, p_encrypted_refresh_token,
      p_encryption_version, p_scopes, 'active'
    ) returning id into v_connection_id;
  else
    update private.google_connections
    set owner_user_id = v_state.user_id,
        google_subject = p_google_subject,
        encrypted_refresh_token = p_encrypted_refresh_token,
        encryption_version = p_encryption_version,
        scopes = p_scopes,
        status = 'active'
    where id = v_connection_id;
  end if;

  if p_selected_calendar_id is not null then
    insert into public.calendar_connections (
      household_id, provider, external_calendar_id, display_name,
      google_connection_id, active, reauth_required
    ) values (
      v_state.household_id, 'google', p_selected_calendar_id, p_selected_calendar_summary,
      v_connection_id, true, false
    )
    on conflict (household_id, external_calendar_id) do update
      set google_connection_id = excluded.google_connection_id,
          display_name = excluded.display_name,
          active = true,
          reauth_required = false
    returning id into v_calendar_connection_id;
  end if;

  -- A reauth (no new calendar selected) clears reauth_required on whatever
  -- calendar_connections rows point at this credential.
  update public.calendar_connections
  set reauth_required = false
  where household_id = v_state.household_id and google_connection_id = v_connection_id;

  v_result := jsonb_build_object(
    'household_id', v_state.household_id,
    'user_id', v_state.user_id,
    'return_to', v_state.return_to,
    'google_connection_id', v_connection_id,
    'calendar_connection_id', v_calendar_connection_id
  );

  return v_result;
end;
$$;

revoke all on function public.server_tx_complete_google_oauth(text, text, text, int, text[], text, text, text) from public;
revoke all on function public.server_tx_complete_google_oauth(text, text, text, int, text[], text, text, text) from anon;
revoke all on function public.server_tx_complete_google_oauth(text, text, text, int, text[], text, text, text) from authenticated;
grant execute on function public.server_tx_complete_google_oauth(text, text, text, int, text[], text, text, text) to service_role;

-- Note: the 5A calendarList eligibility filter (accessRole in
-- writer(WithoutPrivateAccess)/owner, timeZone=Asia/Tokyo) runs entirely in
-- the google-calendar-oauth-callback Edge Function (see
-- supabase/functions/_shared/googleCalendar.ts's pickEligibleCalendar) since
-- private-schema SQL functions are not reachable via the Data API/.rpc() and
-- there is nothing here for it to read from a table.
