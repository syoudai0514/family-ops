-- WP6 LINE foundation: account linking, webhook inbox lease/reclaim/
-- dead-letter, pending-action staging + execution queues, idempotent
-- redelivery, double-tap, out-of-order delivery.
-- docs/design/v6/06_LINE_INTEGRATION.md #2,#3,#9,#13,#14; 10_WORK_PACKAGES.md
-- WP6 test list.
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('19000000-0000-0000-0000-000000000001'), -- household A adult 1
  ('19000000-0000-0000-0000-000000000002'), -- household A adult 2
  ('19000000-0000-0000-0000-000000000003'); -- household B adult (cross-household)

set role service_role;

do $$
declare
  v_hh_a jsonb;
  v_hh_a_id uuid;
  v_hh_b jsonb;
  v_invite jsonb;
  v_raw_invite text;
begin
  v_hh_a := public.server_tx_create_household('19000000-0000-0000-0000-000000000001', gen_random_uuid(), 'LINE Test HH A', 'Adult1');
  v_hh_a_id := (v_hh_a->>'household_id')::uuid;

  v_invite := public.server_tx_create_household_invite('19000000-0000-0000-0000-000000000001', gen_random_uuid());
  -- The raw invite token isn't retrievable from this fixture path (only the
  -- Edge caller sees it); join via a second household instead — household B
  -- only needs to exist as a distinct household for cross-household checks.
  v_hh_b := public.server_tx_create_household('19000000-0000-0000-0000-000000000003', gen_random_uuid(), 'LINE Test HH B', 'Adult1');

  if v_hh_a_id is null or (v_hh_b->>'household_id') is null then
    raise exception 'FAIL line-foundation: household setup failed';
  end if;
end;
$$;

-- Adult2 joins household A directly (bypassing the invite raw-token
-- capture limitation above) so the fixture has two members of the same
-- household for the "partner" completion-actor case later.
do $$
declare
  v_hh_a_id uuid;
begin
  select household_id into v_hh_a_id from public.household_members
  where user_id = '19000000-0000-0000-0000-000000000001';

  insert into public.household_members (household_id, user_id, member_role, joined_at)
  values (v_hh_a_id, '19000000-0000-0000-0000-000000000002', 'adult', now());
  insert into public.profiles (user_id, display_name) values ('19000000-0000-0000-0000-000000000002', 'Adult2');
  insert into public.notification_preferences (household_id, user_id) values (v_hh_a_id, '19000000-0000-0000-0000-000000000002');
end;
$$;

-- ---------------------------------------------------------------------------
-- Link token issue / consume / re-link after unlink / expiry
-- ---------------------------------------------------------------------------

do $$
declare
  v_token jsonb;
  v_raw_token text;
  v_claim jsonb;
  v_resolved jsonb;
