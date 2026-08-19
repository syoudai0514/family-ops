-- WP7B: Google Calendar watch channel lifecycle + webhook admission.
-- docs/design/v6/07_GOOGLE_CALENDAR.md #4 "Watch channel", #5 "Renewal".
-- All service_role-only (called from renew-google-watch and
-- google-calendar-webhook, never directly by the PWA).

-- Step 1-2 of renewal ("create new watch" happens against Google's API in
-- the edge function; this persists the new active row"). Also used for the
-- very first watch a calendar_connection ever gets.
create or replace function public.server_tx_register_google_watch_channel(
  p_calendar_connection_id uuid,
  p_channel_id text,
  p_resource_id text,
  p_token_hash text,
  p_expires_at timestamptz
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if p_calendar_connection_id is null or p_channel_id is null or p_resource_id is null
     or p_token_hash is null or p_expires_at is null then
    raise exception 'INVALID_INPUT';
  end if;

  insert into private.google_watch_channels (
    channel_id, calendar_connection_id, resource_id, token_hash, status, expires_at
  ) values (
    p_channel_id, p_calendar_connection_id, p_resource_id, p_token_hash, 'active', p_expires_at
  );

  -- Step 3-4 "accept old+new overlap": previously-active channels for the
  -- same calendar move to 'retiring' (webhook admission still accepts them)
  -- rather than being stopped immediately; the caller stops them at Google
  -- and marks them 'stopped' via server_tx_mark_google_watch_stopped only
  -- after the stop call succeeds.
  update private.google_watch_channels
  set status = 'retiring'
  where calendar_connection_id = p_calendar_connection_id
    and status = 'active'
    and channel_id <> p_channel_id;

  return jsonb_build_object('channel_id', p_channel_id);
end;
$$;

revoke all on function public.server_tx_register_google_watch_channel(uuid, text, text, text, timestamptz) from public;
revoke all on function public.server_tx_register_google_watch_channel(uuid, text, text, text, timestamptz) from anon;
revoke all on function public.server_tx_register_google_watch_channel(uuid, text, text, text, timestamptz) from authenticated;
grant execute on function public.server_tx_register_google_watch_channel(uuid, text, text, text, timestamptz) to service_role;

-- Step 5-6 of renewal: stop confirmed at Google, mark stopped locally.
create or replace function public.server_tx_mark_google_watch_stopped(p_channel_id text)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  update private.google_watch_channels
  set status = 'stopped'
  where channel_id = p_channel_id and status in ('active', 'retiring');
end;
$$;

revoke all on function public.server_tx_mark_google_watch_stopped(text) from public;
revoke all on function public.server_tx_mark_google_watch_stopped(text) from anon;
revoke all on function public.server_tx_mark_google_watch_stopped(text) from authenticated;
grant execute on function public.server_tx_mark_google_watch_stopped(text) to service_role;

create or replace function public.server_tx_list_google_watch_channels_needing_renewal(p_lead_minutes int default 60)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'channel_id', channel_id,
    'calendar_connection_id', calendar_connection_id,
    'resource_id', resource_id,
    'expires_at', expires_at
  )), '[]'::jsonb)
  from private.google_watch_channels
  where status = 'active'
    and expires_at < now() + make_interval(mins => coalesce(p_lead_minutes, 60));
$$;

revoke all on function public.server_tx_list_google_watch_channels_needing_renewal(int) from public;
revoke all on function public.server_tx_list_google_watch_channels_needing_renewal(int) from anon;
revoke all on function public.server_tx_list_google_watch_channels_needing_renewal(int) from authenticated;
grant execute on function public.server_tx_list_google_watch_channels_needing_renewal(int) to service_role;

-- Webhook admission: verifies Channel-ID/Resource-ID/Channel-Token against
-- the stored row (active or retiring — "accept old+new overlap") *before*
-- any sync is enqueued. An unknown/stopped/expired/mismatched channel is
-- reported as not-accepted so the caller can return 2xx and silently ignore
-- it (#4 "no 4xx retry storm for stale valid-provider channel notifications"),
-- never raised as an exception.
create or replace function public.server_tx_admit_google_webhook(
  p_channel_id text,
  p_resource_id text,
  p_token_hash text
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_channel record;
begin
  if p_channel_id is null then
    return jsonb_build_object('accepted', false);
  end if;

  select * into v_channel
  from private.google_watch_channels
  where channel_id = p_channel_id
    and status in ('active', 'retiring')
    and expires_at > now();

  if not found
     or v_channel.resource_id is distinct from p_resource_id
     or v_channel.token_hash is distinct from p_token_hash then
    return jsonb_build_object('accepted', false);
  end if;

  return jsonb_build_object('accepted', true, 'calendar_connection_id', v_channel.calendar_connection_id);
end;
$$;

revoke all on function public.server_tx_admit_google_webhook(text, text, text) from public;
revoke all on function public.server_tx_admit_google_webhook(text, text, text) from anon;
revoke all on function public.server_tx_admit_google_webhook(text, text, text) from authenticated;
grant execute on function public.server_tx_admit_google_webhook(text, text, text) to service_role;
