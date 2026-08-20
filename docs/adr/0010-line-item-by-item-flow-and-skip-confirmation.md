# 0010. LINE item-by-item flow and top-level skip confirmation (P1-1/P1-2 re-review)

## Status

Accepted

## Context

A second independent design review by the same reviewer ("Sol"), against
the fixed HEAD that closed ADR 0008/0009's findings, found two further P1s
against `docs/design/v6/17_ROUTINE_LINE_AUTOMATION.md` §8:

- **P1-1**: the `項目ごとに入力` (item-by-item) LINE flow was entirely
  missing from the scheduled message's quick-reply buttons. `routine_item`
  postback handling already existed and was tested
  (`tests/sql/22_routine_line_automation.sql`), but nothing in
  `send-notifications` ever offered a button that reached it — ADR 0009's
  own `buildRoutineQuickReply` comment explicitly named this as PWA-only
  "out of scope," reasoning that per-task quick-reply buttons aren't
  derivable from a bundled `notification_outbox` payload (one item per
  `schedule_kind`, not per `task_instance`).
- **P1-2**: the top-level `今回は不要` button posted
  `action=routine_complete&session_id=...&value=skip_incomplete` directly.
  §8's own text requires a confirmation round-trip before this
  mass-skip mutation ("session全部を一括skipしない。確認を1段挟む"), which ADR
  0009's fix had not implemented.

## Decisions

1. **Item-by-item mode is server-driven, not payload-driven — this
   resolves the constraint ADR 0009 flagged.** Tapping `項目ごとに入力` posts
   `action=routine_item_mode&session_id=<id>` with no item list attached.
   `process-line-inbox` then calls the already-existing
   `server_tx_get_routine_session` live (not the scheduled message's own
   payload) to read the session's current items — ordered by
   `display_order`, exactly as `20260819000081`'s
   `fn_get_or_create_routine_session` already populates it
   (`task_definition.sort_order` then `task_instance.created_at`) — and
   replies with the first unfinished item plus its four required actions
   (完了/相手が対応/今回は不要/次へ). No new RPC, table, or migration was
   needed: `server_tx_get_routine_session`,
   `server_tx_routine_session_item_action`, and
   `server_tx_complete_routine_session` were already sufficient; this was
   purely an Edge-Function routing/UX gap, not a data-layer one.

2. **Deterministic selection and message-shape logic is pulled out into
   pure, dependency-free modules** —
   `supabase/functions/process-line-inbox/routineItemFlow.ts`
   (`pickNextUnfinished`, `buildItemQuickReply`, `buildItemPromptText`,
   `buildStaleSessionText`) and
   `supabase/functions/send-notifications/routineQuickReply.ts`
   (`buildRoutineQuickReply`, now emitting all four normative top-level
   actions) — each with a companion `*.test.ts` file exercised by `deno
   test` in CI. This is the same reasoning `_shared/gemini.test.ts` already
   established for AI-invariant checking: the piece that must behave
   correctly regardless of a live provider is made unit-testable without
   one.

3. **`次へ` never mutates.** `action=routine_item_next&session_id=...
   &task_instance_id=<cursor>` only reads the session and advances the
   cursor; `pickNextUnfinished` wraps back to the first unfinished item
   once the cursor reaches the end (so items paged past come back around
   rather than being silently dropped), and restarts from the first
   unfinished item if the cursor item is no longer unfinished (e.g.
   completed concurrently via PWA — the same SL-17 no-rewind principle
   `server_tx_routine_session_item_action` already applies at the mutation
   layer).

4. **After a mutating item action, the flow continues automatically** —
   the existing `routine_item` postback handler now re-reads the session
   and, if any unfinished item remains, replies with a combined
   confirmation + next-item prompt (one LINE message, one `quickReply`);
   otherwise it announces completion. This directly satisfies §8's "After
   an action, show the next unfinished item until no items remain."

