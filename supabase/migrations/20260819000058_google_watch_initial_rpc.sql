-- WP7B: a freshly-connected calendar has no watch channel row at all yet
-- (oauth-callback only stores the credential/target calendar; it does not
-- call Google's watch API itself). renew-google-watch must find these too,
-- not just channels approaching expiry, or a new connection would silently
-- rely on the 30m poll alone forever.
create or replace function public.server_tx_list_calendar_connections_needing_watch(p_lead_minutes int default 60)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'calendar_connection_id', cc.id,
    'external_calendar_id', cc.external_calendar_id
  )), '[]'::jsonb)
  from public.calendar_connections cc
  where cc.active and not cc.reauth_required
    and not exists (
      select 1 from private.google_watch_channels w
      where w.calendar_connection_id = cc.id and w.status = 'active'
        and w.expires_at >= now() + make_interval(mins => coalesce(p_lead_minutes, 60))
    );
$$;

revoke all on function public.server_tx_list_calendar_connections_needing_watch(int) from public;
revoke all on function public.server_tx_list_calendar_connections_needing_watch(int) from anon;
revoke all on function public.server_tx_list_calendar_connections_needing_watch(int) from authenticated;
grant execute on function public.server_tx_list_calendar_connections_needing_watch(int) to service_role;

-- #5 renewal step 5-6 cleanup sweep: channels demoted to 'retiring' by a
-- prior renewal, old enough that the overlap window has clearly closed
-- (a completed sync job would have coalesced across it by then), are ready
-- to be stopped at Google and marked 'stopped' locally.
create or replace function public.server_tx_list_retiring_google_watch_channels(p_older_than_minutes int default 30)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'channel_id', channel_id,
    'resource_id', resource_id,
    'calendar_connection_id', calendar_connection_id
  )), '[]'::jsonb)
  from private.google_watch_channels
  where status = 'retiring'
    and updated_at < now() - make_interval(mins => coalesce(p_older_than_minutes, 30));
$$;

revoke all on function public.server_tx_list_retiring_google_watch_channels(int) from public;
revoke all on function public.server_tx_list_retiring_google_watch_channels(int) from anon;
revoke all on function public.server_tx_list_retiring_google_watch_channels(int) from authenticated;
grant execute on function public.server_tx_list_retiring_google_watch_channels(int) to service_role;
