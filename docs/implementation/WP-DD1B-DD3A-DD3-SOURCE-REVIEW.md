# Family Ops — WP-DD1 / DD2 remainder / DD3A / DD3 Source Review Handoff

## Status

**SOURCE-REVIEW CANDIDATE / DRAFT PR / NO PRODUCTION APPLY / NO MERGE**

PR #44 is retargeted directly to CURRENT `main`; the earlier stacked-on-PR-#43 wording is obsolete.

Canonical contracts:

- `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`
- `docs/design/current/`
- ADR 0013 Accepted

This unit remains pre-P1. No production canonical reader cutover, real LINE delivery, Google Family Event writer activation, production migration apply, or merge is authorized.

## Consolidated review scope

One independent source-review unit covering the maximum safe pre-cutover implementation for:

- remaining WP-DD1 additive/evolution domain foundation;
- remaining WP-DD2 deterministic compatibility/reconciliation;
- WP-DD3A test identity + side-effect sandbox;
- WP-DD3 canonical transaction/concurrency command foundation.

## Implemented

### WP-DD1 / WP-DD2 remainder

- ActorRef-capable Request/Task-event/handover compatibility;
- Request Attempt compatibility projection preserving CURRENT status/timestamp CHECK semantics;
- Task actual participants and reconciliation evidence;
- deterministic legacy ActorRef/assignment/participant/Request Attempt/subtask backfill;
- DailyBrief schedule kinds + one-day override foundation;
- Family Event / field-authority / external-link schema foundation without writer activation;
- change-candidate foundation;
- child / school-context / source-document foundation;
- shopping participant/revision/test prerequisites;
- CURRENT 50-table assertion (public 27/private 23);
- Request/Task/assignment-scope anomaly reconciliation;
- Google Task mirror / target-deletion / orphan provider-lifecycle inventory;
- semantic ActorRef label helper including `🧪 ママ` / `🧪 パパ`.

### WP-DD3A sandbox

- server-derived execution context validation;
- authenticated operator provenance separated from semantic ActorRef;
- no fake auth/member for simulated spouse;
- dedicated `private.test_delivery_outbox`, physically separate from production notification outbox;
- canonical operation receipt identity = semantic actor + operation + test scope;
- pending-action / mutation-receipt ActorRef/test validation;
- production reads exclude test business rows;
- production notification/Google/real-consent side-effect guards;
- immutable Task test context;
- Google projection defense in depth:
  - INSERT/UPDATE/DELETE trigger checks `NEW/OLD.test_context_id` directly;
  - transport existence scans exclude test Tasks;
  - dropoff/pickup provider materialization excludes test Tasks;
  - special lookup excludes test Tasks;
  - calendar reconciliation enumerates production Tasks only;
  - worker re-read is production-only.

### WP-DD3 commands

- receipt claim/replay/hash-conflict semantics;
- aggregate row locking + expected revision checks;
- Task waiting/resume;
- assignment change foundation;
- anyone claim/release/takeover;
- Task completion with participant/audit/intent;
- performer correction preserving history;
- deterministic skipped outcome;
- group reconciliation;
- Request create/checking/consultation/terms confirmation/accept;
- Request legacy lifecycle projection;
- info acknowledgement/superseding correction;
- candidate reject/stale/fail-closed accept boundary.

## Intentional fail-closed boundaries

The following are intentionally not invented here:

- `CANONICAL_ASSIGNMENT_CHANGE_ACCEPT_NOT_ENABLED` — multi-Task assignment-change accept awaits a fully revision-safe atomic scope;
- `CANDIDATE_ACCEPT_TARGET_ADAPTER_NOT_ENABLED` — accept awaits target-specific lock/revision/authority adapters;
- Family Event Google writer/ownership transfer is inactive;
- Task-mirror transfer, stale target-deletion supersession and orphan adoption remain later work;
- no P1 semantic activation;
- no production LINE/PWA canonical cutover.

## Required SQL evidence

- `37_canonical_identity_operational_foundation.sql`
  - accepted/completed Request fixtures use valid linked Tasks;
  - reconciliation remains strict and must be zero for valid fixture state.
- `38_test_execution_sandbox_foundation.sql`
  - operator/domain actor separation, receipt identity, archived-context rejection.
- `39_dd3a_mandatory_actorref_e2e.sql`
  - one real papa/operator drives papa + simulated-mama Request/consultation/Task E2E without fake membership.
- `40_canonical_command_concurrency_reconciliation.sql`
  - replay/conflict, stale revision, claim/takeover, waiting/resume, completion/correction, reconciliation, info/candidate boundaries.
- `41_google_projection_test_scope_isolation.sql`
  - test Task INSERT → production Google mirror unchanged;
  - UPDATE → unchanged;
  - DELETE → unchanged without deleted-row lookup;
  - reconcile excludes test Tasks;
  - test real-user transport Task cannot alter production P/M payload;
  - stale/hostile special mirror referencing a test Task cannot produce provider upsert.

## Independent review focus

1. simulated ActorRef vs real operator/auth identity separation;
2. test execution → production LINE/Google/real-consent isolation;
3. Google isolation at trigger entry and every production Task scan/materialization path;
4. receipt replay/hash conflict and lock/revision ordering;
5. Request Attempt → legacy Request lifecycle tuple projection;
6. Task assignment/claim/waiting/completion/performer correction atomicity;
7. group reconciliation eligibility/stale behavior;
8. exact terms-revision two-party confirmation;
9. Family Event/Google ownership foundation remaining inactive/non-overlapping;
10. 50-table and provider/Request anomaly reconciliation.

## Prohibited in this PR

- production Supabase apply;
- real LINE delivery;
- Google provider mutation;
- P1 activation;
- `main` merge.

Anchor the next independent source review to the exact PR head whose full required CI is green. Any head movement requires reviewing that new exact head.
