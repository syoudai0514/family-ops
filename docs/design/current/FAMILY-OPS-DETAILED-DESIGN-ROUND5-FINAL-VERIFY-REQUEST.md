# Family Ops Detailed Design — Round 5 Final Focused Verification

## 0. Mode

**INDEPENDENT RE-REVIEW / NO IMPLEMENTATION**

Repository: `syoudai0514/family-ops`

Target:

- PR `#41`
- fresh-read the **actual current PR head** at review start and end
- fresh-read CURRENT `main` and record its SHA
- do not review an older Round 1/2/3/4 head

Do not modify code, docs, migrations, Supabase, Edge Functions, LINE, Google, Vercel, production data, commit, or PR.

This is a **focused final verification**, not a fifth redesign pass. Round 4 already closed all BLOCKER/HIGH findings. One reviewer returned `GO`; the other returned `GO WITH CONDITIONS` with one MEDIUM caused only by stale text in `02_DATA_MODEL_AND_MIGRATION.md`.

The current PR head contains the requested `02` synchronization. Verify that condition and regression only.

---

## 1. Sources to fresh-read

Mandatory:

1. `docs/design/current/02_DATA_MODEL_AND_MIGRATION.md`
2. `docs/design/current/07_ACCEPTANCE_ROLLOUT_WORK_PACKAGES.md`
3. `docs/design/current/08_CURRENT_MAIN_PHYSICAL_SCHEMA_ALIGNMENT.md`
4. `docs/design/current/README.md`
5. `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`
6. proposed ADR 0013

For physical truth, re-use no prior count. Fresh-read CURRENT migrations and verify the already-established baseline:

- 78 migration files
- public 27
- private 23
- total 50

At minimum directly inspect the Google provider lifecycle creators/evolvers:

- `20260822000001_calendar_projection_domain.sql`
- `20260822000003_family_ops_google_outbox.sql`
- `20260822000005_review_fix_p1_domain.sql`
- `20260824000002_google_calendar_permission_loss.sql`

---

## 2. The single Round 4 condition to verify

Round 4 `GO WITH CONDITIONS` identified only this MEDIUM:

> `02_DATA_MODEL_AND_MIGRATION.md` still described the older 48-table / two-provider-writer physical truth even though binding `08` and `07` were already correct.

Verify the current `02` now directly states all of the following:

1. CURRENT physical inventory = **50 tables = public 27 / private 23**.
2. CURRENT provider lifecycle includes all three persisted tables:
   - `private.family_ops_calendar_mirrors`
   - `private.family_ops_calendar_target_deletions`
   - `private.family_ops_calendar_orphaned_mirrors`
3. `§13.2` defines provider mutation ownership across:
   - Task mirror bridge
   - target-deletion DELETE bridge
   - Family Event external-link writer
4. DELETE is treated as a provider mutation; an orphan row is observation only and never writable ownership by itself.
5. unresolved matching orphan blocks adoption until fresh provider access + exact identity/ETag revalidation, or another eligible provider event is intentionally linked.
6. Phase 2 reconciliation covers mirror + target deletion + orphan, and uses a **50-table physical precondition audit**.
7. `§21.6` inventories/reconciles all three lifecycle tables, including deletion lease/retry/blocked state and orphan reason/observed state.
8. index/constraint expectations include the three-path provider-mutation-owner invariant and orphan adoption blocker.
9. destructive shortcuts prohibit stale deletion authorization and silent orphan promotion.

If any of these still contradict `08` / `07`, report it with severity.

---

## 3. Regression verification

Do not reopen already-closed architecture questions unless the current head actually regressed them.

Confirm no regression in:

- Request legacy `status + accepted_at + declined_at + cancelled_at + completed_at` compatibility
- post-accept change/cancel Attempt composition
- Task completion CHECK migration strategy
- `待ち` current truth
- ActorRef + direct test-context isolation
- aggregate read/write atomic activation and R0/R1/P1
- Shopping `誰でもOK` + neutral completion/undo
- DailyBrief 06:30 / 09:00 / 20:30 + one-day override
- all-day display vs timed conflict
- outcome_reason / compatibility-primary / consultation proposer confirmation
- Google exactly-one-provider-mutation-owner and stale destructive DELETE guard in `08`/`07`

A regression that forces implementation-time invention is HIGH.

---

## 4. Requirements Final-GO MEDIUM 3

Report `PASS / PARTIAL / FAIL` for all three:

1. `大体やった` + carryover noise
2. duplicate-sensitive neutral completion, including shopping + undo/correction
3. one-user synthetic delivery + direct domain/test isolation

Target remains **3/3 PASS**.

---

## 5. Output format

Return:

1. actual CURRENT main SHA
2. actual PR head SHA at start/end
3. Final Verdict: `GO` or `NO-GO`
4. severity counts: BLOCKER / HIGH / MEDIUM / LOW
5. Round 4 condition verification table
6. regression check
7. Requirements Final-GO MEDIUM 3 result
8. any remaining findings with concrete CURRENT/runtime scenario

---

## 6. Final gate

`GO` only when:

- BLOCKER 0
- HIGH 0
- Requirements contradiction 0
- the stale `02` physical truth is fully synchronized to 50 tables / three Google lifecycle tables
- provider ownership can be implemented without inventing a fourth rule
- Requirements Final-GO MEDIUM 3 = 3/3 PASS

If any BLOCKER/HIGH remains: do not merge PR #41, do not accept ADR 0013, do not begin implementation.

If the only prior MEDIUM is demonstrably closed and no new material finding exists, return **GO** rather than creating another review round for stylistic cleanup.