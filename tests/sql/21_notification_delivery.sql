-- WP9: send-notifications' outbox drain -- bridge/bundling trigger
-- (20260819000070_notification_outbox_line_bridge.sql) and the
-- claim/complete/fail/refresh worker RPCs
-- (20260819000071_notification_outbox_worker_rpcs.sql). Quota reserve/
-- commit/release/mark_ambiguous concurrency guarantees themselves are
-- already covered exhaustively by tests/sql/05_line_quota_reservation.sql;
-- this file focuses on send-notifications' own new logic: bundling at
-- bridge-insert time, lease/reclaim/dead-letter, business/retry-key
-- expiry sweeps, and the fail() outcome state machine.
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('15000000-0000-0000-0000-000000000001'), -- HH1 owner / requester
  ('15000000-0000-0000-0000-000000000002'), -- HH1 member, LINE-linked recipient
  ('15000000-0000-0000-0000-000000000003'), -- HH1 member, never linked LINE
  ('15000000-0000-0000-0000-000000000004'), -- HH2 owner
  ('15000000-0000-0000-0000-000000000005'); -- HH2 member, used for direct-insert worker mechanics tests

set role service_role;

-- ---------------------------------------------------------------------------
-- Bridge + bundling: multiple pending event-driven notifications for the
-- same recipient collapse into one still-queued notification_outbox row
-- (docs/design/v6/06_LINE_INTEGRATION.md #11 "one message";
-- 15_DDL_CONTRACT.md #320 "one outbox row referenced by multiple ...
-- receipts"); a recipient with no active LINE link, or with the relevant
-- preference off, or an unmapped notification type, never gets one.
-- ---------------------------------------------------------------------------
do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_outbox_count int;
  v_items jsonb;
  v_out_id uuid;
begin
  v_hh := public.server_tx_create_household('15000000-0000-0000-0000-000000000001', gen_random_uuid(), 'Notify Bridge HH', 'Owner');
  v_hh_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role) values
    (v_hh_id, '15000000-0000-0000-0000-000000000002', 'adult'),
    (v_hh_id, '15000000-0000-0000-0000-000000000003', 'adult');
  -- server_tx_create_household/join_household insert notification_preferences
  -- for members created through those RPCs; a direct household_members
  -- insert (test setup shortcut, not a real join flow) must do the same
  -- here or the bridge trigger correctly (and silently, by design) treats
  -- a missing preferences row as "off".
  insert into public.notification_preferences (household_id, user_id) values
    (v_hh_id, '15000000-0000-0000-0000-000000000002'),
    (v_hh_id, '15000000-0000-0000-0000-000000000003');

  insert into private.line_user_links (household_id, user_id, line_user_id)
  values (v_hh_id, '15000000-0000-0000-0000-000000000002', 'Ubridge-recipient-1');
  -- f0000000...003 deliberately never linked.

  -- Two independent event-driven notifications (a request, then a
  -- handover) land for the same LINE-linked recipient before anything
  -- claims the outbox.
  perform public.server_tx_send_request(
    '15000000-0000-0000-0000-000000000001', gen_random_uuid(), '15000000-0000-0000-0000-000000000002',
    'Buy milk', 'before dinner', null
  );
  perform public.server_tx_create_handover(
    '15000000-0000-0000-0000-000000000001', gen_random_uuid(), 'Kids fed, homework left', 'evening', '{}', current_date
  );

  select count(*) into v_outbox_count
  from private.notification_outbox
  where household_id = v_hh_id and recipient_user_id = '15000000-0000-0000-0000-000000000002' and channel = 'line';
  if v_outbox_count <> 1 then
    raise exception 'FAIL notify-bridge: two pending event-driven notifications for the same recipient must bundle into one queued outbox row, got %', v_outbox_count;
  end if;

  select id, payload -> 'items' into v_out_id, v_items
  from private.notification_outbox
  where household_id = v_hh_id and recipient_user_id = '15000000-0000-0000-0000-000000000002' and channel = 'line';
  if jsonb_array_length(v_items) <> 2 then
    raise exception 'FAIL notify-bridge: bundled outbox row must carry both items, got % items', jsonb_array_length(v_items);
  end if;
  if (select status from private.notification_outbox where id = v_out_id) <> 'queued' then
    raise exception 'FAIL notify-bridge: bundled row must remain queued (unclaimed)';
  end if;

  -- Never-linked recipient: in-app row exists (WP2 behavior, unchanged) but
  -- no LINE outbox row is ever created for them.
  perform public.server_tx_send_request(
    '15000000-0000-0000-0000-000000000001', gen_random_uuid(), '15000000-0000-0000-0000-000000000003',
    'Take out trash', null, null
  );
  if exists (
    select 1 from private.notification_outbox
    where household_id = v_hh_id and recipient_user_id = '15000000-0000-0000-0000-000000000003'
  ) then
    raise exception 'FAIL notify-bridge: a recipient with no active LINE link must never get a LINE outbox row';
  end if;
  if not exists (
    select 1 from public.user_notifications
    where household_id = v_hh_id and recipient_user_id = '15000000-0000-0000-0000-000000000003' and type = 'request_received'
  ) then
    raise exception 'FAIL notify-bridge: in-app history must still be written regardless of LINE linkage';
  end if;

  -- Preference off: disable handover_line for the linked recipient, then a
  -- new handover for them must not add to (or create) a LINE outbox row.
  update public.notification_preferences
  set handover_line = false
  where household_id = v_hh_id and user_id = '15000000-0000-0000-0000-000000000002';

  -- Claim the existing bundle first so a fresh bundle-or-not check is unambiguous.
  perform public.server_tx_claim_notification_outbox_batch('bridge-test-worker', 10, 60);

  perform public.server_tx_create_handover(
    '15000000-0000-0000-0000-000000000001', gen_random_uuid(), 'Preference-off check', 'morning', '{}', current_date
  );
  if exists (
    select 1 from private.notification_outbox
    where household_id = v_hh_id and recipient_user_id = '15000000-0000-0000-0000-000000000002'
      and status = 'queued'
  ) then
    raise exception 'FAIL notify-bridge: handover_line=false must suppress the LINE outbox insert for handover_created';
  end if;

  -- Unmapped type: direct insert (no server_tx_* produces this type today)
  -- must never enqueue a LINE row either.
  insert into public.user_notifications (household_id, recipient_user_id, type, title, body, dedup_key)
  values (v_hh_id, '15000000-0000-0000-0000-000000000002', 'some_future_type', 't', 'b', 'unmapped-1');
  if exists (
    select 1 from private.notification_outbox
    where household_id = v_hh_id and recipient_user_id = '15000000-0000-0000-0000-000000000002'
      and status = 'queued'
  ) then
    raise exception 'FAIL notify-bridge: an unmapped user_notifications.type must never enqueue a LINE outbox row';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Worker mechanics: claim/lease/reclaim/dead-letter, quota-permit
