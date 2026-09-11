# Lane A — Request canonicalization

Status: **review-ready candidate pending final documentation-head CI**. No merge / no production apply.

Scope: CF-01 and CF-12; Request / RequestAttempt canonical transition ownership, assignment-change atomic convergence, stale-action safety, transport parity, and reply-deadline vs work-deadline semantics.

## Authority and CURRENT baseline

Fresh-read authority for this lane:

1. User Requirement / Requirements Baseline.
2. Appendix requirements and accepted final UX.
3. Accepted ADR governing the architecture decision.
4. `docs/design/current/` detailed design.
5. implementation and tests, which must conform to the above.

Historical handoffs, PR descriptions and old CI runs are evidence/history only, not CURRENT truth.

Fresh-read `main` during final implementation review: `6d93ba0d5b6ed1d6dbc3bbf8ec0a973f898d30ff`.

## Implementation checkpoint

Exact code/evidence checkpoint before this documentation-only finalization:

- branch: `impl/lane-a-request-canonicalization`
- commit: `419940fbffe78f147cecc26c82a9b091875a6f59`
- PR: #67
- CI: #864 / run `34324043058`
- CI result: **4/4 jobs SUCCESS**
  - web: lint / typecheck / full Vitest / production build
  - db: complete migration stack + SQL suite
  - edge-functions: Deno lint / type-check / unit tests / auth-matrix lint
  - supabase-integration: real Supabase CLI stack start/reset, all migrations from empty, integration tests, clean stop

The final review must use the actual PR HEAD and checks after this documentation commit rather than treating the implementation checkpoint SHA above as permanently current.

## CF-01 — one canonical RequestAttempt mutation truth

### Canonical transition owner

`private.fn_command_transition_request_attempt_v1` is the lifecycle mutation owner used by both PWA and LINE. Material actions carry the observed snapshot:

- request ID
- attempt ID
- expected Attempt revision
- expected terms revision
- action
- operation ID
- source (`pwa` or `line`)

The command claims/replays the canonical operation receipt, locks Request + exact Attempt, checks scope, expiry, Attempt revision and terms revision, performs the transition, applies accepted business semantics, projects compatibility state, emits notification intent and completes the receipt in one transaction.

Old ID-only assignment-change actions do not fetch a newer revision to make an old click succeed. They fail closed as stale and require the current proposal to be reopened.

### Consultation / explicit agreement

Proposal and confirmation are separate business actions:

- `edit_terms` stores a new terms revision and returns to `consulting`;
- proposing terms does **not** create a confirmation row;
- first explicit `confirm_terms` on that exact revision moves to `awaiting_confirmation`;
- second required participant explicitly confirming the same revision moves the Attempt to `accepted`;
- edits increment `terms_revision`, so prior confirmations cannot establish a newer agreement;
- one-sided confirmation never mutates assignment/task truth.

This is proven in both the Lane A SQL matrix and the mandatory ActorRef one-operator E2E. The latter separately proves that semantic simulated actors remain the persisted confirmer identities rather than leaking the authenticated operator identity.

### Assignment-change agreement snapshot

Creation snapshots `terms.assignment_targets` with every scoped Task:

- task ID
- observed Task revision
- original assignee ActorRef

Acceptance validates and locks the complete target set in deterministic task-ID order before Task mutation. Every target must still be open, have the observed revision, retain the observed original assignee and remain in the same execution/test scope. Only after every validation succeeds are assignments changed to the agreed recipient and provenance appended.

`assignment_change_request_tasks` remains historical compatibility data; new Lane A assignment creation/acceptance does not use it as current scope truth.

### Atomicity and idempotency

Acceptance, assignment changes, Task events, Request compatibility projection, notification intent and canonical operation receipt are one transactional unit. The SQL suite injects a real failure after assignment mutation but before completion and proves the Attempt, assignment and audit all roll back together.

Replaying the same operation ID with the same semantic payload returns the recorded result without duplicate mutation/notification. A changed semantic payload under the same operation ID remains an idempotency conflict.

### Active entry paths

| Surface | CURRENT route | Guarantee |
|---|---|---|
| PWA Requests accept/decline | Edge adapter → `server_tx_transition_request_v2` | exact observed Attempt/revision/terms revision |
| PWA Requests negotiation | Edge adapter → same v2 transition | checking/consult/edit/confirm share the same Attempt truth |
| PWA Today request actions | display-observed Attempt snapshot → Edge v2 transition | missing/stale/terminal snapshot fails closed |
| PWA respond/cancel | snapshot-bearing v2 transition | no ID-only current-state upgrade |
| LINE assignment postback | postback Attempt/revision snapshot → v2 transition | missing/old snapshot fails closed |
| LINE light-request pending action | frozen pending-action snapshot → compatibility adapter → canonical command | adapter consumes stored snapshot, not latest revision |
| Assignment-change creation | public adapter → private canonical create command | Task scope/revisions frozen before proposal |
| Expiry worker | shared Attempt expiry helper | uses the same `reply_due_at` lifecycle truth |
| Legacy ID-only assignment RPC | compatibility only | stale-only; no independent business truth |

