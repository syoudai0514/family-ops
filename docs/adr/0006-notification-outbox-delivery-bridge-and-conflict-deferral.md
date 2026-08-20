# 0006. Notification-outbox LINE delivery bridge, and deferring standalone
calendar conflict/change messages

## Status

Accepted

## Context

WP9's brief (`docs/design/v6/10_WORK_PACKAGES.md` WP9) lists "message copy
audit" and "bundle audit" as deliverables, and the orchestrating task framed
completing `send-notifications`'s actual LINE push loop as the prerequisite
for both — auditing copy/bundling is meaningless without a real delivery
path to audit.

Investigating the existing state before writing any code turned up two
things the design doesn't pin down:

1. **Nothing ever wrote to `private.notification_outbox`.** WP1 built the
   queue table and the quota reserve/commit/release/mark_ambiguous RPCs; WP2
   built `request_received`/`request_accepted`/`request_declined`/
   `handover_created` as `public.user_notifications` (in-app) rows only.
   `supabase/migrations/20260819000025_reassign_task_once.sql`'s own header
   comment already flagged this explicitly: "`routine_checkin_sessions` and
   `notification_outbox` do not yet have WP3-owned write paths." Nothing in
   `06_LINE_INTEGRATION.md`, `09_API_AND_EDGE_FUNCTIONS.md`, or
   `18_MUTATION_CONTRACT_MATRIX.md` says which WP is responsible for routing
   an *event-driven* in-app notification into the LINE outbox — WP8 (not yet
   built) only owns *scheduled* (cron-dispatched) LINE messages
   (`09_API_AND_EDGE_FUNCTIONS.md` §7 "dispatch-routine-automation ...
   insert notification outbox atomically").
2. **"Calendar change/conflict messages"** (WP9's own bullet) has no
   trigger condition or message copy anywhere in the design docs beyond one
   line embedded in WP8's *scheduled* daily-assignment/weekly-digest copy
   (`17_ROUTINE_LINE_AUTOMATION.md` §4 "conflict warningが既に計算済みなら追記"
   — "append the conflict warning if it has already been computed" — inside
   the 07:00 `daily_assignment` message). `07_GOOGLE_CALENDAR.md` §10's own
   conflict-detection section says only "Overlap => warning only. Never
   auto-reassign," which reads as UI/query-time guidance, not an
   event-sourced notification spec, and WP7's own sub-scope list
   (`10_WORK_PACKAGES.md` WP7A-F) never mentions conflict detection or
   notification dispatch at all.

## Decision

1. **Bridge event-driven `user_notifications` into the LINE outbox via a
   trigger**, not by editing WP2's `request_mutations.sql` /
   `handover_notification_mutations.sql` (out of this work package's file
   scope, and those files are already reviewed/shipped). A new migration
   (`20260819000070_notification_outbox_line_bridge.sql`) adds
   `private.fn_enqueue_line_notification()` as an `after insert` trigger on
   `public.user_notifications`. It maps `type` to the relevant
   `notification_preferences` column via a fixed, explicit allowlist
   (currently `request_received`/`request_accepted`/`request_declined` →
   `request_line`, `handover_created` → `handover_line`); any *unmapped*
   type — including every type a future WP might add — safely stays
   in-app-only rather than erroring, so this bridge can never break an
   unrelated WP's insert.
2. **Bundle at that same insertion point**: if the recipient already has a
   still-`queued` (unclaimed) LINE outbox row, the new item is appended into
   that row's `payload.items` array instead of creating a second row,
   directly implementing `15_DDL_CONTRACT.md` §320's "one outbox row
   referenced by multiple ... receipts" for the event-driven case, the same
   way WP8's future scheduled dispatcher is expected to for the cron case.
3. **Defer standalone calendar change/conflict notifications.** Given (2)
   above, building a trigger-based conflict notification now would either
   duplicate or preempt WP8's daily-assignment dispatcher, which is the only
   place the design actually specifies this content belongs. Implementing
   it correctly would also require inventing an undocumented trigger cadence
   (recomputing overlap on every `calendar_occurrence_busy_members`
   write during a Google sync, potentially thousands of rows during an
   initial backfill, is a real performance/correctness risk with no
   guidance in the docs on debouncing it) and undocumented message copy.
   `send-notifications` and the outbox mechanics built in this work package
   are ready to carry such a notification the moment a future WP defines its
   trigger condition and copy — no further delivery-path work is implied.

## Consequences

- `notification_outbox` now has real, testable traffic
  (`tests/sql/21_notification_delivery.sql`), so `send-notifications`'s
  claim/quota/retry-key/bundling logic is exercised by more than synthetic
  test-only inserts.
- A future WP extending `user_notifications.type` (e.g. WP4/WP8) must add a
  case to `private.fn_line_preference_column_for_type()` if that new type
  should ever reach LINE — otherwise it silently stays in-app-only. This is
  the intended safe default, not a bug, but is worth knowing about.
- "Calendar change/conflict messages" (`10_WORK_PACKAGES.md` WP9) remains
  formally undelivered as a *standalone* notification. It is expected to
  land as part of WP8's daily-assignment dispatcher content
  (`17_ROUTINE_LINE_AUTOMATION.md` §4), at which point that dispatcher can
  either call `INSERT ... private.notification_outbox` directly (its own
  documented job) or, if a genuinely separate event-driven "conflict
  detected right now" notification is later wanted, extend this ADR's
  bridge/type-map pattern with the trigger condition and copy a future ADR
  or design update defines.
