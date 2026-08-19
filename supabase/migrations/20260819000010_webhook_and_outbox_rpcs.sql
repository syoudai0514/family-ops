-- v6 review fix (P1-2): private.webhook_inbox and private.notification_outbox
-- must never be reachable from an Edge Function's Data API client
-- (`.from('webhook_inbox')`/`.from('notification_outbox')`), even under
-- service_role. `private` is deliberately absent from `[api] schemas` in
-- supabase/config.toml, so those calls would 404 against a real project
-- regardless — but relying on that alone is fragile (a future config change
-- could silently reintroduce exposure). The DDL contract is explicit that
-- the *only* interface Edge Functions use for DB work is `public.server_tx_*`
-- (docs/design/v6/15_DDL_CONTRACT.md #8, "Atomic Edge transaction entrypoints
-- are public.server_tx_* only"). These two RPCs give line-webhook-receiver
-- and send-notifications a transaction-boundary-correct path instead.

create or replace function public.server_tx_ingest_line_webhook_event(
  p_provider_event_id text,
  p_source_external_user_id text,
  p_payload jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if coalesce(p_provider_event_id, '') = '' or p_payload is null then
    raise exception 'INVALID_INPUT';
  end if;

  insert into private.webhook_inbox (provider, provider_event_id, source_external_user_id, payload)
  values ('line', p_provider_event_id, p_source_external_user_id, p_payload)
  on conflict (provider, provider_event_id) do nothing;

  -- FOUND is true iff the INSERT actually added a row; false means this
  -- provider_event_id already existed (LINE redelivery) and is a safe no-op.
  return jsonb_build_object('is_new', found);
end;
$$;

revoke all on function public.server_tx_ingest_line_webhook_event(text, text, jsonb) from public;
revoke all on function public.server_tx_ingest_line_webhook_event(text, text, jsonb) from anon;
revoke all on function public.server_tx_ingest_line_webhook_event(text, text, jsonb) from authenticated;
grant execute on function public.server_tx_ingest_line_webhook_event(text, text, jsonb) to service_role;

create or replace function public.server_tx_count_queued_notifications()
returns integer
language sql
stable
security invoker
set search_path = ''
as $$
  select count(*)::int from private.notification_outbox where status = 'queued';
$$;

revoke all on function public.server_tx_count_queued_notifications() from public;
revoke all on function public.server_tx_count_queued_notifications() from anon;
revoke all on function public.server_tx_count_queued_notifications() from authenticated;
grant execute on function public.server_tx_count_queued_notifications() to service_role;
