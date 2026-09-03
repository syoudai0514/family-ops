# Family Ops — WP-DD1 / DD2 remainder / DD3A / DD3 Source Review Handoff

## Status

**SOURCE-REVIEW REMEDIATION CANDIDATE / DRAFT PR / NO PRODUCTION APPLY / NO MERGE**

PR #44 is retargeted directly to CURRENT `main`; the earlier stacked-on-PR-#43 wording is obsolete.

The previous independent review was anchored to historical head
`6125af780358cd7f8155cc67f8cfe7a4046d0571` and returned NO-GO. That SHA is
review evidence only; it must not be treated as the CURRENT remediation head.
Review the exact CURRENT PR head and only the CI attached to that exact head.

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
- rerunnable backfill coexistence with canonical-created Request Attempts (no guessed legacy Attempt and no active-attempt uniqueness collision);
- DailyBrief schedule kinds + one-day override foundation;
- Family Event / field-authority / external-link schema foundation without writer activation;
- change-candidate foundation;
- child / school-context / source-document foundation;
- shopping participant/revision/test prerequisites;
- CURRENT 50-table declaration remains the pre-#43 physical baseline assertion (27 public / 23 private), not a claim that the repository has only 50 total tables;
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

## Independent review remediation after historical head 6125af7

Forward-only migration `20260903000018_source_review_foundation_remediation.sql`
closes the later Claude source-review findings without rewriting accepted migrations.

### HIGH — test subtask RLS isolation

`public.task_subtask_instances` now has the same production-read boundary as the
other test-scoped public business tables:

- authenticated SELECT requires household membership;
- `test_context_id IS NULL` is mandatory;
- regression evidence reads the table as an actual `authenticated` household member and proves the test subtask is invisible.

### HIGH — canonical assignment vs R0 reconciliation

`task_planned_actor_mismatch` no longer assumes every valid production Task must
remain `assignment_source='legacy_snapshot'` forever.

- canonical `manual` / `agreement` assignments are valid only when assignment mode, ActorRef, and legacy compatibility user agree;
- legacy rows continue to require the strict `legacy_snapshot` representation;
- rerunning the R0 maintenance backfill does not overwrite canonical assignment authority;
- a final lexical test requires the complete foundation reconciliation result to be zero after every earlier fixture.

### MEDIUM — canonical Task completion mirrors Request execution truth

When a linked accepted Task first transitions to `completed`, the compatibility
Request tuple is synchronised to `completed` with the Task completion time and a
revision increment. This is one-way execution projection only; declined,
cancelled, or unrelated Requests are not resurrected.

### MEDIUM — system ActorRef test-scope fail closed

System ActorRefs are production-only:

- DB CHECK rejects `actor_kind='system'` with a test context;
- execution and row-scope guards reject system actors in any test execution context;
- simulation continues to use immutable `simulated_member` ActorRefs rather than fake users/members.

### MEDIUM — performer correction kind invariant

The durable `task_actual_participants` boundary now permits only
`real_user` / `simulated_member` performers. This gives completion, correction,
backfill, and future adapters the same invariant and closes the subtasks-mode
system-performer gap.

### Fixture / audit hardening

`38_canonical_r0_request_and_test_actual_guards.sql` now gives its accepted
legacy Request a valid linked execution Task instead of manufacturing a state
that the production contract rejects. Reconciliation was not weakened to make
the fixture pass.

`99_canonical_reconciliation_zero.sql` runs after all foundation SQL tests and
requires every reconciliation issue count to be zero.

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
  - reconciliation remains strict for valid fixture state.
- `38_canonical_r0_request_and_test_actual_guards.sql`
  - CURRENT-valid accepted Request drift fixture keeps a linked execution Task.
- `38_test_execution_sandbox_foundation.sql`
  - operator/domain actor separation, receipt identity, archived-context rejection.
- `39_dd3a_mandatory_actorref_e2e.sql`
  - one real papa/operator drives papa + simulated-mama Request/consultation/Task E2E without fake membership.
- `40_canonical_command_concurrency_reconciliation.sql`
  - replay/conflict, stale revision, claim/takeover, waiting/resume, completion/correction, reconciliation, info/candidate boundaries.
- `41_google_projection_test_scope_isolation.sql`
  - test Task INSERT / UPDATE / DELETE cannot affect production provider projection;
  - reconcile excludes test Tasks;
  - test real-user transport Task cannot alter production P/M payload;
  - stale/hostile special mirror referencing a test Task cannot produce provider upsert.
- `42_canonical_backfill_command_coexistence.sql`
  - rerunning the R0 maintenance backfill after a canonical Request command does not add a legacy Attempt, collide with the active-Attempt constraint, or create a false reconciliation anomaly.
- `43_member_actor_ref_continuity.sql`
  - members created after the one-time backfill immediately receive exactly one canonical real-user ActorRef through the normal create/join path.
- `44_foundation_source_review_remediation.sql`
  - authenticated test-subtask RLS isolation;
  - system/test-scope prohibition;
  - correction performer-kind rejection with no durable partial mutation;
  - canonical Task completion -> Request completed compatibility projection;
  - manual/agreement assignment remains reconciliation-clean and survives R0 backfill.
- `99_canonical_reconciliation_zero.sql`
  - final suite-wide canonical reconciliation sum must be zero.

## Independent review focus

1. simulated ActorRef vs real operator/auth identity separation;
2. test execution → production LINE/Google/real-consent isolation, including direct subtask RLS;
3. Google isolation at trigger entry and every production Task scan/materialization path;
4. receipt replay/hash conflict and lock/revision ordering;
5. Request Attempt / Task execution -> legacy Request lifecycle compatibility;
6. Task assignment/claim/waiting/completion/performer correction atomicity and actor-kind invariants;
7. canonical manual/agreement authority coexisting with strict legacy reconciliation;
8. group reconciliation eligibility/stale behavior;
9. exact terms-revision two-party confirmation;
10. post-migration household-member to ActorRef continuity;
11. Family Event/Google ownership foundation remaining inactive/non-overlapping;
12. CURRENT physical-baseline declaration semantics and final reconciliation zero.

## Prohibited in this PR

- production Supabase apply;
- real LINE delivery;
- Google provider mutation;
- P1 activation;
- `main` merge.

Anchor the next independent source review to the exact CURRENT PR head whose full required CI is green. Any head movement invalidates the prior exact-head review.
