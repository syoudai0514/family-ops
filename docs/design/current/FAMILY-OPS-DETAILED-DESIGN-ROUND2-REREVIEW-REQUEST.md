# Family Ops Detailed Design — Round 2 Historical Re-Review Rubric

## Status

**HISTORICAL REVIEW RUBRIC / NO IMPLEMENTATION**

This file records the Round 2 review concerns that must remain regression-tested, but it is **not the current re-review entry point**.

The current independent re-review instruction is:

`docs/design/current/FAMILY-OPS-DETAILED-DESIGN-ROUND3-REREVIEW-REQUEST.md`

Round 3 supersedes any old physical-count/head assumption that appeared in earlier versions of this file.

In particular, do **not** use the former `46 tables = public 26/private 20` assertion. Fresh direct CURRENT read identified two tables created with `CREATE TABLE IF NOT EXISTS` that were omitted by the prior inventory:

- `public.household_task_categories`
- `private.family_ops_calendar_mirrors`

The current asserted inventory and required direct verification are defined by Round 3 and `08_CURRENT_MAIN_PHYSICAL_SCHEMA_ALIGNMENT.md`.

---

## Round 2 concerns retained as regression rubric

A current reviewer should still verify these areas have not regressed.

### 1. Task completion CHECK compatibility

CURRENT task completion CHECKs require a forward constraint migration before canonical participant-based completion.

Required invariant:

- subtasks parent legacy actor remains null
- production whole completion has canonical participant(s) and technical compatibility real-user mirror while required
- simulated/test completion never fabricates a real user
- completed/completed_at remains valid

### 2. Request Attempt / legacy Request compatibility

Canonical states include pending/checking/consulting/awaiting_confirmation/accepted/declined/expired/cancelled.

Old readers must not interpret checking/consulting as unrestricted old pending after canonical cutover.

**Current Round 3 additionally requires full status+timestamp CHECK compatibility and post-accept multi-attempt composition.**

### 3. Atomic aggregate cutover

Schema/backfill -> deploy canonical reader+writer inactive -> reconcile -> activate canonical read+write together -> permit first new-only state.

After P1 no legacy current-truth rollback.

### 4. Test scope / simulated actor isolation

Direct test context on canonical test-capable business rows, ActorRef simulated identity, production read exclusion, and production outbox/Google/real-consent hard block.

### 5. CURRENT table disposition

Every actual CURRENT application-owned table that overlaps the program must have KEEP/EVOLVE/BRIDGE/SUPERSEDE/OUT-OF-SCOPE treatment.

**Use Round 3's direct `CREATE TABLE IF NOT EXISTS` verification and current 48-table inventory, not the stale Round 2 count.**

### 6. Shopping

Shopping stays a separate aggregate but gains assignment mode, anyone claim, participant/recorder, revision, test context, duplicate-sensitive neutral completion and correction.

### 7. DailyBrief schedule persistence

Persist weekday 06:30 / nonworkday 09:00 / evening 20:30, date-specific override, settings/RPC/dispatcher/receipt evolution, and suppress legacy extra routine pushes after cutover.

### 8. All-day display vs conflict

Relevant all-day Event/Google occurrence is visible in DailyBrief; no fake 00:00; timed conflict still excludes all-day under current requirements.

### 9. Outcome / compatibility-primary / consultation

- task outcome reason is current snapshot
- compatibility-primary has no product meaning
- explicit proposer confirms exact terms revision; AI summary alone confirms nobody

### 10. Test sandbox dependency order

One-user actual-household simulation may not start before ActorRef/test scope/execution context/side-effect hard guard exists.

---

## Requirements Final-GO MEDIUM regression rubric

Continue to report:

1. `大体やった` + carryover noise
2. duplicate-sensitive neutral completion
3. one-user synthetic delivery vs production delivery

Target remains PASS/PASS/PASS.

---

## Current gate

Use Round 3 for the current verdict.

Any BLOCKER/HIGH remaining in the actual current head => NO-GO, no merge, no ADR 0013 acceptance, no implementation.
