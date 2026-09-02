# Family Ops Detailed Design — Round 3 Focused Independent Re-Review

## 0. Mode

**INDEPENDENT RE-REVIEW / NO IMPLEMENTATION**

Repository:

`syoudai0514/family-ops`

Target:

- PR `#41`
- fresh-read the **actual current PR head**
- fresh-read CURRENT `main`
- do not reuse any older reviewed head SHA

Do not modify code, docs, migration, Supabase, Edge Functions, LINE, Google, Vercel, production data, commit, or PR.

Base rubrics remain:

1. `FAMILY-OPS-DETAILED-DESIGN-INDEPENDENT-REVIEW-REQUEST.md`
2. `FAMILY-OPS-DETAILED-DESIGN-ROUND1-REREVIEW-REQUEST.md`
3. `FAMILY-OPS-DETAILED-DESIGN-ROUND2-REREVIEW-REQUEST.md`

This Round 3 gate is intentionally focused. Prior reviewers already found Requirements contradiction 0 and the Authority/truth-separation direction valid. Do not restart the whole product design unless current remediation introduced an actual regression.

---

## 1. Why Round 3 exists

Latest independent reviews supplied by the user agreed that almost all prior BLOCKER/HIGH findings were closed, but identified two remaining issues:

1. **CURRENT physical table inventory disagreement**
   - one reviewer found `public.household_task_categories` and `private.family_ops_calendar_mirrors` missing and therefore 48 tables rather than 46;
   - another reviewer reported a mechanical 46/46 match.
2. **Request legacy status/timestamp compatibility**
   - status projection existed, but CURRENT `requests` also has a status↔timestamp CHECK;
   - post-accept change/cancel Attempts were not physically composable by the previous text.

Both have now been remediated. Re-review the actual blobs, not this summary.

---

## 2. Mandatory physical baseline audit — first

Confirm CURRENT main SHA and full migration chain.

### 2.1 Table-count discrepancy

Do **not** use a parser/grep that matches only plain `CREATE TABLE`.

Explicitly fresh-read:

`supabase/migrations/20260822000001_calendar_projection_domain.sql`

Verify that it contains:

- `create table if not exists public.household_task_categories`
- `create table if not exists private.family_ops_calendar_mirrors`

Then verify later migrations continue to use/evolve the mirror, especially:

- `20260822000003_family_ops_google_outbox.sql`
- `20260822000005_review_fix_p1_domain.sql`

Also verify no later CURRENT migration drops those tables.

Expected CURRENT inventory asserted by current design:

- public 27
- private 21
- total 48

Review the 48/48 disposition in `08_CURRENT_MAIN_PHYSICAL_SCHEMA_ALIGNMENT.md`.

If your direct CURRENT read proves a different count, report the exact CREATE/DROP chain and treat the physical fact as authoritative.

---

## 3. HIGH closure A — Request status + timestamp CHECK compatibility

Fresh-read CURRENT Request definition in `20260819000003_tasks_recurrence.sql` and any later alteration.

Verify current physical behavior includes:

- status allowed set
- status NOT NULL
- lifecycle CHECK coupling status with:
  - accepted_at
  - declined_at
  - cancelled_at
  - completed_at

Then verify current PR docs now close it in both `02_DATA_MODEL_AND_MIGRATION.md` and `08_CURRENT_MAIN_PHYSICAL_SCHEMA_ALIGNMENT.md`.

Required properties:

### Pre-agreement

- pending/checking/consulting/awaiting_confirmation -> legacy pending + all terminal timestamps null
- accepted -> legacy accepted + accepted_at only
- declined -> legacy declined + declined_at only
- expired -> canonical remains expired; legacy compatibility tuple uses cancelled + compatibility-only cancelled_at
- cancelled -> legacy cancelled + cancelled_at

### Multi-attempt / post-agreement

Once an agreement has been accepted:

- legacy Request stays `accepted + accepted_at`
- a pending/terminal `change` or `cancel` Attempt is **not** projected back into legacy pending/declined/cancelled tuple
- canonical reader owns the current negotiation view
- accepted change mutates linked Task/assignment but legacy Request remains accepted compatibility
- declined/expired/cancelled change leaves legacy Request accepted
- accepted cancel can close/cancel canonical relationship/work without forcing an impossible legacy accepted_at+cancelled_at tuple
- new runtime never sets Request completed merely because linked Task completes
- historical pre-cutover completed rows remain preserved/backfilled

### Physical strategy

Verify design explicitly chooses one server-owned compatibility helper/transaction that writes the entire legacy lifecycle tuple atomically and keeps CURRENT CHECK valid.

Verify WP-DD4 acceptance covers these cases.

