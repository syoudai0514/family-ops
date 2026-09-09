# Lane A — Request canonicalization

Status: **review-ready candidate pending final documentation-head CI**. No merge / no production apply.

Scope: CF-01 and CF-12; Q2/Q4/Q30/Q36/Q43/Q45/Q47/Q78/Q83 plus Requirements Baseline §7 lifecycle, agreement-truth, reply-deadline and stale-action guarantees.

## Authority and CURRENT baseline

Fresh-read authority for this lane:

1. Accepted ADR governing the exact architecture decision.
2. `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md` for requirements / UX.
3. `docs/design/current/` for accepted detailed design.
4. `docs/design/v6/` only for non-conflicting legacy mechanics.
5. implementation and tests, which must conform to the above.

No repository-root `AGENTS.md` exists on the current branch. Historical handoffs, review requests, PR bodies, old CI and old implementation matrices are evidence/history only, not CURRENT truth.

Fresh-read `main` at final implementation review: `6d93ba0d5b6ed1d6dbc3bbf8ec0a973f898d30ff`.

## Implementation checkpoint

Exact implementation checkpoint before this documentation-only finalization:

- branch: `impl/lane-a-request-canonicalization`
- commit: `7a7e3eaa082015e09c442e9fae0fdd1c46b8c9d9`
- PR: #67
- CI: #788 / run `34314624376`
- CI result: **4/4 jobs SUCCESS**
  - web: lint / typecheck / full Vitest run / production build
  - db: all migrations + SQL suite
  - edge-functions: Deno lint / type-check / unit tests / auth-matrix lint
  - supabase-integration: real Supabase CLI stack reset + integration suite

The final review must still use the actual PR head and checks after this documentation commit rather than treating the implementation checkpoint SHA as permanently current.

## CF-01 — one canonical RequestAttempt mutation truth

### Canonical command

`private.fn_command_transition_request_attempt_v1` is the mutation owner for the active RequestAttempt lifecycle used by both PWA and LINE. It requires an observed snapshot:

- request ID
- attempt ID
- expected attempt revision
- expected terms revision
- action
- operation ID
- source (`pwa` or `line`)

The command authenticates the actor/context through its public adapter, claims/replays the idempotency receipt, locks Request + Attempt, checks expiry and both revisions, executes the state transition, applies accepted semantics, writes provenance/notification intent, completes the receipt, and commits as one transaction.

Old ID-only assignment-change actions are never upgraded to whatever happens to be CURRENT. They fail closed as stale and require the person to reopen the current proposal.

### Assignment-change agreement snapshot

Creation snapshots `terms.assignment_targets` with every scoped Task:

- task ID
- observed Task revision
- original assignee ActorRef

Acceptance validates and locks the complete target set in deterministic task-ID order before any Task mutation. Every target must still be open, have the observed revision, retain the observed original assignee and be in the same execution/test scope. Only after all validations pass are assignments changed to the agreed recipient and provenance appended.

`assignment_change_request_tasks` is historical compatibility data only. New Lane A request creation and acceptance do not use it as CURRENT scope truth.

### Atomicity and idempotency

Acceptance, assignment changes, Task events, Request projection, notification intent and mutation receipt are one transactional unit. The SQL suite injects a real failure after assignment mutation but before transaction completion and proves that the Attempt, Task assignment and audit event all roll back together.

Replaying the same operation ID with the same semantic payload returns the recorded result without duplicating mutation or notification. Reusing an operation ID with a different semantic payload remains an idempotency conflict.

### Active entry paths

