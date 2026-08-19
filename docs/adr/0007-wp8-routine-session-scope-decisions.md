# 0007. WP8 routine-session automation: scope decisions and one deferred
wiring gap

## Status

Accepted

## Context

`docs/design/v6/17_ROUTINE_LINE_AUTOMATION.md` is detailed and mostly
unambiguous, but this work package's own collision-avoidance constraints
(explicit file allowlist from the orchestrating task — new files only under
`supabase/migrations/`, four new Edge Function directories, `tests/sql/`,
`docs/adr/`, and `apps/web/src/features/checkin/**`) forbid editing several
existing files the doc's own architecture points at. Four gaps fell out of
implementing against that allowlist:

1. **LINE postback routing.** `06_LINE_INTEGRATION.md` / `09_API_AND_EDGE_
   FUNCTIONS.md` route LINE postbacks through `process-line-inbox`'s
   `handlePostback` dispatch, and that function's own header comment
   (`supabase/functions/process-line-inbox/index.ts`, written by WP6)
   explicitly anticipates this: *"This worker's postback vocabulary
   (confirm_pending/cancel_pending/complete_task) is generic, not
   routine-session-shaped, so it does not collide with WP8 adding its own
   postback actions later."* `process-line-inbox/**` is on this task's
   forbidden-file list, so no branch was added there.
2. **New error codes.** `_shared/errors.ts` is also forbidden to edit (WP7
   hit the identical constraint for a different reason — a live parallel-agent
   collision — and resolved it with a local error-mapping file per
   `docs/adr/0005`; that workaround itself lives outside this task's allowed
   paths, so it was not repeated here).
3. **`server_tx_reassign_task_once` / `server_tx_complete_task` signature
   changes.** Both are pre-existing, already-shipped functions this WP needed
   to extend (session supersede on reassignment; a `source` tag on
   completions). Neither file is on the forbidden list, so both were amended
   in place via `create or replace function` — following the exact house-style
   precedent WP3 already set by amending WP1's
   `private.materialize_recurrence_rule` in place
   (`20260819000023_recurrence_role_resolver.sql`).
4. **Cascading role-strategy reassignment.** Reassigning `pickup` flips which
   adult is "non-pickup" (MVP: exactly two adults), but no migration anywhere
   re-resolves already-materialized `nonpickup_adult`-strategy task_instances'
   `planned_assignee_id` when that happens — `20260819000023`'s own resolver
   only ever resolves at *materialization* time, never on later reassignment.

## Decisions

1. **RPC layer is fully LINE-postback-ready; the actual webhook wiring is
   deferred and documented, not built.** `public.server_tx_routine_session_
   item_action` / `server_tx_complete_routine_session` both take an explicit
   `p_source` ('line' | 'pwa') and are exercised with LINE-postback-shaped
   arguments directly in `tests/sql/22_routine_line_automation.sql` (scenario
   8's `p_source='line'` calls, asserting `task_events.source='line'`). The
   follow-up this unblocks is small and precisely scoped: a new branch in
   `process-line-inbox`'s `handlePostback` (alongside its existing
   `complete_task` branch) recognizing postback actions such as
   `action=routine_item&session_id=...&task_instance_id=...&disposition=...`
   and `action=routine_complete_all&session_id=...`, resolving the actor via
   the same `server_tx_resolve_line_actor` call already used there, then
   calling these two RPCs with `p_source='line'`. **This is the one
   concrete, load-bearing gap in this WP's delivery** — until that follow-up
   lands, a LINE quick-reply tap has nothing to receive it; see the final
   report for the same note.
