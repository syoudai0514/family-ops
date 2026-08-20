-- P1-3/P1-4 fix (docs/adr/0009): SQL/RPC-level assertions for
-- 20260819000100_line_reply_and_routine_quick_reply.sql.
--
-- This file only covers what is genuinely checkable at the SQL/RPC layer
-- (matching this repo's existing tests/sql convention). The Edge-Function
-- half (send-notifications building quickReply.items/PWA-link text from
-- item.session_id; process-line-inbox's reply-first replyOrEnqueuePush call
-- sequencing) is exercised by `deno check`/`deno lint` only — no live LINE
-- provider is reachable in this environment, the same documented limitation
-- every other real provider wire call in this codebase carries (see the
-- final task report for the explicit breakdown of what ran vs. what is a
-- design-level guarantee).
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('25000000-0000-0000-0000-000000000001'), -- HH1 adult A (dropoff, session-context scenario)
  ('25000000-0000-0000-0000-000000000002'), -- HH1 adult B (daily_assignment-only, no session)
  ('25000000-0000-0000-0000-000000000003'); -- HH2 adult A (push-fallback RPC scenario)

set role service_role;

-- ===========================================================================
-- Scenario 1: dispatching a bundled 07:00 (daily_assignment + dropoff_
-- checklist) message attaches session_id/session_type to the checklist item
-- only, matching the session server_tx_dispatch_routine_automation itself
-- get-or-created; the daily_assignment-only item (for the non-dropoff
-- adult) and the daily_assignment item within A's own bundle both carry no
-- session_id. process-line-inbox's routine_complete postback contract
-- (session_id + value) is exercised end to end against the SAME session id
-- this dispatch produced, confirming the two sides agree on one canonical
-- session identity.
-- ===========================================================================
do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_a uuid := '25000000-0000-0000-0000-000000000001';
  v_b uuid := '25000000-0000-0000-0000-000000000002';
  v_dropoff_def uuid;
  v_dropoff_ti uuid;
  v_now timestamptz := ('2026-08-25 07:00:00'::timestamp at time zone 'Asia/Tokyo');
  v_session_id uuid;
  v_outbox_a record;
  v_outbox_b record;
  v_daily_item jsonb;
  v_checklist_item jsonb;
  v_result jsonb;
begin
  v_hh := public.server_tx_create_household(v_a, gen_random_uuid(), 'WP-P1-3 HH', 'A');
  v_hh_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role) values (v_hh_id, v_b, 'adult');

  select id into v_dropoff_def from public.task_definitions where household_id = v_hh_id and code = 'dropoff';
  insert into public.task_instances
    (id, household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
     planned_assignee_id, completion_mode, status, source, created_by)
  values (gen_random_uuid(), v_hh_id, v_dropoff_def, 'recurring', '送り', 'dropoff', 'morning', '2026-08-25',
    v_a, 'whole', 'todo', 'recurring', v_a)
  returning id into v_dropoff_ti;

  perform public.server_tx_dispatch_routine_automation(v_now, 2000);

  select id into v_session_id from public.routine_checkin_sessions
  where household_id = v_hh_id and session_type = 'dropoff' and scheduled_date = '2026-08-25' and assignee_id = v_a;
  if v_session_id is null then
    raise exception 'FAIL session-context: dropoff session was not created';
  end if;

  select * into v_outbox_a from private.notification_outbox
  where household_id = v_hh_id and recipient_user_id = v_a and channel = 'line' and status = 'queued';
  if not found or jsonb_array_length(v_outbox_a.payload -> 'items') <> 2 then
    raise exception 'FAIL session-context: expected A''s bundled outbox row with 2 items';
  end if;

  -- Identify the two bundled items by title, NOT by array position — the
  -- dispatch loop over schedule_kinds has no explicit ORDER BY, so which of
  -- daily_assignment/dropoff_checklist gets appended to the shared bundled
  -- outbox row first is not guaranteed and was observed to differ between
  -- a long-lived local Postgres instance and a freshly-reset one (CI).
  select item into v_daily_item
  from jsonb_array_elements(v_outbox_a.payload -> 'items') as item
  where item ->> 'title' = '☀️ 今日の担当';
  select item into v_checklist_item
  from jsonb_array_elements(v_outbox_a.payload -> 'items') as item
  where item ->> 'title' = '🎒 朝のチェック';

  if v_daily_item is null or v_checklist_item is null then
    raise exception 'FAIL session-context: expected both a daily_assignment and a dropoff_checklist item, got %', v_outbox_a.payload -> 'items';
  end if;
  if v_daily_item ? 'session_id' then
    raise exception 'FAIL session-context: daily_assignment item must NOT carry session_id (no session backs it)';
  end if;
  if (v_checklist_item ->> 'session_id')::uuid <> v_session_id then
    raise exception 'FAIL session-context: dropoff_checklist item session_id must equal the dispatched dropoff session id, got %', v_checklist_item ->> 'session_id';
  end if;
  if v_checklist_item ->> 'session_type' <> 'dropoff' then
    raise exception 'FAIL session-context: dropoff_checklist item session_type must be ''dropoff'', got %', v_checklist_item ->> 'session_type';
  end if;

  -- B: daily_assignment-only bundle, no session anywhere.
  select * into v_outbox_b from private.notification_outbox
  where household_id = v_hh_id and recipient_user_id = v_b and channel = 'line' and status = 'queued';
  if not found or exists (
    select 1 from jsonb_array_elements(v_outbox_b.payload -> 'items') as item where item ? 'session_id'
  ) then
    raise exception 'FAIL session-context: B''s daily_assignment-only item must not carry session_id';
  end if;

  -- The session_id send-notifications will read from the payload is the
  -- SAME id process-line-inbox's existing routine_complete postback
  -- contract already accepts (already tested at the RPC level in
  -- tests/sql/22 scenario 9) — confirm end to end here rather than
  -- duplicating that coverage: the LINE quick-reply button's
  -- action=routine_complete&session_id=<this id>&value=complete_all would
  -- resolve to exactly this session.
  v_result := public.server_tx_complete_routine_session(v_a, gen_random_uuid(), v_session_id, 'complete_all', 'line');
  if (v_result->>'ok')::boolean is not true then
    raise exception 'FAIL session-context: complete_all against the dispatched session_id must succeed, got %', v_result;
  end if;
  if (select status from public.task_instances where id = v_dropoff_ti) <> 'completed' then
    raise exception 'FAIL session-context: dropoff task instance must be completed via the quick-reply-equivalent session_id';
  end if;
