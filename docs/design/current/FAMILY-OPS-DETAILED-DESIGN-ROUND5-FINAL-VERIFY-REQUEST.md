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

This is a focused final verification. Round 4 closed all BLOCKER/HIGH findings. One reviewer returned `GO`; another returned `GO WITH CONDITIONS` with one MEDIUM: stale physical wording in `02_DATA_MODEL_AND_MIGRATION.md`.

The current PR head contains the requested synchronization. Verify that condition and regression only.

## 1. Sources to fresh-read

Mandatory:

1. `docs/design/current/02_DATA_MODEL_AND_MIGRATION.md`
2. `docs/design/current/07_ACCEPTANCE_ROLLOUT_WORK_PACKAGES.md`
3. `docs/design/current/08_CURRENT_MAIN_PHYSICAL_SCHEMA_ALIGNMENT.md`
4. `docs/design/current/README.md`
5. `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`
6. proposed ADR 0013

Fresh-read CURRENT migrations and independently verify the established physical baseline: 78 migration files, public 27, private 23, total 50.

At minimum inspect:

- `20260822000001_calendar_projection_domain.sql`
- `20260822000003_family_ops_google_outbox.sql`
- `20260822000005_review_fix_p1_domain.sql`
- `20260824000002_google_calendar_permission_loss.sql`

## 2. Single Round 4 condition

Verify current `02_DATA_MODEL_AND_MIGRATION.md` now states:

1. CURRENT inventory = **50 tables = public 27 / private 23**.
2. Provider lifecycle includes:
   - `private.family_ops_calendar_mirrors`
   - `private.family_ops_calendar_target_deletions`
   - `private.family_ops_calendar_orphaned_mirrors`
3. `§13.2` covers Task mirror bridge + target-deletion DELETE bridge + Family Event external-link writer.
4. DELETE is a provider mutation; orphan is observation only and not writable ownership.
5. unresolved orphan blocks adoption until fresh provider access + exact identity/ETag revalidation or intentional alternate linking.
6. Phase 2 covers all three lifecycle tables and a **50-table physical precondition audit**.
7. `§21.6` inventories mirror/deletion/orphan including lease/retry/blocked and orphan reason/observed state.
8. index/constraint expectations include the three-path mutation-owner invariant and orphan blocker.
9. destructive-shortcut rules forbid stale deletion authorization and silent orphan promotion.

## 3. Regression verification

Confirm no regression in:

- Request legacy lifecycle tuple compatibility and post-accept change/cancel composition
- Task completion CHECK migration strategy
- Task waiting truth
- ActorRef + direct test-context isolation
- atomic read/write activation and R0/R1/P1
- Shopping anyone + neutral completion/undo
- DailyBrief 06:30 / 09:00 / 20:30 + one-day override
- all-day display vs timed conflict
- outcome_reason / compatibility-primary / consultation proposer confirmation
- Google three-path mutation ownership + stale destructive DELETE guard

## 4. Requirements Final-GO MEDIUM 3

Report PASS/PARTIAL/FAIL for:

1. `大体やった` + carryover noise
2. duplicate-sensitive neutral completion, including shopping + undo/correction
3. one-user synthetic delivery + direct domain/test isolation

Target: **3/3 PASS**.

## 5. Final gate

Return `GO` only when:

- BLOCKER 0
- HIGH 0
- Requirements contradiction 0
- the Round 4 `02` synchronization condition is closed
- provider ownership can be implemented without inventing another lifecycle rule
- Requirements Final-GO MEDIUM 3 = 3/3 PASS

If the prior MEDIUM is demonstrably closed and no new material finding exists, return `GO` rather than creating another review round for stylistic cleanup.