5. **The confirmation step is itself a stateless prompt, not a new mutable
   session state.** The top-level `今回は不要` button now posts
   `action=routine_skip_prompt&session_id=...`. That handler performs
   **zero** database writes — it only reads via `server_tx_get_routine_session`
   to gate on `can_act` — and replies with a confirm/cancel quick reply.
   Only the confirmed `はい、今回は不要` button reaches the pre-existing
   `routine_complete&value=skip_incomplete` branch, unchanged from ADR
   0009. `戻る` (`action=routine_cancel_prompt`) makes no RPC call
   whatsoever. No new confirmation-state table was introduced: because the
   confirm button's own postback data already carries
   `value=skip_incomplete` (an idempotent, session-state-checked mutation
   via the untouched `server_tx_complete_routine_session`), there is
   nothing to "remember" between the prompt and the confirm tap — the
   session id is the only state that matters, and it round-trips through
   the button itself, not a bearer secret.

6. **Every new postback's data carries only opaque resource ids** (session
   id, task instance id) — no bearer credential, matching the existing
   `routine_item`/`routine_complete` contract this reuses unchanged.
   Asserted directly in `routineItemFlow.test.ts`.

7. **Stale/superseded sessions resolve to a safe link, never a mutation,
   in all three new branches** — `routine_item_mode`, `routine_item_next`,
   and `routine_skip_prompt` all gate on `server_tx_get_routine_session`'s
   `can_act` field (`status = 'open' AND assignee_id = actor`) before doing
   anything else, reusing ADR 0007 decision 2's existing
   "resolve to `current_session_id`'s link" pattern. Neither `can_act` nor
   `current_session_id` had a direct SQL-level test anywhere in this repo
   before this fix (`server_tx_get_routine_session` itself was only
   exercised via its `items` count) — closed by
   `tests/sql/26_line_item_by_item_and_skip_confirm.sql` scenario 2.

8. **The PWA link is always folded into the item prompt text itself**, not
   only attached as a `quickReply` button, so §8's "PWA remains available
   as fallback" holds even along the push-fallback path (when a Reply API
   attempt fails and `replyOrEnqueuePush` falls back to
   `server_tx_enqueue_immediate_line_push`, which does not carry
   `quickReply` buttons through). A postback-triggered reply almost always
   has a fresh, valid reply token (the same webhook turn that carried the
   postback), so this fallback is expected to be rare for this flow, but
   the text-embedded link keeps the user unblocked either way without
   requiring a broader schema change to thread quick-reply buttons through
   the push-fallback outbox path — deliberately out of scope here as a
   documented, non-blocking simplification (the same style of scoped
   deferral ADR 0007/0009 already use elsewhere).

9. **`一今回は不要にしますか` future "mandatory/non-skippable task" carve-out is
   not implemented.** §8's per-item skip subsection anticipates "将来導入され
   た場合" (if introduced in the future) a mandatory-task concept that skip
   must reject — no such concept exists anywhere in this schema today
   (every task is skippable). This is intentionally left undone as a
   forward-looking note, not a present gap, consistent with how ADR 0007
   already documents similarly-scoped, explicitly-future v6 language.

## Consequences

- `supabase/functions/process-line-inbox/routineItemFlow.test.ts` (9 cases)
  and `supabase/functions/send-notifications/routineQuickReply.test.ts` (6
  cases) unit-test the deterministic-selection, wraparound,
  cursor-fallback, message-shape, and no-bearer-secret guarantees without
  any live LINE provider or database.
- `tests/sql/26_line_item_by_item_and_skip_confirm.sql` closes the two
  DB-level gaps the new Edge Function code depends on:
  `server_tx_get_routine_session`'s `items[]` ordering (verified against a
  fixture where insertion order is deliberately the reverse of
  `sort_order`) and its `can_act`/`current_session_id` fields for both an
  open session's non-assignee and a superseded session.
- No migration, table, or existing RPC signature changed — every mutation
  this fix reaches was already implemented and tested (ADR 0007/0009); this
  closes a routing/UX gap in the two Edge Functions only.
- What this environment genuinely **cannot** verify with a running test:
  an actual LINE Reply API/postback round trip against a live channel (same
  documented limitation every provider-wire call in this repo carries).
  That the right RPC is called with the right arguments for each of the
  four new postback actions is verified by direct code inspection plus the
  unit/SQL tests above, not a live LINE interaction.
