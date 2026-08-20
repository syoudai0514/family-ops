# 0009. LINE routine quick-reply buttons and reply-first delivery (P1-3/P1-4)

## Status

Accepted

## Context

An independent design review ("Sol") flagged two P1 findings against
`docs/design/v6/06_LINE_INTEGRATION.md` and
`docs/design/v6/17_ROUTINE_LINE_AUTOMATION.md`, both already named as the
one concrete gap in `docs/adr/0007` (decisions 1 and 5):

- **P1-3**: routine/check-in LINE messages carry no actionable buttons —
  `send-notifications` only ever sent `{ type: "text", text }`, so a LINE
  quick-reply tap had nothing to receive it (the receiving side —
  `process-line-inbox`'s `handlePostback` for `routine_item`/
  `routine_complete` — was already fully built and tested against
  LINE-postback-shaped RPC calls in `tests/sql/22_routine_line_automation.sql`,
  per ADR 0007 decision 1).
- **P1-4**: `06_LINE_INTEGRATION.md` #10A "When a current webhook reply
  token can satisfy the interaction, use Reply API first. Reply messages
  do not consume counted monthly push allowance" was unimplemented —
  every confirmation would have gone through the counted push path.

This fix's own file-boundary constraints (a parallel agent owns
`20260819000082_dispatch_routine_automation_rpc.sql` for a different P1
fix) again forbid editing the exact call sites the design doc's own
architecture points at, echoing ADR 0007's framing.

## Decisions