2. **Existing error codes are reused rather than invented.** A session that
   is not `'open'` (superseded, already submitted, or auto_closed) raises
   `TASK_TERMINAL` for any mutation attempt; a session/item not visible to
   the actor (wrong household, or not the session's own assignee) raises
   `CROSS_HOUSEHOLD_RESOURCE` — the same "not found or not yours, don't
   disclose which" convention `server_tx_reassign_task_once` already uses for
   an unauthorized task id. Both read acceptably (if not perfectly precisely)
   through the existing `describeCode()` Japanese strings. **Recommended
   follow-up** (needs a human or a session with `_shared/errors.ts` in scope):
   add `ROUTINE_SESSION_SUPERSEDED` (409) and `ROUTINE_SESSION_NOT_OPEN` (409)
   as dedicated codes and swap the two `raise exception 'TASK_TERMINAL'`
   sites in `20260819000083_routine_session_action_rpcs.sql` to the more
   precise one.
3. **`server_tx_complete_task` gained a `p_source text default 'pwa'`
   trailing parameter** so every completion this WP produces can tag its
   channel (`17_ROUTINE_LINE_AUTOMATION.md` #9 "LINEとPWAは同じmutation APIを
   使う。sourceだけtask_eventへ記録する") without duplicating WP2's whole/subtasks
   completion and linked-request lifecycle logic. Adding a trailing
   `DEFAULT`-valued parameter is call-compatible for every pre-existing 5-arg
   caller *in application code* (the `complete-task` Edge Function,
   `process-line-inbox`'s own `complete_task` postback branch — neither
   needed a change) — but Postgres does **not** treat this as replacing the
   old signature; it adds a second overload. `tests/sql/10_task_instance_
   mutations.sql`'s pre-existing call passing an untyped `null` literal for
   `p_complete_remaining_subtasks` became ambiguous between the two
   overloads and failed with "function ... is not unique" until
   `20260819000083` added an explicit `drop function if exists
   public.server_tx_complete_task(uuid, uuid, uuid, text, boolean);` before
   the `create or replace`. Full regression: `PGHOST=127.0.0.1 PGPORT=5544
   PGUSER=postgres bash scripts/run_sql_tests.sh` passes end to end,
   including every pre-existing WP1–WP9 test file and the concurrency suite.
4. **`server_tx_reassign_task_once`'s session-supersede amendment is scoped
   to `dropoff`/`pickup` canonical-task reassignment on the *same real-world
   Asia/Tokyo day* only** (not the whole `origin='recurring'` surface that
   function accepts) — a future-dated reassignment has no session to
   supersede yet (sessions are only ever created at same-day dispatch). It
   does supersede/rebuild the `nonpickup_evening` session for **both** adults
   when `pickup` is reassigned (since non-pickup identity flips), but it does
   **not** retroactively touch any individual `nonpickup_adult`-strategy
   chore instance's own `planned_assignee_id` — no migration anywhere
   cascades that re-resolution (see gap 4 above), and inventing one was out
   of scope for a session-identity fix. The rebuilt `nonpickup_evening`
   session therefore reflects whatever those instances' `planned_assignee_id`
   already says, exactly like every other live read in this WP's dispatcher.

5. **LINE quick-reply/postback buttons themselves are not sent** — a
   separate, pre-existing limitation independent of decision 1.
   `send-notifications` (WP9, also forbidden to edit here) only ever posts
   `{ type: "text", text }` LINE messages; it has no quick-reply/template
   message support to attach `17_ROUTINE_LINE_AUTOMATION.md` #8's
   `[全部完了] [項目ごとに入力] [今回は不要] [PWAで開く]` action buttons to. Every
   routine message this WP's dispatcher enqueues is plain text, so its actual
   interactive affordance today is the PWA deep link
   (`{APP_BASE_URL}/checkin/{session_id}`) included as a plain URL in the
   message body — LINE auto-linkifies it, and it is the one action a
   recipient can actually take from the notification itself pending decision
   1's follow-up. This is flagged prominently in the final task report as a
   P1 finding for the same reason as decision 1: it materially affects
   whether the design's core "LINE-native quick reply" loop is realized, even
   though the underlying canonical-state mutation is fully built and tested.

## Consequences

- `dispatch-routine-automation`, `get-routine-session`,
  `complete-routine-session`, and `routine-session-item-action` are complete
  and fully tested (`tests/sql/22_routine_line_automation.sql`, 10
  scenarios, all passing) against every deliverable except the LINE-webhook
  wiring named in decision 1.
- A human (or a future session with `process-line-inbox/**` and
  `_shared/errors.ts` in scope) has two small, precisely-specified follow-ups
  to fully close the loop: the postback branch from decision 1, and the two
  new error codes from decision 2. Neither requires touching anything this
  WP built — both are additive.