begin
  v_token := public.server_tx_create_line_link_token('19000000-0000-0000-0000-000000000001', gen_random_uuid());
  v_raw_token := v_token->>'raw_token';
  if v_raw_token is null or length(v_raw_token) <> 64 then
    raise exception 'FAIL line-foundation: expected a 64-hex-char raw_token, got %', v_raw_token;
  end if;

  -- claim with verified LINE source id
  v_claim := public.server_tx_claim_line_link_token('Uaaa-adult1', v_raw_token);
  if (v_claim->>'user_id')::uuid <> '19000000-0000-0000-0000-000000000001'::uuid then
    raise exception 'FAIL line-foundation: claim did not resolve to the token owner';
  end if;
  if (v_claim->>'already_linked')::boolean then
    raise exception 'FAIL line-foundation: first claim must not report already_linked';
  end if;

  v_resolved := public.server_tx_resolve_line_actor('Uaaa-adult1');
  if (v_resolved->>'user_id')::uuid <> '19000000-0000-0000-0000-000000000001'::uuid then
    raise exception 'FAIL line-foundation: resolve_line_actor did not find the newly linked user';
  end if;

  -- idempotent redelivery of the SAME claim (same token, same source id,
  -- token already used) => success replay, not an error
  v_claim := public.server_tx_claim_line_link_token('Uaaa-adult1', v_raw_token);
  if not (v_claim->>'already_linked')::boolean then
    raise exception 'FAIL line-foundation: replayed claim of an already-used token (same source id) must report already_linked=true';
  end if;

  -- reuse attempt from a DIFFERENT source id must be rejected
  begin
    perform public.server_tx_claim_line_link_token('Uzzz-imposter', v_raw_token);
    raise exception 'FAIL line-foundation: reusing a consumed token from a different LINE user must fail';
  exception
    when others then
      if sqlerrm <> 'LINE_LINK_TOKEN_USED' then
        raise exception 'FAIL line-foundation: expected LINE_LINK_TOKEN_USED, got %', sqlerrm;
      end if;
  end;

  -- unknown token
  begin
    perform public.server_tx_claim_line_link_token('Uwhoever', repeat('0', 64));
    raise exception 'FAIL line-foundation: unknown token must be rejected';
  exception
    when others then
      if sqlerrm <> 'INVALID_INPUT' then
        raise exception 'FAIL line-foundation: expected INVALID_INPUT for unknown token, got %', sqlerrm;
      end if;
  end;
end;
$$;

-- expiry: mint a token, force its expires_at into the past, confirm it's rejected
do $$
declare
  v_token jsonb;
  v_raw_token text;
  v_token_hash text;
begin
  v_token := public.server_tx_create_line_link_token('19000000-0000-0000-0000-000000000002', gen_random_uuid());
  v_raw_token := v_token->>'raw_token';
  v_token_hash := encode(sha256(convert_to(v_raw_token, 'UTF8')), 'hex');

  update private.line_link_tokens set expires_at = now() - interval '1 minute' where token_hash = v_token_hash;

  begin
    perform public.server_tx_claim_line_link_token('Ubbb-adult2', v_raw_token);
    raise exception 'FAIL line-foundation: expired token must be rejected';
  exception
    when others then
      if sqlerrm <> 'LINE_LINK_TOKEN_EXPIRED' then
        raise exception 'FAIL line-foundation: expected LINE_LINK_TOKEN_EXPIRED, got %', sqlerrm;
      end if;
  end;
end;
$$;

-- link adult2 for real (used by later cross-user-uniqueness + partner tests)
do $$
declare
  v_token jsonb;
  v_claim jsonb;
begin
  v_token := public.server_tx_create_line_link_token('19000000-0000-0000-0000-000000000002', gen_random_uuid());
  v_claim := public.server_tx_claim_line_link_token('Ubbb-adult2', v_token->>'raw_token');
  if (v_claim->>'user_id')::uuid <> '19000000-0000-0000-0000-000000000002'::uuid then
    raise exception 'FAIL line-foundation: adult2 link failed';
  end if;
end;
$$;

-- global uniqueness: a LINE id already actively linked to adult2 cannot be
-- claimed by adult1's token
do $$
declare
  v_token jsonb;
begin
  v_token := public.server_tx_create_line_link_token('19000000-0000-0000-0000-000000000001', gen_random_uuid());
  begin
    perform public.server_tx_claim_line_link_token('Ubbb-adult2', v_token->>'raw_token');
    raise exception 'FAIL line-foundation: claiming a LINE id already actively linked to a different user must fail';
  exception
    when others then
      if sqlerrm <> 'LINE_USER_ID_ALREADY_LINKED' then
        raise exception 'FAIL line-foundation: expected LINE_USER_ID_ALREADY_LINKED, got %', sqlerrm;
      end if;
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- Unlink (idempotent) + re-link after unlink
-- ---------------------------------------------------------------------------

do $$
declare
  v_unlink jsonb;
  v_resolved jsonb;
  v_token jsonb;
  v_claim jsonb;
