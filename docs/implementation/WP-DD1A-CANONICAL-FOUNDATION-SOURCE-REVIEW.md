# Family Ops — WP-DD1A Canonical Foundation Source Review

## Status

**SOURCE REVIEW CANDIDATE / NO PRODUCTION APPLY / NO CAPABILITY ACTIVATION**

This document defines the review boundary for the first implementation batch after the accepted Requirements + Detailed Design.

Canonical governance:

1. `docs/adr/0013-current-detailed-design-architecture-evolution.md` — Accepted
2. `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`
3. `docs/design/current/`
4. this implementation PR

## Baseline

Implementation branch started from:

`main @ 9712adda903bf310d14a61b19585b36c9d86f012`

At branch creation, CURRENT physical baseline remained:

- migrations: 78
- public tables: 27
- private tables: 23
- total: 50

This PR adds new migrations after the accepted chain. It does **not** rewrite an existing migration.

## Scope

This is **Batch 1A**, a deliberately reviewable subset of WP-DD1/WP-DD2. It implements the highest-risk identity / Task / Request compatibility foundation before any user-facing semantic cutover.

Included:

- `test_simulation_contexts`
- common `domain_actor_refs` (`real_user | simulated_member | system`)
- immutable ActorRef identity
- nullable R0 compatibility columns on current Task / Request / Handover / Shopping aggregates
- Task waiting / outcome / assignment / claim / revision / test-context fields
- Task actual participant representation, including technical `compatibility_primary`
- group reconciliation evidence tables (`all_done | mostly_done | individual`)
- Request Attempt + terms-revision confirmation representation
- ActorRef-capable information acknowledgement
- direct test-context fields on canonical rows in this batch
- cross-household ActorRef FKs and actor/test-scope guards
- parent/child direct test-context consistency guards
- CURRENT Task completion CHECK replacement by catalog inspection
- deterministic/idempotent real-user ActorRef and legacy-state backfill
- read-only reconciliation report
- RLS/direct-read boundary so future test rows cannot leak into ordinary production Data API reads
- SQL tests for schema, deterministic backfill, idempotency, no simulated-identity invention, and completion CHECK compatibility

Explicitly **not** included in Batch 1A:

- relaxing legacy real-user NOT NULL fields needed by simulated Request/task-event writes
- WP-DD3A synthetic LINE delivery or test execution runtime
- canonical Task/Request command activation
- PWA/LINE reader cutover
- `誰でもOK` user-facing claim commands
- DailyBrief schedule-kind migration / 06:30, 09:00, 20:30 activation
- Family Event / Google Authority writer
- Google provider lifecycle ownership transfer
- nursery/Codmon image intake
- production migration apply / feature activation / P1

Those remain separate reviewed batches. A reviewer must not require them to be implemented in this PR, but must reject this PR if it makes their later safe implementation impossible.

## Compatibility posture

This PR is R0-only.

- Old production runtime may continue reading/writing legacy columns.
- New canonical columns are nullable where old runtime does not populate them.
- The deterministic backfill helper is retained and rerunnable so rows created by old runtime after initial migration can be reconciled before cutover.
- No new-only production semantic state is produced.
- No existing legacy NOT NULL actor column is relaxed yet.
- No current Request status/timestamp tuple behavior is changed.
- No current Google provider mutation path is changed.

## Critical source-review questions

Review actual CURRENT main and actual PR head. Do not review only this summary.

### A. Migration safety

- Are all changes forward/additive/evolution only?
- Are existing migrations untouched?
- Can the new migrations apply after the complete CURRENT migration chain?
- Does any schema change break old runtime before canonical activation?

### B. Task completion physical CHECK

Confirm CURRENT catalog semantics are preserved:

- production `whole + completed` still requires legacy `actual_completed_by_id` during compatibility;
- `subtasks` parent still requires legacy actual actor null;
- test-scoped `whole + completed` may keep legacy real-user mirror null;
- migration discovers the actual old CHECK names from catalog definitions and fails closed on drift;
- `completed_at` status integrity is untouched.

### C. ActorRef/test identity

- one production household member -> exactly one real-user ActorRef;
- simulated ActorRef never has a real user ID;
- production aggregate cannot reference a simulated ActorRef;
- simulated actor cannot use the operator user ID as a compatibility substitute;
- same-household/test-context invariants are enforced for rows implemented in this batch;
- no test/simulated actor is invented by production backfill.

### D. Deterministic backfill

- non-null legacy planned assignee maps to `person` + exact ActorRef;
- null legacy planned assignee maps to `unassigned`, never `anyone`;
- legacy actual actor maps to performer participant;
- recorder is left unknown instead of guessed;
- legacy `completed` Request backfills agreement as `accepted`, not a new execution-completion truth;
- assignment-change vs light Request classification is based only on current structural fields;
- rerun is idempotent;
- reconciliation reports mismatch instead of inventing repair.

### E. Current Request compatibility

This batch must not disturb the CURRENT `requests.status + accepted_at / declined_at / completed_at / cancelled_at` CHECK contract. Request Attempt is additive only. New server-owned tuple projection is a later command-layer batch.

### F. RLS / grants

- all new public business tables have RLS;
- authenticated receives SELECT only, not DML;
- direct production reads exclude test-scoped canonical rows;
- simulated ActorRefs are not exposed as ordinary production ActorRef rows;
- private helper functions are not executable by PUBLIC/anon/authenticated.

### G. No premature P1

Reject if this PR activates a canonical reader/writer, sends production LINE, writes Google, changes user-visible Request behavior, or creates a new-only production semantic state.

## Review severity / gate

Use:

- `BLOCKER`
- `HIGH`
- `MEDIUM`
- `LOW`

For this source batch:

- any migration that can corrupt/reinterpret production truth = BLOCKER/HIGH;
- any old-runtime incompatibility before activation = HIGH;
- any simulated-as-real identity possibility = HIGH;
- any non-idempotent or guessed backfill = HIGH;
- any test-data direct-read leakage caused by this schema = HIGH;
- missing later-WP features that are explicitly out of scope are **not findings**.

Final verdict:

- `GO` — safe to merge this source batch; still no production apply until the implementation rollout gate says so.
- `GO WITH CONDITIONS` — only if no BLOCKER/HIGH and conditions are explicit.
- `NO-GO` — any BLOCKER/HIGH.

## Post-review rule

Do not merge this implementation PR from CI alone. Independent source review of the **actual PR head** is required first.
