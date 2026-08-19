-- WP7A/WP7C: reauth-required transition.
-- docs/design/v6/07_GOOGLE_CALENDAR.md #2 "Publishing status gate" — while
-- the OAuth consent screen is kept in Testing, Calendar refresh tokens can
-- expire after 7 days; repeated invalid_grant from Google's token endpoint
-- is expected and must flip the connection into reauth_required rather than
-- retrying forever. Used by process-google-sync / renew-google-watch /
-- create-calendar-event / update-calendar-event whenever a token refresh
-- fails with invalid_grant.
create or replace function public.server_tx_mark_google_reauth_required(
  p_calendar_connection_id uuid,
  p_reason text
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_connection_id uuid;
begin
  if p_calendar_connection_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  update public.calendar_connections
  set reauth_required = true
  where id = p_calendar_connection_id
  returning google_connection_id into v_connection_id;

  if v_connection_id is not null then
    update private.google_connections
    set status = 'reauth_required'
    where id = v_connection_id and status <> 'revoked';
  end if;

  insert into private.google_sync_state (calendar_connection_id, last_error)
  values (p_calendar_connection_id, coalesce(p_reason, 'invalid_grant'))
  on conflict (calendar_connection_id) do update set last_error = coalesce(p_reason, 'invalid_grant');
end;
$$;

revoke all on function public.server_tx_mark_google_reauth_required(uuid, text) from public;
revoke all on function public.server_tx_mark_google_reauth_required(uuid, text) from anon;
revoke all on function public.server_tx_mark_google_reauth_required(uuid, text) from authenticated;
grant execute on function public.server_tx_mark_google_reauth_required(uuid, text) to service_role;

-- private-schema state (encrypted credential, syncToken, target calendar
-- id) is not reachable from PostgREST/.rpc() directly, so process-google-sync
-- and renew-google-watch fetch everything they need for one calendar
-- connection through this single service_role-only read.
create or replace function public.server_tx_get_google_sync_context(p_calendar_connection_id uuid)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select jsonb_build_object(
    'household_id', cc.household_id,
    'calendar_connection_id', cc.id,
    'external_calendar_id', cc.external_calendar_id,
    'active', cc.active,
    'reauth_required', cc.reauth_required,
    'google_connection_id', gc.id,
    'encrypted_refresh_token', gc.encrypted_refresh_token,
    'encryption_version', gc.encryption_version,
    'connection_status', gc.status,
    'next_sync_token', gs.next_sync_token
  )
  from public.calendar_connections cc
  join private.google_connections gc on gc.id = cc.google_connection_id
  left join private.google_sync_state gs on gs.calendar_connection_id = cc.id
  where cc.id = p_calendar_connection_id;
$$;

revoke all on function public.server_tx_get_google_sync_context(uuid) from public;
revoke all on function public.server_tx_get_google_sync_context(uuid) from anon;
revoke all on function public.server_tx_get_google_sync_context(uuid) from authenticated;
grant execute on function public.server_tx_get_google_sync_context(uuid) to service_role;