| Surface | CURRENT route | Guarantee |
|---|---|---|
| PWA Requests `やる/難しい` | Edge adapter → `server_tx_transition_request_v2` | observed attempt/revision/terms revision required |
| PWA Requests negotiation | Edge adapter → same v2 transition | checking/consult/edit/confirm use the same Attempt truth |
| PWA Today quick actions | display-observed RequestAttempt → Edge v2 transition | fail closed while snapshot is missing/stale/terminal |
| PWA respond/cancel Edge | snapshot-bearing v2 transition | no ID-only CURRENT-state lookup |
| LINE assignment postback | postback snapshot → `server_tx_transition_request_v2` | old/missing snapshot fails closed |
| LINE light-request pending action | persisted pending-action snapshot → compatibility adapter → canonical command | stored snapshot is used; no CURRENT revision substitution |
| Assignment-change creation | public adapter → private canonical create command | Task scope/revisions are frozen before proposal is issued |
| Expiry worker | shared RequestAttempt expiry helper | same `reply_due_at` lifecycle rule as interactive transition |
| Legacy ID-only assignment RPCs | compatibility only | stale-only; no independent business semantics |
| Notification renderer | canonical notification intent + immutable Attempt snapshot | LINE buttons carry the same observed snapshot |

## CF-12 — reply deadline and work deadline remain separate

`RequestAttempt.reply_due_at` is the response lifecycle truth. `Request.due_at` / Task due data remains execution/work timing; it does not silently expire an Attempt.

Canonical automatic reply-deadline proposal when the user omits one:

- future work deadline: earlier of 24 hours after creation or halfway from creation to work deadline;
- no future work deadline: 24 hours after creation;
- an explicit future reply deadline takes precedence, including when it is later than the work deadline.

The proposed value is persisted once on the Attempt. Replay does not recalculate it. PWA request buckets, Today actions, notifications and LINE pending actions consume the persisted Attempt deadline instead of inventing caller-specific work-deadline fallbacks.

Expiry closes `pending`, `checking`, `consulting` or `awaiting_confirmation` Attempts whose `reply_due_at` has passed. It preserves the underlying Task/current assignment. A late response receives expired/stale/reproposal behavior and cannot revive the old Attempt.

## Evidence

### SQL / transaction evidence

`tests/sql/81_lane_a_request_canonicalization.sql` exercises both `pwa` and `line` sources across:

- direct accept
- checking then accept
- consulting and same-terms-revision confirmation
- decline
- expiry / late response
- stale Attempt revision
- stale terms revision
- stale target Task revision
- injected transactional failure
- idempotent replay
- assignment provenance/link projection
- explicit `reply < work` ordering
- explicit `reply > work` ordering
- omitted reply deadline proposal/persistence
- LINE pending-action immutable snapshot
- stale LINE pending action rejection
- fresh LINE snapshot acceptance through the canonical transition

`tests/sql/44_dd4_request_canonical_cutover.sql` keeps post-accept change/cancel lifecycle coverage and now uses relative reply deadlines so wall-clock time cannot turn it into an accidental expiry test.

### Edge / PWA evidence

- `_shared/requestTransition.test.ts` covers the shared snapshot contract.
- `Today.test.tsx` renders the real Today Request action and asserts that clicking `やる` sends request ID + attempt ID + expected revision + expected terms revision.
- The full Web test suite also exercises the two evening Today variants that previously exposed a render-loop weakness. `7a7e3eaa...` stabilized Attempt observation by semantic request-ID set instead of caller array identity; CI #788 proves the full suite and production build complete without the prior Vitest OOM.

### Environment evidence

CI #788 on exact implementation checkpoint `7a7e3eaa082015e09c442e9fae0fdd1c46b8c9d9` passed not only unit/SQL checks but the repository's real Supabase CLI integration job. This proves the migration stack and configured Supabase boundary used by CI; it is not a claim that production has been migrated or exercised.

## Final review / release boundaries

Still intentionally not performed by this lane:

- merge to `main`
- production migration/application
- production LINE mutation
- production Google mutation
- independent reviewer approval of PR #67

Before marking the PR ready for review, the documentation-only final HEAD must have CI GREEN and CURRENT PR/main/review state must be fresh-read again. Merge and production release remain separate decisions after review.
