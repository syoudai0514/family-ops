# Family Ops Detailed Design — Round 4 Final Physical Re-Review

## 0. Mode

**INDEPENDENT RE-REVIEW / NO IMPLEMENTATION**

Repository: `syoudai0514/family-ops`

Target:

- PR `#41`
- fresh-read the **actual current PR head** at review start and end
- fresh-read CURRENT `main` and record its SHA
- do not review an older head from Round 1/2/3

Do not modify code, docs, migrations, Supabase, Edge Functions, LINE, Google, Vercel, production data, commit, or PR.

Primary target documents:

1. `docs/design/current/08_CURRENT_MAIN_PHYSICAL_SCHEMA_ALIGNMENT.md`
2. `docs/design/current/07_ACCEPTANCE_ROLLOUT_WORK_PACKAGES.md`
3. `docs/design/current/02_DATA_MODEL_AND_MIGRATION.md`
4. `docs/design/current/README.md`

Use previous review rubrics as regression checks, but **do not restart the accepted Requirements/Authority/truth model from zero** unless current remediation introduced a real contradiction.

## 1. Review history / current merge gate

Requirements Baseline already received final `GO`.

Detailed-design prior reviews closed:

- Task `待ち` current truth
- ActorRef simulated identity
- R0/R1/P1 rollback safety
- Task completion CHECK compatibility
- Request status + timestamp + multi-attempt compatibility
- test scoping/leak prevention
- shopping claim/actual/duplicate safety
- DailyBrief schedule persistence + one-day override
- all-day display vs timed conflict
- work-package gaps

Round 3 had exactly one remaining merge-blocking area. Two independent fresh reviews both reported:

- `NO-GO`
- BLOCKER 0
- HIGH 1
- Requirements contradiction 0

The shared HIGH was incomplete CURRENT Google provider-lifecycle inventory/ownership.

If any BLOCKER or HIGH remains after this review, verdict must be `NO-GO`.

## 2. Physical table inventory — mandatory first step

Do not inherit the document count.

Fresh-read all 78 CURRENT migrations and enumerate tables using a case-insensitive pattern that matches both:

- `CREATE TABLE schema.name`
- `CREATE TABLE IF NOT EXISTS schema.name`

Also verify there is no unqualified/other-schema table that invalidates the count and that listed tables were not later dropped.

The current design claims:

- public: **27**
- private: **23**
- total: **50**

Explicitly verify the late tables:

- `public.household_task_categories`
- `private.family_ops_calendar_mirrors`
- `private.family_ops_calendar_target_deletions`
- `private.family_ops_calendar_orphaned_mirrors`

Mandatory source reads:

- `supabase/migrations/20260822000001_calendar_projection_domain.sql`
- `supabase/migrations/20260822000003_family_ops_google_outbox.sql`
- `supabase/migrations/20260822000005_review_fix_p1_domain.sql`
- `supabase/migrations/20260824000002_google_calendar_permission_loss.sql`

Compare the physical result mechanically with the disposition list in `08`.

If CURRENT has a table absent from the design inventory, or the design lists a non-existent CURRENT table as CURRENT physical state, report it before semantic review. A live provider-write/queue table omission is HIGH.

## 3. Round 3 HIGH closure — Google provider lifecycle

Fresh-read the actual behavior of all three private lifecycle tables.

### 3.1 `family_ops_calendar_mirrors`

Verify CURRENT behavior includes stable projection/provider identity, upsert/delete intent, sync state, lease/retry, provider ID/ETag and Task-trigger enqueue.

Design disposition must remain bounded `BRIDGE`, not Family Event truth.

### 3.2 `family_ops_calendar_target_deletions`

Verify CURRENT behavior includes:

- durable old-target DELETE job
- provider identity
- pending/processing/failed/deleted and later blocked behavior
- claim + lease
- complete/fail/retry
- consumption by the current Google outbox worker path

Design must treat this as a **provider mutation path**, not merely an audit table.

### 3.3 `family_ops_calendar_orphaned_mirrors`

Verify CURRENT behavior records provider identities that cannot be safely managed after calendar permission/eligibility loss.

Design must treat it as audit/observation, not writable Family Event truth and not proof the provider event still exists.

## 4. Exactly-one-provider-mutation-owner invariant

Review `08` §10 and answer whether the implementation can enforce, without inventing semantics:

For each provider identity, at most one active Family Ops provider mutation path exists among:

1. Task mirror bridge (`family_ops_calendar_mirrors`)
2. old-target deletion bridge (`family_ops_calendar_target_deletions`)
3. Family Event external-link writer

DELETE counts as a provider mutation/writer for this invariant.

Verify:

- Task mirror ownership transfer guards future Task enqueue;
- a live target-deletion job is not left capable of deleting an event after Family Event ownership starts;
- an unexpired processing deletion lease blocks transfer rather than being cancelled underneath the worker;
- pending/failed/blocked deletion jobs are reconciled or made terminal non-mutating with history preserved before transfer;
- already-completed deletion means the deleted provider identity is not adopted as live;
- worker/claim adapter revalidates current ownership before destructive DELETE, so stale queued job existence alone is not authorization;
- Family Event writer does not consume the old bridge tables as its canonical queue.

Mandatory failure scenario:

1. calendar A is old write target;
2. target changes to calendar B and an A-event deletion job is queued;
3. the same A provider event is proposed for explicit Family Event adoption;
4. after adoption, no stale deletion worker may delete the Family-Event-owned event.

If implementer must invent the cancellation/supersession/guard rule here, this remains HIGH.

## 5. Permission-loss / orphan transfer safety

Review permission-loss behavior from `20260824000002_google_calendar_permission_loss.sql`.

Verify current design requires:

- unresolved orphan record for the provider identity blocks direct ownership transfer;
- orphan record alone never becomes `family_event_external_links`;
- provider access must be restored and exact event existence/identity/ETag freshly revalidated before adopting the same provider event;
- alternatively the user may intentionally link/create a different eligible provider event;
- blocked mirror/deletion state is not interpreted as successful cleanup;
- no provider identity/ETag is guessed.

Mandatory failure scenario:

Google write permission is lost, mirror is blocked and orphan row recorded. Family Event adoption must not silently claim that provider event as writable merely because the old provider_event_id is known.

## 6. Work-package / release-gate alignment

Verify `07` now includes the full provider lifecycle in:

### WP-DD1 / WP-DD2

- schema/guard foundation
- **50-table assertion**
- Task mirror inventory
- target-deletion queue/lease inventory
- orphan identity/reason inventory

### WP-DD8

Acceptance must explicitly cover:

- Task mirror
- target deletion queue
- orphan state
- ownership transfer
- destructive DELETE guard
- exactly-one-provider-mutation-owner audit
- unresolved lifecycle anomaly blocking Family Event P1

### WP-DD11 / release evidence

Verify audit/evidence includes:

- Task mirror counts/state
- target deletion counts/state including blocked
- orphan counts/disposition
- provider-mutation overlap = zero
- unresolved orphan/provider lifecycle anomaly = zero for affected cutover

If `08` defines the truth but `07` still allows an implementation/release path that omits the deletion/orphan subsystem, report HIGH if that forces an unsafe provider cutover; otherwise MEDIUM.

## 7. Regression checks — must remain PASS

Do not reopen without evidence, but fresh-check for remediation regression:

1. **Request physical compatibility**
   - full `status + accepted_at + declined_at + cancelled_at + completed_at` tuple
   - pre-agreement checking/consulting/awaiting -> CHECK-valid pending projection
   - expired compatibility handling
   - post-accept change/cancel Attempt keeps legacy accepted tuple
   - new Task completion does not write Request completed
2. Task completion CHECK replacement strategy
3. Task waiting current truth
4. ActorRef / direct test scoping / no operator substitution
5. aggregate atomic read+write cutover / P1 rollback rule
6. Shopping `誰でもOK` + neutral completion/undo
7. DailyBrief 06:30/09:00/20:30 + one-day override
8. all-day display vs timed conflict
9. outcome_reason / compatibility-primary / consultation confirmation

Any new regression that forces implementer invention at product/domain/migration/provider-ownership level should be severity-rated normally.

## 8. Requirements Final-GO MEDIUM 3

Report `PASS / PARTIAL / FAIL` for all three:

1. `大体やった` + carryover noise
2. duplicate-sensitive neutral completion including shopping + undo/correction
3. one-user synthetic delivery + direct domain/test isolation

Target: 3/3 PASS.

## 9. Required output

Return:

1. Final Verdict: `GO / GO WITH CONDITIONS / NO-GO`
2. severity count: BLOCKER / HIGH / MEDIUM / LOW
3. physical table count and 50/50 comparison result
4. provider lifecycle table disposition verdict
5. exactly-one-provider-mutation-owner verdict
6. permission-loss/orphan adoption verdict
7. WP-DD8/WP-DD11 alignment verdict
8. Request compatibility regression verdict
9. Requirements Final-GO MEDIUM 3 verdict
10. any remaining finding with:
    - problem
    - concrete system scenario
    - why severity is justified
    - smallest safe remediation

## 10. GO gate

`GO` is allowed only if:

- BLOCKER 0
- HIGH 0
- Requirements contradiction 0
- CURRENT physical inventory is fully dispositioned
- provider mutation ownership is executable without invention
- orphan handling cannot silently create writable ownership
- no regression in prior closed HIGHs
- Final-GO MEDIUM 3 remain PASS

If BLOCKER/HIGH remains:

- do not merge PR #41
- do not accept ADR 0013
- do not begin implementation

This review is documentation/design only. No implementation changes.