1. **Session context is derived, not threaded through the forbidden file.**
   `private.fn_claim_and_enqueue_routine_notification`
   (`20260819000081_routine_session_helpers_and_reassignment.sql`) is the
   single choke point every routine-message insert into
   `private.notification_outbox` passes through, regardless of which branch
   of `20260819000082` called it. `20260819000100_line_reply_and_routine_
   quick_reply.sql` `CREATE OR REPLACE`s it (the same "amend an existing
   function via a later migration" house style ADR 0007 itself cites) to
   look up the current `'open'` `routine_checkin_sessions` row for
   `(household_id, session_type-derived-from-schedule_kind, scheduled_date,
   recipient_user_id)` and attach `session_id`/`session_type` onto the
   bundled item — without needing `20260819000082`'s call sites to change
   at all. This works because every session-bearing schedule_kind already
   get-or-creates (checklist branches) or `FOR UPDATE`-selects (check-in
   branches) that exact session row in the *same transaction*, moments
   before calling this function.

2. **Session-level quick-reply buttons only — not per-task item-level.**
   `17_ROUTINE_LINE_AUTOMATION.md` #8's item-level actions (`完了`/`相手が
   対応`/`今回は不要`/`次へ`) presuppose a stateful "bot presents items one
   by one" conversational flow. The payload shape available here is one
   `{title, body}` item *per schedule_kind*, where `body` is often itself a
   multi-line checklist (e.g. `dropoff_checklist`'s `🎒 朝のチェック` item
   lists several task titles in one string) — there is no per-`task_
   instance_id` granularity to hang a button on without a broader payload
   schema change to `20260819000082`, which is out of scope (owned by the
   parallel fix). `全部完了` / `今回は不要` (session-level, via the existing
   `action=routine_complete&session_id=...&value=complete_all|
   skip_incomplete` postback contract `process-line-inbox` already parses)
   are attached whenever an outbox row's items reference **exactly one**
   distinct `session_id`. `項目ごとに入力` and `PWAで開く` are satisfied by
   the deep link now folded into the message text (decision 3) — LINE
   auto-linkifies it, and item-by-item editing remains a PWA-only
   interaction, consistent with the task's own scoping note that this does
   not need a dedicated postback action.
   - Zero or more-than-one distinct session in a bundle (only possible if a
     household manually configures two different session-bearing
     `schedule_kind`s to the identical local minute — not a default
     configuration) → no postback buttons; the deep link(s) already in the
     text remain the fallback action.

3. **The PWA deep link itself was also missing from routine message
   bodies** — a second, adjacent gap: nothing in `20260819000082` ever
   included `{APP_BASE_URL}/checkin/{session_id}` in `v_item.body`, contrary
   to `06_LINE_INTEGRATION.md` #8 "Every checklist/check-in message includes
   deep link" and the `17_ROUTINE_LINE_AUTOMATION.md` #4/#5 message
   templates. Rather than another migration-file workaround, this is fixed
   in `send-notifications`' own message builder (`buildBundledText`,
   entirely within this fix's allowed files): once per distinct
   `session_id` referenced by the bundle, `{APP_BASE_URL}/checkin/
   {session_id}` is appended to that item's text block. No bearer
   credential is ever included (matches the existing PWA-link contract).

4. **Reply-first delivery is a new shared helper, not inlined into either
   worker.** `supabase/functions/_shared/lineMessaging.ts` (new file)
   exports `replyOrEnqueuePush()`: attempt LINE's Reply API when
   `item.payload.replyToken` (from the raw webhook event
   `private.webhook_inbox` already stores verbatim — no schema change) is
   present, treating any non-2xx/network failure as "unavailable" (per
   #10A, LINE returns 400 for expired/used/invalid tokens and no precise
   TTL is documented, so this never tries to predict expiry) and falling
   back immediately. The reply path never calls
   `server_tx_reserve_line_quota` or any quota RPC. `process-line-inbox`
   calls this from `handlePostback` (all five existing postback actions)
   and `handleText` after each successful RPC, with short, deliberately
   minimal confirmation copy (e.g. "✓ 完了にしました").
   - A `TASK_TERMINAL` error from `routine_item`/`routine_complete` (a
     stale tap on a since-superseded/submitted session) gets a specific
     reply carrying the same session's `checkin` deep link, satisfying
     `06_LINE_INTEGRATION.md` #13's "old scheduled session superseded ->
     return SESSION_SUPERSEDED and latest PWA link" at the messaging layer
     (the RPC layer's own use of `TASK_TERMINAL` rather than a dedicated
     `SESSION_SUPERSEDED` code is ADR 0007 decision 2's pre-existing,
     unchanged simplification).

5. **The push-fallback path is a new RPC, not a direct push call from
   `process-line-inbox`.** `server_tx_enqueue_immediate_line_push`
   (`20260819000100`) inserts one normal, quota-counted
   `private.notification_outbox` row (`type = 'line_reply_fallback'`,
   priority `normal`), so `send-notifications`' existing claim/quota-
   reserve/retry-key/429-handling machinery is reused verbatim rather than
   duplicated. `process-line-inbox` never touches
   `private.line_quota_reservations` or the LINE push endpoint directly.
   The caller-supplied `p_dedup_key` (derived from the triggering webhook's
   `provider_event_id`) collapses a redelivered event's fallback push to
   the same outbox row via the table's existing
   `unique(recipient_user_id, channel, dedup_key)` constraint.

## Consequences

- `tests/sql/24_line_reply_and_quick_actions.sql` asserts, at the SQL/RPC
  level: a dispatched `dropoff_checklist` outbox row's bundled item carries
  `session_id`/`session_type`; `server_tx_enqueue_immediate_line_push`
  creates a correctly-shaped, quota-eligible outbox row and is redelivery-
  safe (same dedup key → no second row); the new RPC is cross-household
  safe; and the existing `22_routine_line_automation.sql` /
  `19_line_foundation.sql` assertions are unaffected by the
  `fn_claim_and_enqueue_routine_notification` change (full suite passes,
  see final task report).
- What this environment genuinely **cannot** verify with a running test:
  an actual LINE Reply API call succeeding/failing (no live LINE sandbox
  here, same documented limitation ADR 0007/WP6/WP9 already carry for every
  other real provider wire call), and therefore that "reply succeeds → no
  quota RPC invoked" end-to-end. That specific guarantee is structural
  instead: `replyOrEnqueuePush()` only calls
  `server_tx_enqueue_immediate_line_push` inside the fallback branch (after
  a non-2xx/thrown reply attempt or when no token/channel is available) —
  reachable by inspection, not by a live 2xx reply in this harness.
- A future WP with `_shared/errors.ts` and
  `20260819000083_routine_session_action_rpcs.sql` in scope could still
  close ADR 0007 decision 2's `TASK_TERMINAL` → `SESSION_SUPERSEDED`/
  `ROUTINE_SESSION_NOT_OPEN` follow-up; this fix works correctly either way
  since it matches on the RPC's current error text.