## CF-12 — reply deadline and work deadline remain separate

`RequestAttempt.reply_due_at` is response-lifecycle truth. Request/Task `due_at` remains the execution/work deadline and does not silently expire an Attempt.

Canonical automatic reply-deadline proposal when omitted:

- future work deadline: earlier of 24 hours after creation or halfway from creation to work deadline;
- no future work deadline: 24 hours after creation;
- explicit future reply deadline wins, including when later than the work deadline.

The proposed response deadline is persisted once on the Attempt. Replay does not recalculate it. PWA buckets, Today request actions, notifications and LINE pending actions consume persisted `reply_due_at` rather than substituting the work deadline.

Expiry closes nonterminal `pending`, `checking`, `consulting` or `awaiting_confirmation` Attempts whose `reply_due_at` has passed. Underlying Task/current assignment stays unchanged; a late/stale action cannot revive the old Attempt.

## Evidence

### SQL / transaction evidence

`tests/sql/81_lane_a_request_canonicalization.sql` exercises both `pwa` and `line` sources across:

- direct accept
- checking then accept
- consultation proposal with zero implicit confirmations
- first explicit same-revision confirmation without assignment mutation
- second explicit same-revision confirmation establishing agreement
- stale terms revision
- stale Attempt revision
- decline
- expiry / late action
- stale target Task revision
- injected transactional rollback
- idempotent replay
- assignment provenance/link projection
- explicit reply Tuesday / work Friday ordering
- explicit reply Friday / work Tuesday ordering
- omitted reply deadline proposal/persistence
- LINE pending-action immutable snapshot
- stale LINE pending-action rejection
- fresh LINE snapshot acceptance through the canonical transition

`tests/sql/39_dd3a_mandatory_actorref_e2e.sql` proves proposal-vs-confirm separation and two explicit confirmations while keeping one authenticated test operator distinct from persisted Papa/Mama semantic ActorRefs.

`tests/sql/44_dd4_request_canonical_cutover.sql` keeps post-accept change/cancel lifecycle coverage and uses relative reply deadlines so wall-clock time cannot turn it into an accidental expiry test.

### Edge / PWA evidence

- `_shared/requestTransition.test.ts` covers the shared snapshot contract.
- `Today.test.tsx` renders the real Today Request action and asserts request ID + attempt ID + expected revision + expected terms revision are sent.
- Web full-suite CI proves the Request/Today changes compile, test and production-build together.

### Environment evidence

CI #864 on exact code/evidence checkpoint `419940fbffe78f147cecc26c82a9b091875a6f59` passed the complete repository CI, including the real Supabase CLI reset/integration job. This proves the branch migration stack and configured CI boundary; it is not a claim that production has been migrated or exercised.

## Migrations introduced by Lane A

- `20260909033326_lane_a_request_canonicalization.sql`
- `20260909040000_lane_a_restore_legacy_request_adapter_contracts.sql`
- `20260909041000_lane_a_assignment_create_command_boundary.sql`
- `20260909042000_lane_a_line_request_snapshot_deadline_parity.sql`
- `20260909043000_lane_a_explicit_terms_confirmation.sql`

No migration has been applied to production by this lane.

## Self-review notes / bounded follow-up

The canonical correctness criteria for CF-01/CF-12 are satisfied at the code checkpoint above. Two UX/product points are intentionally **not** represented as additional Lane A business semantics:

1. A Requests row that is already in `checking` can still visually retain the expanded “その他の返答” area and show the `確認してみる` control again. Re-click is rejected by the canonical state machine, so no invalid mutation occurs; this is a bounded UI polish follow-up rather than a second mutation truth.
2. Free-text consultation examples such as rescheduling or swapping both dropoff/pickup responsibilities require a structured agreement patch capable of safely representing those additional Task mutations. Lane A does not interpret free text as hidden Task mutation. Assignment transfer continues to apply only the server-issued structured assignment target snapshot. Extending consultation to structured swap/reschedule semantics requires its own explicit product/domain contract rather than guessing from text.

Neither point creates an alternate lifecycle owner, bypasses revision checking, conflates reply/work deadlines, or permits stale assignment mutation.

## Final review / release boundaries

Still intentionally not performed by this lane:

- merge to `main`
- production migration/application
- production LINE mutation
- production Google mutation
- independent reviewer approval of PR #67

Before marking PR #67 ready for independent review, this documentation HEAD itself must have CI GREEN and CURRENT PR/main state must be fresh-read once more. Merge and production release remain separate decisions after review.