end;
$$;

-- ===========================================================================
-- Scenario 2: server_tx_enqueue_immediate_line_push (P1-4 push-fallback
-- path) — correct row shape, redelivery-safe (same dedup key -> no second
-- row), cross-household rejected, invalid input rejected, and never touches
-- LINE quota tables (the reply-succeeded case cannot be end-to-end tested
-- here without a live LINE sandbox, but this RPC's own isolation from
-- private.line_quota_reservations is directly assertable).
-- ===========================================================================
do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_a uuid := '25000000-0000-0000-0000-000000000003';
  v_other_hh uuid;
  v_result jsonb;
  v_outbox_id uuid;
  v_row record;
  v_raised boolean;
  v_quota_count_before int;
  v_quota_count_after int;
begin
  v_hh := public.server_tx_create_household(v_a, gen_random_uuid(), 'WP-P1-4 HH', 'A');
  v_hh_id := (v_hh->>'household_id')::uuid;

  select count(*) into v_quota_count_before from private.line_quota_reservations;

  v_result := public.server_tx_enqueue_immediate_line_push(v_hh_id, v_a, '✓ 完了にしました', 'line-reply-fallback:evt-1');
  if (v_result->>'ok')::boolean is not true or v_result->>'notification_outbox_id' is null then
    raise exception 'FAIL push-fallback: expected ok=true with a notification_outbox_id, got %', v_result;
  end if;
  v_outbox_id := (v_result->>'notification_outbox_id')::uuid;

  select * into v_row from private.notification_outbox where id = v_outbox_id;
  if not found or v_row.channel <> 'line' or v_row.type <> 'line_reply_fallback'
     or v_row.status <> 'queued' or v_row.priority <> 'normal'
     or v_row.recipient_user_id <> v_a or v_row.household_id <> v_hh_id
     or (v_row.payload -> 'items' -> 0 ->> 'title') <> '✓ 完了にしました' then
    raise exception 'FAIL push-fallback: outbox row shape mismatch: %', to_jsonb(v_row);
  end if;

  -- Redelivery: identical dedup key must not create a second row.
  v_result := public.server_tx_enqueue_immediate_line_push(v_hh_id, v_a, '✓ 完了にしました', 'line-reply-fallback:evt-1');
  if (v_result->>'notification_outbox_id')::uuid <> v_outbox_id then
    raise exception 'FAIL push-fallback: redelivery with the same dedup key must resolve to the same outbox row';
  end if;
  if (select count(*) from private.notification_outbox where recipient_user_id = v_a and channel = 'line' and dedup_key = 'line-reply-fallback:evt-1') <> 1 then
    raise exception 'FAIL push-fallback: redelivery must not create a second outbox row';
  end if;

  -- A different dedup key (a different webhook event) is a genuinely new row.
  v_result := public.server_tx_enqueue_immediate_line_push(v_hh_id, v_a, '✓ キャンセルしました', 'line-reply-fallback:evt-2');
  if (v_result->>'notification_outbox_id')::uuid = v_outbox_id then
    raise exception 'FAIL push-fallback: a different dedup key must produce a distinct outbox row';
  end if;

  -- This RPC alone must never reserve/consume LINE quota — only
  -- send-notifications' own claim/send loop does that, and only when it
  -- actually drains this row (P1-4 "do not increment/reserve counted push
  -- quota for successful reply sends" — the corollary is this RPC, by
  -- itself, touches zero quota state).
  select count(*) into v_quota_count_after from private.line_quota_reservations;
  if v_quota_count_after <> v_quota_count_before then
    raise exception 'FAIL push-fallback: server_tx_enqueue_immediate_line_push must never create a line_quota_reservations row by itself';
  end if;

  -- Cross-household recipient rejected.
  select household_id into v_other_hh from public.household_members where user_id = '25000000-0000-0000-0000-000000000001';
  v_raised := false;
  begin
    perform public.server_tx_enqueue_immediate_line_push(v_other_hh, v_a, 'x', 'line-reply-fallback:evt-3');
  exception when others then
    v_raised := true;
    if sqlerrm <> 'CROSS_HOUSEHOLD_RESOURCE' then
      raise exception 'FAIL push-fallback: expected CROSS_HOUSEHOLD_RESOURCE for a mismatched household/recipient, got %', sqlerrm;
    end if;
  end;
  if not v_raised then
    raise exception 'FAIL push-fallback: mismatched household/recipient must be rejected';
  end if;

  -- Invalid input rejected.
  v_raised := false;
  begin
    perform public.server_tx_enqueue_immediate_line_push(v_hh_id, v_a, '', 'line-reply-fallback:evt-4');
  exception when others then
    v_raised := true;
    if sqlerrm <> 'INVALID_INPUT' then
      raise exception 'FAIL push-fallback: expected INVALID_INPUT for empty text, got %', sqlerrm;
    end if;
  end;
  if not v_raised then
    raise exception 'FAIL push-fallback: empty text must be rejected';
  end if;
end;
$$;

reset role;

select 'line_reply_and_quick_actions: PASS' as result;