-- integration (reserve -> complete commits it; reserve -> quota_fallback
-- releases it), a definitive failure with no reservation ever made, and the
-- ambiguous/retry-key-expiry/business-expiry sweeps. All share one
-- household+recipient (direct private.notification_outbox inserts, not the
-- bridge trigger, since these test the worker RPCs themselves).
-- ---------------------------------------------------------------------------
do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_recipient uuid := '15000000-0000-0000-0000-000000000005';
  v_out_id uuid;
  v_claimed jsonb;
  v_row jsonb;
  v_retry_key_1 uuid;
  v_retry_key_2 uuid;
  v_lease_token uuid;
  v_result jsonb;
  v_reservation jsonb;
  v_reservation_id uuid;
begin
  v_hh := public.server_tx_create_household('15000000-0000-0000-0000-000000000004', gen_random_uuid(), 'Worker Mechanics HH', 'Owner');
  v_hh_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role)
  values (v_hh_id, v_recipient, 'adult');

  -- === claim / lease / reclaim / dead-letter ===
  insert into private.notification_outbox (id, household_id, recipient_user_id, channel, type, payload, dedup_key)
  values (gen_random_uuid(), v_hh_id, v_recipient, 'line', 'test',
          jsonb_build_object('items', jsonb_build_array(jsonb_build_object('title', 'T', 'body', 'B'))),
          'claim-lease-1')
  returning id into v_out_id;

  v_claimed := public.server_tx_claim_notification_outbox_batch('worker-a', 10, 60);
  select value into v_row from jsonb_array_elements(v_claimed) as value where (value->>'id')::uuid = v_out_id;
  if v_row is null then
    raise exception 'FAIL claim-lease: newly queued row must be claimable';
  end if;
  v_retry_key_1 := (v_row->>'provider_retry_key')::uuid;
  if v_retry_key_1 is null then
    raise exception 'FAIL claim-lease: first claim must assign a provider_retry_key';
  end if;
  if (select status from private.notification_outbox where id = v_out_id) <> 'sending' then
    raise exception 'FAIL claim-lease: claimed row must be status=sending';
  end if;

  v_claimed := public.server_tx_claim_notification_outbox_batch('worker-b', 10, 60);
  if exists (select 1 from jsonb_array_elements(v_claimed) as value where (value->>'id')::uuid = v_out_id) then
    raise exception 'FAIL claim-lease: a row with an unexpired lease must not be reclaimed by another worker';
  end if;

  update private.notification_outbox set lease_until = now() - interval '1 minute' where id = v_out_id;

  v_claimed := public.server_tx_claim_notification_outbox_batch('worker-c', 10, 60);
  select value into v_row from jsonb_array_elements(v_claimed) as value where (value->>'id')::uuid = v_out_id;
  if v_row is null then
    raise exception 'FAIL claim-lease: a row with an expired lease must be reclaimable by another worker';
  end if;
  v_retry_key_2 := (v_row->>'provider_retry_key')::uuid;
  if v_retry_key_2 <> v_retry_key_1 then
    raise exception 'FAIL claim-lease: reclaim must keep the SAME provider_retry_key as the first attempt';
  end if;
  if (select attempts from private.notification_outbox where id = v_out_id) <> 2 then
    raise exception 'FAIL claim-lease: reclaim must increment attempts (expected 2)';
  end if;

  v_lease_token := (v_row->>'lease_token')::uuid;
  -- attempts is already 2 here (first claim + reclaim); max_attempts=3 so
  -- this failure is still under the cap and must requeue, not dead-letter.
  v_result := public.server_tx_fail_notification_outbox_item(v_out_id, v_lease_token, 'boom', 'transient', 3, 60);
  if (v_result->>'status') <> 'queued' then
    raise exception 'FAIL claim-lease: transient failure under max_attempts must requeue, got %', v_result->>'status';
  end if;

  update private.notification_outbox set next_attempt_at = now() where id = v_out_id;
  v_claimed := public.server_tx_claim_notification_outbox_batch('worker-d', 10, 60);
  select value into v_row from jsonb_array_elements(v_claimed) as value where (value->>'id')::uuid = v_out_id;
  if (v_row->>'provider_retry_key')::uuid <> v_retry_key_1 then
    raise exception 'FAIL claim-lease: retry-key idempotency violated after a transient failure requeue';
  end if;
  if (v_row->>'attempts')::int <> 3 then
    raise exception 'FAIL claim-lease: expected attempts=3 after a second claim, got %', v_row->>'attempts';
  end if;

  v_lease_token := (v_row->>'lease_token')::uuid;
  -- attempts is now 3, at max_attempts=3 -> dead-letter.
  v_result := public.server_tx_fail_notification_outbox_item(v_out_id, v_lease_token, 'boom again', 'transient', 3, 60);
  if (v_result->>'status') <> 'dead' then
    raise exception 'FAIL claim-lease: transient failure at/over max_attempts(3) must dead-letter, got %', v_result->>'status';
  end if;
  if (select lease_owner from private.notification_outbox where id = v_out_id) is not null then
    raise exception 'FAIL claim-lease: dead-lettered row must have its lease cleared';
  end if;

  -- === quota-permit integration: complete commits, quota_fallback releases ===
  insert into private.notification_outbox (id, household_id, recipient_user_id, channel, type, payload, dedup_key)
  values (gen_random_uuid(), v_hh_id, v_recipient, 'line', 'test', '{}'::jsonb, 'quota-int-1')
  returning id into v_out_id;

  v_claimed := public.server_tx_claim_notification_outbox_batch('quota-worker', 10, 60);
  select value into v_row from jsonb_array_elements(v_claimed) as value where (value->>'id')::uuid = v_out_id;
  v_lease_token := (v_row->>'lease_token')::uuid;

  v_reservation := public.server_tx_reserve_line_quota(v_out_id, 'normal');
  if not (v_reservation->>'permitted')::boolean then
    raise exception 'FAIL quota-integration: reservation should be permitted at low usage';
  end if;
  v_reservation_id := (v_reservation->>'reservation_id')::uuid;

  v_result := public.server_tx_complete_notification_outbox_item(v_out_id, v_lease_token);
  if (v_result->>'status') <> 'sent' then
    raise exception 'FAIL quota-integration: complete must report status=sent, got %', v_result->>'status';
  end if;
  if (select status from private.line_quota_reservations where id = v_reservation_id) <> 'committed' then
    raise exception 'FAIL quota-integration: complete must commit the linked quota reservation';
  end if;
  if (select status from private.notification_outbox where id = v_out_id) <> 'sent' then
    raise exception 'FAIL quota-integration: outbox row must be status=sent after complete';
  end if;

  insert into private.notification_outbox (id, household_id, recipient_user_id, channel, type, payload, dedup_key)
  values (gen_random_uuid(), v_hh_id, v_recipient, 'line', 'test', '{}'::jsonb, 'quota-int-2')
  returning id into v_out_id;

  v_claimed := public.server_tx_claim_notification_outbox_batch('quota-worker-2', 10, 60);
  select value into v_row from jsonb_array_elements(v_claimed) as value where (value->>'id')::uuid = v_out_id;
  v_lease_token := (v_row->>'lease_token')::uuid;

  v_reservation := public.server_tx_reserve_line_quota(v_out_id, 'normal');
  v_reservation_id := (v_reservation->>'reservation_id')::uuid;

  v_result := public.server_tx_fail_notification_outbox_item(v_out_id, v_lease_token, 'monthly limit hit', 'quota_fallback', 5, 60);
  if (v_result->>'status') <> 'fallback' then
    raise exception 'FAIL quota-integration: quota_fallback outcome must set status=fallback, got %', v_result->>'status';
  end if;
  if (select status from private.line_quota_reservations where id = v_reservation_id) <> 'released' then
    raise exception 'FAIL quota-integration: quota_fallback outcome must release the reservation';
  end if;

  -- === definitive failure without ever having reserved quota ===
  insert into private.notification_outbox (id, household_id, recipient_user_id, channel, type, payload, dedup_key)
  values (gen_random_uuid(), v_hh_id, v_recipient, 'line', 'test', '{}'::jsonb, 'no-link-1')
  returning id into v_out_id;

  v_claimed := public.server_tx_claim_notification_outbox_batch('no-link-worker', 10, 60);
  select value into v_row from jsonb_array_elements(v_claimed) as value where (value->>'id')::uuid = v_out_id;
  if (v_row->>'line_user_id') is not null then
    raise exception 'FAIL no-link: claim must report line_user_id=null for a recipient with no active link';
  end if;
  v_lease_token := (v_row->>'lease_token')::uuid;

  v_result := public.server_tx_fail_notification_outbox_item(v_out_id, v_lease_token, 'no active LINE link', 'definitive', 5, 60);
  if (v_result->>'status') <> 'dead' then
    raise exception 'FAIL no-link: definitive outcome must dead-letter, got %', v_result->>'status';
  end if;

  -- === ambiguous: retryable with same key, then swept to delivery_unknown ===
  insert into private.notification_outbox (id, household_id, recipient_user_id, channel, type, payload, dedup_key)
  values (gen_random_uuid(), v_hh_id, v_recipient, 'line', 'test', '{}'::jsonb, 'ambiguous-1')
  returning id into v_out_id;

  v_claimed := public.server_tx_claim_notification_outbox_batch('ambiguous-worker', 10, 60);
  select value into v_row from jsonb_array_elements(v_claimed) as value where (value->>'id')::uuid = v_out_id;
  v_lease_token := (v_row->>'lease_token')::uuid;

  v_result := public.server_tx_fail_notification_outbox_item(v_out_id, v_lease_token, 'timeout', 'ambiguous', 5, 60);
  if (v_result->>'status') <> 'queued' then
    raise exception 'FAIL ambiguous: within the retry-key window, ambiguous must requeue (not dead/delivery_unknown), got %', v_result->>'status';
  end if;

  update private.notification_outbox
  set provider_retry_expires_at = now() - interval '1 minute', next_attempt_at = now()
  where id = v_out_id;

  v_claimed := public.server_tx_claim_notification_outbox_batch('ambiguous-worker-2', 10, 60);
  if exists (select 1 from jsonb_array_elements(v_claimed) as value where (value->>'id')::uuid = v_out_id) then
    raise exception 'FAIL ambiguous: a row past its retry-key expiry must never be claimed for another provider call';
  end if;
  if (select status from private.notification_outbox where id = v_out_id) <> 'delivery_unknown' then
    raise exception 'FAIL ambiguous: expired retry window must sweep the row to delivery_unknown';
  end if;

  -- === business_expires_at sweep: never claim/deliver a stale scheduled item ===
  insert into private.notification_outbox (id, household_id, recipient_user_id, channel, type, payload, dedup_key, business_expires_at)
  values (gen_random_uuid(), v_hh_id, v_recipient, 'line', 'test', '{}'::jsonb, 'business-expiry-1', now() - interval '1 minute')
  returning id into v_out_id;

  v_claimed := public.server_tx_claim_notification_outbox_batch('business-expiry-worker', 10, 60);
  if exists (select 1 from jsonb_array_elements(v_claimed) as value where (value->>'id')::uuid = v_out_id) then
    raise exception 'FAIL business-expiry: a row whose business_expires_at already passed must never be claimed';
  end if;
  if (select status from private.notification_outbox where id = v_out_id) <> 'dead' then
    raise exception 'FAIL business-expiry: expired-before-send row must be swept to dead';
  end if;
end;
$$;

reset role;

select '21_notification_delivery: PASS' as result;
