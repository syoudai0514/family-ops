# 0011. PWA pending-action review surface and Today calendar/conflict view (Sol re-review #3)

## Status

Accepted

## Context

A third independent review by the same reviewer ("Sol"), against the fixed
HEAD that closed both prior review-fix cycles (docs/adr/0008–0010), found
two P1s and one P2 outside the LINE routine-flow area those prior cycles
covered:

- **P1-1**: `docs/design/v6/02_UX_AND_SCREENS.md` #3 places "LINEから作った
  pending action" in Today Priority 2. `process-line-inbox` already creates
  `private.pending_actions` drafts and replies "内容はアプリでご確認ください"
  (docs/adr/0009), but no PWA screen ever read/confirmed/cancelled them —
  the reply pointed at a surface that did not exist, a genuine dead end for
  natural-language LINE input.
- **P1-2**: `02_UX_AND_SCREENS.md` #3 places "今/次の予定" (current/next
  schedule, with a calendar-conflict warning) as Today's own Priority 1 —
  the single most important thing the screen is supposed to show. The
  backend already computes this exact conflict concept for the LINE digest
  (`docs/adr/0008`), but the PWA Today screen never read Calendar data at
  all.
- **P2-1**: `MANUAL_SETUP_REQUIRED.md`'s pending-action section, written
  during the P1-1 fix that added LINE-side confirmations, said the
  confirm/cancel step was "PWA-only" — true in the RPC sense but misleading
  without the PWA surface P1-1 here now provides.

## Decisions

1. **Two new read-model RPCs, zero changes to existing mutation RPCs.**
   `server_tx_confirm_pending_action`/`server_tx_cancel_pending_action`
   (`20260819000041`) already did exactly what was needed — the gap was
   purely "nothing lets the PWA call them, and nothing lets the PWA see
   what to call them on." `20260819000102` adds
   `server_tx_list_pending_actions` (actor-scoped: the sender's own
   non-terminal `draft`/`confirmed`/`queued`/`executing` rows only — never
   the partner's, since a draft is private until it becomes a shared
   task/shopping item) and `server_tx_get_today_schedule` (today's timed,
   non-transparent, non-cancelled Calendar occurrences plus assigned/due
   tasks, each already annotated with `has_conflict`).

2. **One conflict predicate, two call sites — no re-derivation.** Sol's
   finding explicitly warned against reimplementing busy attribution in the
   browser. Rather than duplicating `fn_conflict_task_count`'s (`20260819000091`)
   `WHERE EXISTS` clause a second time even in SQL, that clause is extracted
   into a new `private.fn_calendar_conflict_exists(household, assignee,
   due_at, conflict_window_minutes)` helper, and `fn_conflict_task_count`
   itself is `CREATE OR REPLACE`d to call it (same house style as every
   prior in-place amendment — WP3's `materialize_recurrence_rule`, this
   session's `change_recurrence`/`fn_claim_and_enqueue_routine_notification`).
   `server_tx_get_today_schedule` calls the exact same helper per assignment.
   `tests/sql/27`'s scenario 2 asserts the LINE digest's aggregate count and
   the PWA's per-item flags agree on the same fixture, closing the drift
   risk directly rather than just by code inspection.

3. **needs_pwa_review gets no confirm button — by design, not oversight.**
   `process-pending-actions`' execution worker (`supabase/functions/process-pending-actions/index.ts`)
   has cases for exactly `shopping_item_add` and `task_create_once`; any
   other `action_type` — which today only ever means `needs_pwa_review`,
   the parser's own fallback for anything outside its small deterministic
   grammar — falls into `default: throw`, i.e. would dead-letter forever if
   confirmed. `PendingActionCard` therefore never offers "この内容で確定" for
   that type, only "キャンセル" and "編集してPWAフォームへ", which cancels the
   draft and opens the existing `TaskFormModal` (given a new,
   create-mode-only `initialTitle` prop) pre-filled with the sender's own
   raw text as a correction starting point — closing Sol's exact acceptance
   line "Parser fallback leads to a usable correction/form path rather than
   a dead end" without inventing a second free-text execution path outside
   the reviewed deterministic grammar.

4. **Polling, not Realtime, for pending-action refresh — and that's the
   correct answer, not a compromise.** `private.pending_actions` is not in
   PostgREST's exposed schema list (`supabase/config.toml` `schemas =
   ["public", "graphql_public"]`), so Supabase Realtime's
   `postgres_changes` — which `useTodayData`/the new `useTodaySchedule` both
   use for task/calendar tables — has no channel into it at all. A fixed
   20s poll (`usePendingActions.ts`) is the pragmatic, honest substitute the
   acceptance criterion itself allows for ("Realtime **or** refresh
   behavior"); the user's own confirm/cancel already triggers an immediate
   refetch on top of it, so the interval only matters for the LINE-origin
   arrival case.

5. **The Today schedule view performs zero calendar-domain computation.**
   `TodaySchedule.tsx` only merges two already-filtered,
   already-conflict-annotated arrays into one chronologically-sorted
   render list and formats timestamps — no overlap arithmetic, no
   transparency/all-day filtering, no busy-attribution lookup. Everything
   Sol's finding said must not be reimplemented in the browser stays
   entirely server-side.

6. **Four new gap-fill endpoints, same allowlist pattern as WP2/WP5.**
   `list-pending-actions`, `confirm-pending-action`, `cancel-pending-action`,
   `get-today-schedule` are absent from the vendored 52-function matrix (no
   named endpoint exists for either Today priority) — added to
   `scripts/check-edge-auth-matrix.mjs`'s `GAP_FILL_FUNCTIONS`, matching the
   exact precedent `docs/adr/0002`/`docs/adr/0003` already established.

## Consequences

- `tests/sql/27_pending_action_review_and_today_schedule.sql` covers, at
  the SQL/RPC layer: actor-scoping (sender-only visibility), the
  draft→confirmed→succeeded visibility lifecycle (card disappears once a
  worker completes it), expired-draft exclusion, cross-household exclusion
  for both RPCs, all-day/transparent occurrence exclusion, per-item
  conflict flags agreeing with the LINE digest's own aggregate count, and
  graceful degradation (calendar_connected=false, calendar_stale=true for
  reauth/staleness) without breaking task visibility.
- `apps/web/src/features/today/{PendingActionCard,TodaySchedule,Today}.test.tsx`
  cover the frontend: per-`action_type` button sets (including the
  needs_pwa_review no-confirm rule), confirm/cancel prop wiring, the
  conflict-warning render, the disconnected/stale-calendar hints, and the
  two new sections appearing end-to-end in `Today` with `list-pending-actions`/
  `get-today-schedule` mocked at the `apiClient` boundary.
- What this environment genuinely **cannot** verify with a running test: a
  live LINE-created draft actually appearing in a real browser session
  (no live LINE sandbox here, the same documented limitation every other
  provider-wire call in this repo carries) and an actual Google Calendar
  occurrence round-tripping through a real OAuth connection. Both are
  exercised here against realistic fixtures instead (SQL-level calendar rows
  built the same way `tests/sql/24`'s existing Calendar-conflict scenarios
  already do, and frontend fixtures shaped exactly like the RPCs' own
  return values).
- `MANUAL_SETUP_REQUIRED.md`'s pending-action section is updated in the same
  commit as this fix to describe the now-real PWA surface, closing P2-1
  (see that file's own diff for the exact wording change).
