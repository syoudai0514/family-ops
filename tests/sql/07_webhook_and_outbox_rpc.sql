-- v6 review fixes P1-2/P1-3/P1-5: webhook_inbox/notification_outbox are only
-- ever touched through public.server_tx_* RPCs (never Data API .from()),
-- server_tx_ingest_line_webhook_event correctly distinguishes "new" from
-- "duplicate" so the Edge Function can tell LINE apart 200-vs-5xx, and the
-- queue status/lease CHECK constraints hold.
\set ON_ERROR_STOP on

set role service_role;

do $$
declare
  v_result jsonb;
begin
  -- first ingest of a given provider_event_id is new
  v_result := public.server_tx_ingest_line_webhook_event('evt-dedup-1', 'Uabc123', '{"type":"message"}'::jsonb);
  if not (v_result->>'is_new')::boolean then
    raise exception 'FAIL webhook-rpc: first ingest of a new provider_event_id must report is_new=true';
  end if;

  -- redelivery of the same provider_event_id is a duplicate no-op, not an error
  v_result := public.server_tx_ingest_line_webhook_event('evt-dedup-1', 'Uabc123', '{"type":"message"}'::jsonb);
  if (v_result->>'is_new')::boolean then
    raise exception 'FAIL webhook-rpc: redelivery of the same provider_event_id must report is_new=false';
  end if;

  if (select count(*) from private.webhook_inbox where provider_event_id = 'evt-dedup-1') <> 1 then
    raise exception 'FAIL webhook-rpc: redelivery must not create a second row';
  end if;

  -- missing provider_event_id is rejected before any insert
  begin
    perform public.server_tx_ingest_line_webhook_event('', 'Uabc123', '{}'::jsonb);
    raise exception 'FAIL webhook-rpc: empty provider_event_id must be rejected';
  exception
    when others then
      if sqlerrm <> 'INVALID_INPUT' then
        raise exception 'FAIL webhook-rpc: expected INVALID_INPUT, got %', sqlerrm;
      end if;
  end;
end;
$$;

do $$
declare
  v_before int;
  v_after int;
  v_hh jsonb;
  v_hh_id uuid;
begin
  insert into auth.users (id) values ('e0000000-0000-0000-0000-000000000001');
  v_hh := public.server_tx_create_household('e0000000-0000-0000-0000-000000000001', gen_random_uuid(), 'Outbox Count HH', 'Owner');
  v_hh_id := (v_hh->>'household_id')::uuid;

  v_before := public.server_tx_count_queued_notifications();

  insert into private.notification_outbox (household_id, recipient_user_id, channel, type, payload, dedup_key)
  values (v_hh_id, 'e0000000-0000-0000-0000-000000000001', 'line', 'test', '{}'::jsonb, 'outbox-count-dedup-1');

  v_after := public.server_tx_count_queued_notifications();
  if v_after <> v_before + 1 then
    raise exception 'FAIL outbox-rpc: server_tx_count_queued_notifications did not reflect the new queued row (before=%, after=%)', v_before, v_after;
  end if;
end;
$$;

-- P1-5: queue status/lease CHECK constraints
do $$
begin
  begin
    insert into private.webhook_inbox (provider, provider_event_id, payload, status)
    values ('line', 'evt-lease-check-1', '{}'::jsonb, 'processing');
    raise exception 'FAIL queue-lease: webhook_inbox status=processing without a lease must be rejected';
  exception
    when check_violation then null;
  end;

  begin
    insert into private.webhook_inbox
      (provider, provider_event_id, payload, status, lease_owner, lease_token, lease_until)
    values
      ('line', 'evt-lease-check-2', '{}'::jsonb, 'received', 'worker-1', gen_random_uuid(), now() + interval '5 minutes');
    raise exception 'FAIL queue-lease: webhook_inbox status=received with a lease must be rejected';
  exception
    when check_violation then null;
  end;
end;
$$;

do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
begin
  insert into auth.users (id) values ('e0000000-0000-0000-0000-000000000002') on conflict do nothing;
  v_hh := public.server_tx_create_household('e0000000-0000-0000-0000-000000000002', gen_random_uuid(), 'Lease Check HH', 'Owner');
  v_hh_id := (v_hh->>'household_id')::uuid;

  begin
    insert into private.notification_outbox
      (household_id, recipient_user_id, channel, type, payload, dedup_key, status)
    values
      (v_hh_id, 'e0000000-0000-0000-0000-000000000002', 'line', 'test', '{}'::jsonb, 'lease-check-1', 'sending');
    raise exception 'FAIL queue-lease: notification_outbox status=sending without a lease must be rejected';
  exception
    when check_violation then null;
  end;

  begin
    insert into private.pending_actions
      (household_id, actor_id, source, action_type, normalized_payload, operation_id, status, expires_at)
    values
      (v_hh_id, 'e0000000-0000-0000-0000-000000000002', 'pwa', 'test', '{}'::jsonb, gen_random_uuid(), 'executing', now() + interval '5 minutes');
    raise exception 'FAIL queue-lease: pending_actions status=executing without a lease must be rejected';
  exception
    when check_violation then null;
  end;
end;
$$;

reset role;

-- Even if a future config mistake exposed the private schema to the Data
-- API, service_role querying webhook_inbox/notification_outbox directly
-- (bypassing the RPC boundary) must remain something Edge code never does —
-- enforced here as "the tables are reachable to service_role only via
-- direct SQL/RPC, and authenticated/anon still can't touch them at all",
-- which 02/03 already assert. This file's job is the RPC *behavior*, above.

select 'webhook_and_outbox_rpc: PASS' as result;