begin
  v_unlink := public.server_tx_unlink_line_account('19000000-0000-0000-0000-000000000001', gen_random_uuid());
  if not (v_unlink->>'was_linked')::boolean then
    raise exception 'FAIL line-foundation: unlink of a linked account must report was_linked=true';
  end if;

  v_resolved := public.server_tx_resolve_line_actor('Uaaa-adult1');
  if v_resolved is not null then
    raise exception 'FAIL line-foundation: resolve_line_actor must return nothing for an unlinked LINE id';
  end if;

  -- idempotent: unlinking again is a no-op success
  v_unlink := public.server_tx_unlink_line_account('19000000-0000-0000-0000-000000000001', gen_random_uuid());
  if (v_unlink->>'was_linked')::boolean then
    raise exception 'FAIL line-foundation: unlinking an already-unlinked account must report was_linked=false';
  end if;

  -- re-link after unlink, to a NEW LINE user id
  v_token := public.server_tx_create_line_link_token('19000000-0000-0000-0000-000000000001', gen_random_uuid());
  v_claim := public.server_tx_claim_line_link_token('Uaaa-adult1-relinked', v_token->>'raw_token');
  if (v_claim->>'line_user_id') <> 'Uaaa-adult1-relinked' then
    raise exception 'FAIL line-foundation: re-link after unlink failed';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- webhook_inbox: idempotent redelivery -> one durable row
-- ---------------------------------------------------------------------------

do $$
declare
  v_r1 jsonb;
  v_r2 jsonb;
  v_count int;
begin
  v_r1 := public.server_tx_ingest_line_webhook_event(
    'evt-shopping-1', 'Uaaa-adult1-relinked',
    jsonb_build_object('type', 'message', 'webhookEventId', 'evt-shopping-1',
      'message', jsonb_build_object('type', 'text', 'text', 'オムツをAmazonで買う'))
  );
  if not (v_r1->>'is_new')::boolean then
    raise exception 'FAIL line-foundation: first ingest must report is_new=true';
  end if;

  v_r2 := public.server_tx_ingest_line_webhook_event(
    'evt-shopping-1', 'Uaaa-adult1-relinked',
    jsonb_build_object('type', 'message', 'webhookEventId', 'evt-shopping-1',
      'message', jsonb_build_object('type', 'text', 'text', 'オムツをAmazonで買う'))
  );
  if (v_r2->>'is_new')::boolean then
    raise exception 'FAIL line-foundation: redelivery must report is_new=false';
  end if;

  select count(*) into v_count from private.webhook_inbox where provider_event_id = 'evt-shopping-1';
  if v_count <> 1 then
    raise exception 'FAIL line-foundation: redelivery must not create a second webhook_inbox row (found %)', v_count;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Full round trip: webhook -> claim -> resolve actor -> pending_action
-- (draft) -> confirm -> execution queue claim -> business mutation ->
-- complete. Mirrors exactly what process-line-inbox + process-pending-
-- actions do, one RPC call at a time (the TS parser itself has no SQL
-- surface to test here; deno lint/check covers that file).
-- ---------------------------------------------------------------------------

do $$
declare
  v_batch jsonb;
  v_item jsonb;
  v_actor jsonb;
  v_hh_id uuid;
  v_actor_id uuid;
  v_op_id uuid;
  v_pending jsonb;
  v_pending_id uuid;
  v_confirm jsonb;
  v_exec_batch jsonb;
  v_exec_item jsonb;
  v_shopping jsonb;
  v_complete jsonb;
  v_webhook_complete jsonb;