If an implementer still needs to invent which timestamp to clear/set for a valid canonical Attempt transition, this remains HIGH.

---

## 4. HIGH closure B — CURRENT Task→Google mirror versus Family Event Authority

Fresh-read actual CURRENT mirror path.

Verify `private.family_ops_calendar_mirrors` is active durable infrastructure, including task-trigger enqueue/worker/provider identity/ETag behavior.

Then review current design boundary.

Required properties:

- `family_ops_calendar_mirrors` has explicit disposition, not omission
- it remains bounded to Task-owned projection (transport + explicitly Google-visible standalone Task)
- it is not Family Event household truth or field Authority
- new Family Event writer does not silently share the same provider event with Task mirror
- exactly one writer-owner per provider event identity
- transport mirror is not auto-converted
- existing special Task mirror is not auto-converted to Event by title/date/category guess

### Explicit adoption/ownership transfer

If an existing Task-mirrored Google event is explicitly adopted as Family Event, verify design requires:

1. stable projection/provider identity, no title search
2. Task enqueue guard during transfer
3. no race with processing lease
4. pending/failed state reconciled or transfer blocked
5. provider_event_id + ETag/current external snapshot preserved
6. Family Event external link created from exact identity
7. Task mirror marked/guarded superseded before Family Event writer starts
8. post-transfer exactly-one-writer audit
9. transferred projection cannot be re-enqueued by Task trigger

Verify `07` has implementation acceptance for queue reconciliation / double-writer audit.

If implementer must invent how to avoid a Task mirror and Family Event writer both PATCHing the same Google event, this is HIGH.

---

## 5. MEDIUM cleanup re-check

Previous non-blocking recommendations should now be checked:

### 5.1 `02` phase drift

Verify `02` no longer says “enable new writes in Phase 3, read cutover in Phase 4”.

Expected:

- Phase 3 deploy canonical reader+writer inactive
- Phase 4 atomic aggregate read+write activation

Verify participant model in `02` includes direct test context and compatibility-primary migration semantics.

### 5.2 Work-package gaps

Verify `07` now contains:

- dedicated shopping responsibility/actual/duplicate-safety package
- Request legacy CHECK acceptance
- DailyBrief one-day schedule override acceptance
- all-day event display acceptance scenarios
- Family Event Google package covering CURRENT Task-mirror ownership/reconciliation

These may remain implementation-level MEDIUM only if the meaning/order is already unambiguous. Prefer PASS.

---

## 6. Regression checks — previously PASS areas

Re-check only for regressions introduced by the latest remediation:

- Task completion CHECK strategy
- Task waiting current truth
- ActorRef simulated identity
- direct test-context/read leakage boundary
- atomic R0/R1/P1 cutover
- shopping separate aggregate
- DailyBrief 06:30/09:00/20:30 persistence
- all-day display vs timed conflict
- outcome_reason
- compatibility-primary has no product meaning
- consultation proposer confirmation
- legacy Request/Task mismatch audit

Do not reopen an item merely because exact SQL constraint name or Flex JSON is deferred to implementation review.

---

## 7. Requirements Final-GO MEDIUM 3

Report `PASS / PARTIAL / FAIL`:

1. `大体やった` + carryover noise
2. duplicate-sensitive neutral completion, including shopping + undo/correction
3. one-user synthetic delivery + domain-state/test-read isolation

Target: 3/3 PASS.

---

## 8. Required output

Start with:

- `GO`
- `GO WITH CONDITIONS`
- or `NO-GO`

Then report:

- BLOCKER / HIGH / MEDIUM / LOW counts
- physical baseline: migration count + table count, with explicit result for the two `CREATE TABLE IF NOT EXISTS` tables
- Request status+timestamp/multi-attempt compatibility: PASS/PARTIAL/FAIL
- Task-mirror / Family Event exactly-one-writer boundary: PASS/PARTIAL/FAIL
- `02` phase cleanup: PASS/PARTIAL/FAIL
- `07` work-package cleanup: PASS/PARTIAL/FAIL
- regression check summary
- Requirements Final-GO MEDIUM 3
- only genuinely new material findings
- final merge / ADR 0013 / implementation gate verdict

---

## 9. Gate

- any BLOCKER/HIGH => NO-GO
- MEDIUM may be carried only if it does not force implementer invention of current truth, consent, migration semantics, test identity, or provider-write ownership
- if BLOCKER/HIGH=0 and Requirements contradiction=0, explicitly state whether PR #41 may merge and ADR 0013 may become Accepted

Key question:

**Can the implementation team now build migrations/commands/read models/test sandbox/Google Authority against the actual CURRENT main without inventing Request CHECK behavior, omitted table disposition, or Google writer ownership?**
