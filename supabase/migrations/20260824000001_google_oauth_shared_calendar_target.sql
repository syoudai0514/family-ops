-- OAuth v2: Calendar list entries are household-scoped candidates, not an
-- implicit Family Ops write target.  Existing explicit choices survive a
-- reauthorization only while Google still reports them as eligible.
--
-- This is forward-only: the v1 completion RPC remains available for old
-- callers, while the callback switches to the v2 contract below.

drop trigger if exists calendar_connections_default_family_write_target on public.calendar_connections;

create or replace function public.server_tx_complete_google_oauth_v2(
  p_state_hash text,
  p_google_subject text,
  p_encrypted_refresh_token text,
  p_encryption_version int,
  p_scopes text[],
  p_calendar_candidates jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_state private.google_oauth_states%rowtype;
  v_connection_id uuid;
  v_previous_target_id uuid;
  v_previous_target_external_id text;
  v_candidate_ids text[];
begin
  if p_state_hash is null
     or p_google_subject is null
     or p_encrypted_refresh_token is null
     or p_calendar_candidates is null
     or jsonb_typeof(p_calendar_candidates) <> 'array'
     or jsonb_array_length(p_calendar_candidates) = 0 then
    raise exception 'INVALID_INPUT';
  end if;

  select * into v_state
  from private.google_oauth_states
  where state_hash = p_state_hash
  for update;

  if not found or v_state.used_at is not null or v_state.expires_at < now() then
    raise exception 'GOOGLE_OAUTH_STATE_INVALID';
  end if;

  -- The Edge function filters calendarList itself, but enforce its v6
  -- contract again inside the transaction so a malformed service RPC call
  -- cannot register a reader, freeBusyReader, or foreign-timezone calendar.
  if exists (
    select 1
    from jsonb_array_elements(p_calendar_candidates) item
    where nullif(item ->> 'id', '') is null
       or item ->> 'accessRole' not in ('writerWithoutPrivateAccess', 'writer', 'owner')
       or item ->> 'timeZone' is distinct from 'Asia/Tokyo'
  ) then
    raise exception 'CALENDAR_NO_ELIGIBLE_CALENDAR';
  end if;

  select array_agg(calendar_id order by calendar_id)
  into v_candidate_ids
  from (
    select distinct nullif(item ->> 'id', '') as calendar_id
    from jsonb_array_elements(p_calendar_candidates) item
  ) candidates;

  if cardinality(v_candidate_ids) is null or cardinality(v_candidate_ids) = 0 then
    raise exception 'CALENDAR_NO_ELIGIBLE_CALENDAR';
  end if;

  select id, external_calendar_id
  into v_previous_target_id, v_previous_target_external_id
  from public.calendar_connections
  where household_id = v_state.household_id
    and provider = 'google'
    and is_family_write_target
  for update;

  -- Households retain one credential row.  The state binding remains the
  -- authority for household and user identity; browser code never sees the
  -- token or credential id.
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
      v_state.household_id, v_state.user_id, p_google_subject,
      p_encrypted_refresh_token, p_encryption_version, p_scopes, 'active'
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

  -- A candidate that disappeared from the new Calendar API result (or lost
  -- write access) is no longer readable/writable for this credential.  In
  -- particular, it cannot remain the active write target.
  update public.calendar_connections
  set active = false,
      reauth_required = true,
      is_family_write_target = false
  where household_id = v_state.household_id
    and provider = 'google'
    and external_calendar_id <> all(v_candidate_ids);

  insert into public.calendar_connections (
    household_id, provider, external_calendar_id, display_name,
    google_connection_id, active, reauth_required, is_family_write_target
  )
  select
    v_state.household_id,
    'google',
    candidate.item ->> 'id',
    nullif(candidate.item ->> 'summary', ''),
    v_connection_id,
    true,
    false,
    false
  from (
    select distinct on (item ->> 'id') item
    from jsonb_array_elements(p_calendar_candidates) item
    order by item ->> 'id'
  ) candidate
  on conflict (household_id, external_calendar_id) do update
  set google_connection_id = excluded.google_connection_id,
      display_name = excluded.display_name,
      active = true,
      reauth_required = false;

  -- New connections deliberately have no target.  Reauthorization retains
  -- only a target the user already chose and Google still lists as eligible.
  if v_previous_target_id is not null
     and v_previous_target_external_id = any(v_candidate_ids) then
    update public.calendar_connections
    set is_family_write_target = false
    where household_id = v_state.household_id
      and provider = 'google'
      and is_family_write_target
      and id <> v_previous_target_id;
    update public.calendar_connections
    set is_family_write_target = true
    where id = v_previous_target_id;
  end if;

  update private.google_oauth_states
  set used_at = now()
  where state_hash = p_state_hash;

  return jsonb_build_object(
    'household_id', v_state.household_id,
    'user_id', v_state.user_id,
    'return_to', v_state.return_to,
    'google_connection_id', v_connection_id,
    'calendar_connection_ids', (
      select coalesce(jsonb_agg(id order by external_calendar_id), '[]'::jsonb)
      from public.calendar_connections
      where household_id = v_state.household_id
        and provider = 'google'
        and external_calendar_id = any(v_candidate_ids)
    ),
    'family_write_target_id', (
      select id
      from public.calendar_connections
      where household_id = v_state.household_id
        and provider = 'google'
        and is_family_write_target
    )
  );
end;
$$;

revoke all on function public.server_tx_complete_google_oauth_v2(text, text, text, int, text[], jsonb) from public, anon, authenticated;
grant execute on function public.server_tx_complete_google_oauth_v2(text, text, text, int, text[], jsonb) to service_role;