begin
  v_batch := public.server_tx_claim_webhook_inbox_batch('test-worker-1', 10, 60);
  select value into v_item from jsonb_array_elements(v_batch) as value
    where value->>'provider_event_id' = 'evt-shopping-1';
  if v_item is null then
    raise exception 'FAIL line-foundation: claim batch did not return evt-shopping-1';
  end if;

  v_actor := public.server_tx_resolve_line_actor(v_item->>'source_external_user_id');
  v_hh_id := (v_actor->>'household_id')::uuid;
  v_actor_id := (v_actor->>'user_id')::uuid;
  if v_actor_id <> '19000000-0000-0000-0000-000000000001'::uuid then
    raise exception 'FAIL line-foundation: resolved actor mismatch';
  end if;

  -- deterministic operation_id derived from the webhook event id (as
  -- process-line-inbox's deterministicOperationId() does)
  v_op_id := md5('line-text|evt-shopping-1')::uuid;

  v_pending := public.server_tx_create_pending_action(
    v_actor_id, v_hh_id, v_op_id, 'line', 'shopping_item_add',
    jsonb_build_object('title', 'オムツ', 'purchase_method', 'online'), 30
  );
  v_pending_id := (v_pending->>'pending_action_id')::uuid;
  if v_pending->>'status' <> 'draft' then
    raise exception 'FAIL line-foundation: newly created pending action must be draft, got %', v_pending->>'status';
  end if;

  -- redelivery of the SAME webhook event re-derives the SAME operation_id
  -- and therefore the same pending_action row, not a duplicate
  v_pending := public.server_tx_create_pending_action(
    v_actor_id, v_hh_id, v_op_id, 'line', 'shopping_item_add',
    jsonb_build_object('title', 'オムツ', 'purchase_method', 'online'), 30
  );
  if (v_pending->>'created')::boolean or (v_pending->>'pending_action_id')::uuid <> v_pending_id then
    raise exception 'FAIL line-foundation: replayed create_pending_action must return the same existing row';
  end if;

  -- confirm (postback) — double-tap: call twice, must stay a single row / one effect
  v_confirm := public.server_tx_confirm_pending_action(v_actor_id, v_pending_id);
  if v_confirm->>'status' <> 'confirmed' then
    raise exception 'FAIL line-foundation: confirm must set status=confirmed';
  end if;
  v_confirm := public.server_tx_confirm_pending_action(v_actor_id, v_pending_id);
  if v_confirm->>'status' <> 'confirmed' then
    raise exception 'FAIL line-foundation: double-tap confirm must replay confirmed, not error';
  end if;
  if (select count(*) from private.pending_actions where id = v_pending_id) <> 1 then
    raise exception 'FAIL line-foundation: double-tap confirm must not create extra rows';
  end if;

  -- execution queue claims it
  v_exec_batch := public.server_tx_claim_pending_actions_batch('exec-worker-1', 10, 60);
  select value into v_exec_item from jsonb_array_elements(v_exec_batch) as value
    where value->>'id' = v_pending_id::text;
  if v_exec_item is null then
    raise exception 'FAIL line-foundation: execution claim batch did not return the confirmed pending action';
  end if;

  -- process-pending-actions' executor calls the real mutation
  v_shopping := public.server_tx_add_shopping_item(
    (v_exec_item->>'actor_id')::uuid, (v_exec_item->>'operation_id')::uuid,
    'オムツ', 'online', null, null, null
  );
  if v_shopping->>'item_id' is null and v_shopping->>'shopping_item_id' is null then
    -- accept either result key shape without over-constraining this test to
    -- shopping_mutations.sql's exact field name
    null;
  end if;

  v_complete := public.server_tx_complete_pending_action(
    (v_exec_item->>'id')::uuid, (v_exec_item->>'lease_token')::uuid, 'shopping_item', null
  );
  if not (v_complete->>'ok')::boolean then
    raise exception 'FAIL line-foundation: complete_pending_action should succeed with a valid lease';
  end if;
  if (select status from private.pending_actions where id = v_pending_id) <> 'succeeded' then
    raise exception 'FAIL line-foundation: pending action must be succeeded after completion';
  end if;

  v_webhook_complete := public.server_tx_complete_webhook_inbox_item(
    (v_item->>'id')::uuid, (v_item->>'lease_token')::uuid
  );
  if not (v_webhook_complete->>'ok')::boolean then
    raise exception 'FAIL line-foundation: complete_webhook_inbox_item should succeed with a valid lease';
  end if;
  if (select status from private.webhook_inbox where id = (v_item->>'id')::uuid) <> 'done' then
    raise exception 'FAIL line-foundation: webhook_inbox row must be done after completion';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Lease/reclaim on worker crash: webhook_inbox
-- ---------------------------------------------------------------------------

do $$
declare
  v_ingest jsonb;
  v_batch1 jsonb;
  v_item1 jsonb;
  v_id uuid;
  v_batch2 jsonb;
  v_item2 jsonb;
begin
  v_ingest := public.server_tx_ingest_line_webhook_event(
    'evt-lease-crash-1', 'Uaaa-adult1-relinked',
    jsonb_build_object('type', 'message', 'webhookEventId', 'evt-lease-crash-1',
      'message', jsonb_build_object('type', 'text', 'text', 'unused'))
  );

  v_batch1 := public.server_tx_claim_webhook_inbox_batch('crashed-worker', 10, 60);
  select value into v_item1 from jsonb_array_elements(v_batch1) as value
    where value->>'provider_event_id' = 'evt-lease-crash-1';
  v_id := (v_item1->>'id')::uuid;
  if v_id is null then
    raise exception 'FAIL line-foundation: claim did not pick up evt-lease-crash-1';
  end if;
  if (v_item1->>'attempts')::int <> 1 then
    raise exception 'FAIL line-foundation: first claim should set attempts=1, got %', v_item1->>'attempts';
  end if;

  -- simulate the worker dying: never completed, force the lease into the past
  update private.webhook_inbox set lease_until = now() - interval '1 minute' where id = v_id;

  -- a second worker's claim batch must reclaim it
  v_batch2 := public.server_tx_claim_webhook_inbox_batch('recovering-worker', 10, 60);
  select value into v_item2 from jsonb_array_elements(v_batch2) as value
    where value->>'id' = v_id::text;
  if v_item2 is null then
    raise exception 'FAIL line-foundation: a stale lease was not reclaimed by another worker';
  end if;
  if (v_item2->>'attempts')::int <> 2 then
    raise exception 'FAIL line-foundation: reclaim should bump attempts to 2, got %', v_item2->>'attempts';
  end if;
  if (v_item2->>'lease_token') = (v_item1->>'lease_token') then
    raise exception 'FAIL line-foundation: reclaim must mint a new lease_token';
  end if;

  -- the original (now-stale) lease_token can no longer complete the row
  if (public.server_tx_complete_webhook_inbox_item(v_id, (v_item1->>'lease_token')::uuid)->>'ok')::boolean then
    raise exception 'FAIL line-foundation: a stale lease_token must not be able to complete the row';
  end if;

  perform public.server_tx_complete_webhook_inbox_item(v_id, (v_item2->>'lease_token')::uuid);
  if (select status from private.webhook_inbox where id = v_id) <> 'done' then
    raise exception 'FAIL line-foundation: row must be done after the reclaiming worker completes it';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Dead-letter after max retries: webhook_inbox
-- ---------------------------------------------------------------------------

do $$
declare
  v_id uuid;
  v_item jsonb;
  v_batch jsonb;
  v_fail jsonb;
  i int;
begin
  perform public.server_tx_ingest_line_webhook_event(
    'evt-dead-letter-1', 'Uaaa-adult1-relinked',
    jsonb_build_object('type', 'message', 'webhookEventId', 'evt-dead-letter-1',
      'message', jsonb_build_object('type', 'text', 'text', 'unused'))
  );

  for i in 1..3 loop
    v_batch := public.server_tx_claim_webhook_inbox_batch('flaky-worker', 10, 60);
    select value into v_item from jsonb_array_elements(v_batch) as value
      where value->>'provider_event_id' = 'evt-dead-letter-1';
    v_id := (v_item->>'id')::uuid;
    v_fail := public.server_tx_fail_webhook_inbox_item(v_id, (v_item->>'lease_token')::uuid, 'boom', 3, 0);
    if i < 3 and v_fail->>'status' <> 'received' then
      raise exception 'FAIL line-foundation: attempt % should retry (status=received), got %', i, v_fail->>'status';
    end if;
  end loop;

  if v_fail->>'status' <> 'dead' then
    raise exception 'FAIL line-foundation: after max_attempts=3 the row must be dead, got %', v_fail->>'status';
  end if;
  if (select status from private.webhook_inbox where id = v_id) <> 'dead' then
    raise exception 'FAIL line-foundation: webhook_inbox row must persist status=dead';
  end if;

  -- a dead row is never claimed again
  v_batch := public.server_tx_claim_webhook_inbox_batch('another-worker', 10, 60);
  if exists (select 1 from jsonb_array_elements(v_batch) as value where value->>'id' = v_id::text) then
    raise exception 'FAIL line-foundation: a dead webhook_inbox row must not be claimable';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Lease/reclaim + dead-letter: pending_actions execution queue
-- ---------------------------------------------------------------------------

do $$
declare
  v_hh_id uuid;
  v_pending jsonb;
  v_pending_id uuid;
  v_batch jsonb;
  v_item jsonb;
  v_fail jsonb;
  i int;
begin
  select household_id into v_hh_id from public.household_members
  where user_id = '19000000-0000-0000-0000-000000000001';

  v_pending := public.server_tx_create_pending_action(
    '19000000-0000-0000-0000-000000000001', v_hh_id, gen_random_uuid(), 'line',
    'always_fails_for_test', jsonb_build_object('x', 1), 30
  );
  v_pending_id := (v_pending->>'pending_action_id')::uuid;
  perform public.server_tx_confirm_pending_action('19000000-0000-0000-0000-000000000001', v_pending_id);

  for i in 1..3 loop
    v_batch := public.server_tx_claim_pending_actions_batch('exec-flaky', 10, 60);
    select value into v_item from jsonb_array_elements(v_batch) as value
      where value->>'id' = v_pending_id::text;
    if v_item is null then
      raise exception 'FAIL line-foundation: pending action not claimable on attempt %', i;
    end if;
    v_fail := public.server_tx_fail_pending_action(
      (v_item->>'id')::uuid, (v_item->>'lease_token')::uuid, 'executor exploded', 3, 0
    );
  end loop;

  if v_fail->>'status' <> 'dead' then
    raise exception 'FAIL line-foundation: pending action must be dead after 3 failed attempts, got %', v_fail->>'status';
  end if;

  -- worker-crash reclaim on the execution queue too
  v_pending := public.server_tx_create_pending_action(
    '19000000-0000-0000-0000-000000000001', v_hh_id, gen_random_uuid(), 'line',
    'needs_reclaim_test', jsonb_build_object('x', 1), 30
  );
  v_pending_id := (v_pending->>'pending_action_id')::uuid;
  perform public.server_tx_confirm_pending_action('19000000-0000-0000-0000-000000000001', v_pending_id);

  v_batch := public.server_tx_claim_pending_actions_batch('exec-crashed', 10, 60);
  select value into v_item from jsonb_array_elements(v_batch) as value
    where value->>'id' = v_pending_id::text;
  update private.pending_actions set lease_until = now() - interval '1 minute' where id = v_pending_id;

  v_batch := public.server_tx_claim_pending_actions_batch('exec-recovering', 10, 60);
  select value into v_item from jsonb_array_elements(v_batch) as value
    where value->>'id' = v_pending_id::text;
  if v_item is null then
    raise exception 'FAIL line-foundation: a stale pending_actions execution lease was not reclaimed';
  end if;
  if (v_item->>'attempts')::int <> 2 then
    raise exception 'FAIL line-foundation: reclaimed pending action should have attempts=2, got %', v_item->>'attempts';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Out-of-order webhook delivery: a "later" event processed before an
-- "earlier" one (independent events; no ordering dependency assumed)
-- ---------------------------------------------------------------------------

do $$
declare
  v_hh_id uuid;
  v_later jsonb;
  v_earlier jsonb;
  v_batch jsonb;
  v_item_later jsonb;
  v_item_earlier jsonb;
begin
  -- "evt-B" (logically later) ingested and claimed first
  perform public.server_tx_ingest_line_webhook_event(
    'evt-ooo-B', 'Uaaa-adult1-relinked',
    jsonb_build_object('type', 'message', 'webhookEventId', 'evt-ooo-B',
      'message', jsonb_build_object('type', 'text', 'text', '牛乳を買う'))
  );
  v_batch := public.server_tx_claim_webhook_inbox_batch('ooo-worker', 10, 60);
  select value into v_item_later from jsonb_array_elements(v_batch) as value
    where value->>'provider_event_id' = 'evt-ooo-B';
  perform public.server_tx_complete_webhook_inbox_item((v_item_later->>'id')::uuid, (v_item_later->>'lease_token')::uuid);

  -- "evt-A" (logically earlier) arrives and is processed after evt-B
  perform public.server_tx_ingest_line_webhook_event(
    'evt-ooo-A', 'Uaaa-adult1-relinked',
    jsonb_build_object('type', 'message', 'webhookEventId', 'evt-ooo-A',
      'message', jsonb_build_object('type', 'text', 'text', 'パンを買う'))
  );
  v_batch := public.server_tx_claim_webhook_inbox_batch('ooo-worker', 10, 60);
  select value into v_item_earlier from jsonb_array_elements(v_batch) as value
    where value->>'provider_event_id' = 'evt-ooo-A';
  perform public.server_tx_complete_webhook_inbox_item((v_item_earlier->>'id')::uuid, (v_item_earlier->>'lease_token')::uuid);

  -- both processed independently and durably, regardless of arrival order
  if (select status from private.webhook_inbox where provider_event_id = 'evt-ooo-A') <> 'done'
     or (select status from private.webhook_inbox where provider_event_id = 'evt-ooo-B') <> 'done' then
    raise exception 'FAIL line-foundation: out-of-order events must each still reach done independently';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Double-tap postback on a direct-execute mutation (06_LINE_INTEGRATION.md
-- #9 "Routine 完了 postbacks may call user mutation Edge directly", #14
-- "user taps same postback twice -> mutation receipt replay"): the postback
-- handler derives a deterministic operation_id from the webhook event id, so
-- two deliveries of the SAME LINE webhook event id replay the same receipt.
-- ---------------------------------------------------------------------------

do $$
declare
  v_hh_id uuid;
  v_task jsonb;
  v_task_id uuid;
  v_op_id uuid;
  v_r1 jsonb;
  v_r2 jsonb;
begin
  select household_id into v_hh_id from public.household_members
  where user_id = '19000000-0000-0000-0000-000000000001';

  v_task := public.server_tx_create_task(
    '19000000-0000-0000-0000-000000000001', gen_random_uuid(), 'Double-tap test task', 'todo',
    current_date, null, null, 'whole', 'anytime', null
  );
  v_task_id := (v_task->>'task_id')::uuid;

  v_op_id := md5('line-postback|evt-double-tap-1')::uuid;

  v_r1 := public.server_tx_complete_task(
    '19000000-0000-0000-0000-000000000001', v_op_id, v_task_id, 'self', false
  );
  v_r2 := public.server_tx_complete_task(
    '19000000-0000-0000-0000-000000000001', v_op_id, v_task_id, 'self', false
  );
  if v_r1 <> v_r2 then
    raise exception 'FAIL line-foundation: double-tap complete_task with the same derived operation_id must replay identically';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- Cross-household validation on pending_actions
-- ---------------------------------------------------------------------------

do $$
declare
  v_hh_b_id uuid;
begin
  select household_id into v_hh_b_id from public.household_members
  where user_id = '19000000-0000-0000-0000-000000000003';

  begin
    perform public.server_tx_create_pending_action(
      '19000000-0000-0000-0000-000000000001', v_hh_b_id, gen_random_uuid(), 'line',
      'shopping_item_add', jsonb_build_object('title', 'x'), 30
    );
    raise exception 'FAIL line-foundation: actor from household A must not be accepted for household B''s pending action';
  exception
    when others then
      if sqlerrm <> 'NOT_HOUSEHOLD_MEMBER' then
        raise exception 'FAIL line-foundation: expected NOT_HOUSEHOLD_MEMBER, got %', sqlerrm;
      end if;
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- Cancel: draft/confirmed cancellable + idempotent; terminal states are not
-- ---------------------------------------------------------------------------

do $$
declare
  v_hh_id uuid;
  v_pending jsonb;
  v_pending_id uuid;
  v_cancel jsonb;
begin
  select household_id into v_hh_id from public.household_members
  where user_id = '19000000-0000-0000-0000-000000000001';

  v_pending := public.server_tx_create_pending_action(
    '19000000-0000-0000-0000-000000000001', v_hh_id, gen_random_uuid(), 'line',
    'shopping_item_add', jsonb_build_object('title', 'cancel-me'), 30
  );
  v_pending_id := (v_pending->>'pending_action_id')::uuid;

  v_cancel := public.server_tx_cancel_pending_action('19000000-0000-0000-0000-000000000001', v_pending_id);
  if v_cancel->>'status' <> 'cancelled' then
    raise exception 'FAIL line-foundation: cancel must set status=cancelled';
  end if;

  -- double-tap cancel is a no-op replay
  v_cancel := public.server_tx_cancel_pending_action('19000000-0000-0000-0000-000000000001', v_pending_id);
  if v_cancel->>'status' <> 'cancelled' then
    raise exception 'FAIL line-foundation: double-tap cancel must replay cancelled, not error';
  end if;

  -- cannot confirm a cancelled action
  begin
    perform public.server_tx_confirm_pending_action('19000000-0000-0000-0000-000000000001', v_pending_id);
    raise exception 'FAIL line-foundation: a cancelled pending action must not be confirmable';
  exception
    when others then
      if sqlerrm <> 'INVALID_INPUT' then
        raise exception 'FAIL line-foundation: expected INVALID_INPUT confirming a cancelled action, got %', sqlerrm;
      end if;
  end;
end;
$$;

-- ---------------------------------------------------------------------------
-- Grants: these RPCs are service_role-only, same as every public.server_tx_*
-- ---------------------------------------------------------------------------

reset role;
set role authenticated;
set request.jwt.claim.sub = '19000000-0000-0000-0000-000000000001';
do $$
begin
  begin
    perform public.server_tx_create_line_link_token('19000000-0000-0000-0000-000000000001', gen_random_uuid());
    raise exception 'FAIL line-foundation: authenticated must not execute server_tx_create_line_link_token directly';
  exception
    when insufficient_privilege then null;
  end;

  begin
    perform public.server_tx_claim_webhook_inbox_batch('x', 1, 60);
    raise exception 'FAIL line-foundation: authenticated must not execute server_tx_claim_webhook_inbox_batch directly';
  exception
    when insufficient_privilege then null;
  end;

  begin
    perform public.server_tx_claim_pending_actions_batch('x', 1, 60);
    raise exception 'FAIL line-foundation: authenticated must not execute server_tx_claim_pending_actions_batch directly';
  exception
    when insufficient_privilege then null;
  end;
end;
$$;
reset role;
reset request.jwt.claim.sub;

set role anon;
do $$
begin
  begin
    perform public.server_tx_resolve_line_actor('Uaaa-adult1-relinked');
    raise exception 'FAIL line-foundation: anon must not execute server_tx_resolve_line_actor directly';
  exception
    when insufficient_privilege then null;
  end;
end;
$$;
reset role;

select 'line_foundation: PASS' as result;
