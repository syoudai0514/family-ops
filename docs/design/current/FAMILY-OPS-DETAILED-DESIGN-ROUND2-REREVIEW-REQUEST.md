# Family Ops Detailed Design — Round 2 CURRENT-Schema Re-Review

## 0. Mode

**INDEPENDENT RE-REVIEW / NO IMPLEMENTATION**

Repository:

`syoudai0514/family-ops`

Target:

- PR `#41`
- fresh-read the **actual current PR head**; do not review the old heads `6e63eb1661869c7ad549139e91bc480994d55f0b` or `02fe5d956655cd0fc964c70de5dc4f84832d7d31`
- fresh-read CURRENT `main` and confirm its SHA

Do not modify code, docs, migrations, Supabase, LINE, Google, Vercel, production data, commit, or PR.

Base rubrics:

1. `docs/design/current/FAMILY-OPS-DETAILED-DESIGN-INDEPENDENT-REVIEW-REQUEST.md`
2. `docs/design/current/FAMILY-OPS-DETAILED-DESIGN-ROUND1-REREVIEW-REQUEST.md`
3. this file

For CURRENT-main physical schema/cutover details, also treat this as a mandatory review target:

`docs/design/current/08_CURRENT_MAIN_PHYSICAL_SCHEMA_ALIGNMENT.md`

The previous reviews already found the product Requirements, Authority model, truth separation, and ADR 0013 scope directionally valid. Do **not** restart those areas from zero unless the new remediation introduced a real regression.

## 1. Review history to preserve

### Requirements Baseline

Final verdict: `GO`.

### Detailed design initial review

Verdict: `NO-GO` with:

- BLOCKER 0
- HIGH 3
- MEDIUM 3

Those findings were:

- missing Task `待ち` current truth
- incomplete simulated actor persistence model
- unsafe semantic rollback contract
- outcome reason current storage
- broader legacy Request mismatch audit
- test-mode package dependency ordering

They were remediated on the same fixed detailed-design path before this Round 2 review. Re-check for regression, but do not assume the old head still represents the PR.

### CURRENT-main physical alignment review

Verdict: `NO-GO` with reported:

- BLOCKER 1
- HIGH 7
- MEDIUM 8
- LOW 4

The mandatory re-review focus is the physical alignment closure below.

## 2. Physical baseline audit — mandatory first step

Before judging the design, verify CURRENT `main` rather than the older v6 snapshot.

At minimum confirm:

- `main` current SHA
- `supabase/migrations` full tree, including later 20260821–20260825 migrations
- current table inventory relevant to the app
- CURRENT constraint/query behavior used by the findings below

The design now records 78 migration files and 46 application tables (public 26 / private 20). If your fresh read finds a different count, report the exact difference before reviewing semantics.

Review the 46/46 disposition table in `08_CURRENT_MAIN_PHYSICAL_SCHEMA_ALIGNMENT.md` and confirm no current table that overlaps the new semantics is silently omitted.

## 3. BLOCKER re-check — `task_instances` completion CHECK compatibility

Previous problem:

CURRENT `20260819000003_tasks_recurrence.sql` requires:

- subtasks parent `actual_completed_by_id` to be null
- whole completed task `actual_completed_by_id` to be non-null

The old mirror plan could not work for the new participant truth/test actor without changing those CHECKs first.

Verify the current design now requires, in Phase 1:

- explicit replacement of the two current completion-mode CHECKs by a new migration;
- no rewrite of old migration files;
- no physical drop of the legacy column as part of this change;
- production whole completion compatibility mirror remains valid until old readers retire;
- subtasks parent mirror remains null;
- test/simulated whole completion can rely on ActorRef participants without fabricating a real user FK;
- completed/completed_at integrity remains enforced.

Also verify the design defines a deterministic compatibility-primary performer for multi-performer production whole tasks and clearly says it has **no product meaning**.

If the first new completion could still violate the existing physical CHECK, this remains BLOCKER.

## 4. HIGH-1 — Request Attempt → legacy status/read-path compatibility

Verify:

- canonical attempt states remain `pending/checking/consulting/awaiting_confirmation/accepted/declined/expired/cancelled`;
- legacy `requests.status` projection is explicitly defined;
- `checking/consulting/awaiting_confirmation` do not become new illegal CHECK values;
- expired does not resurrect an old pending request;
- accepted execution remains linked Task truth; new runtime does not independently write Request `completed`;
- historical legacy `completed` rows remain preserved/backfilled safely.

Fresh-read and verify current direct readers/writers are accounted for, at minimum:

- `apps/web/src/features/requests/Requests.tsx`
- `apps/web/src/features/today/useTodayData.ts`
- request accept/decline/cancel Edge/RPC paths
- assignment-change request path
- LINE-native request path

Critical expected result:

A Request in canonical `checking` must never be shown by an old reader as actionable `引き受ける / 断る` after semantic cutover.

## 5. HIGH-2 — aggregate read/write cutover order

Previous contradiction:

One document could be read as Phase 3 new writes followed by Phase 4 new reads, while another required same-cutover semantics.

Verify the current design now means:

- schema/backfill first;
- deploy new reader + command adapter inactive;
- pre-cutover reconciliation;
- **activate one aggregate's canonical reader + writer atomically**;
- only then allow first new-only semantic state.

Check at least Request, task actual, shopping, DailyBrief, and Family Event.

No production interval may allow new-only write semantics with a legacy current-truth UI/read path.

## 6. HIGH-3 — test scope on domain state, not only delivery

Verify the design now requires direct `test_context_id` on the test-capable canonical business rows identified in `08`, including at least:

- task_instances
- task_actual_participants
- task_reconciliation_sessions
- task_reconciliation_session_items
- handovers
- Requests/Attempts/Confirmations
- shopping item/claim/participant state
- family event/candidate/source rows created in simulation

The earlier relaxed rule “test_context_id **or derive from a parent**” must no longer be enough for the core rows named above.

Verify production ordinary reads are server-filtered to non-test by default for:

- DailyBrief/Today
- scheduled morning/evening dispatch
- Requests
- History/analytics
- handover/share
- shopping
- events/prep
- recurrence/materialization inputs where leakage could produce real work

Verify production outbox/Google write/real consent remain fail-closed.

Mandatory E2E:

simulated mama receives/accepts a Request, becomes assignee/claimant/performer, group reconciliation runs, and **none** of those rows appear in ordinary production Today, next morning LINE, History count, Google write, or real spouse consent.

## 7. HIGH-4 — 46-table disposition completeness

Review the full public 26 / private 20 table inventory in `08`.

Pay particular attention to tables previously omitted from the design discussion:

- `household_routine_schedules`
- `assignment_change_request_tasks` + `requests.assignment_scope`
- `private.pending_actions`
- `notification_preferences`
- `evening_routine_preferences`
- `private.raw_inputs`
- `private.scheduled_dispatch_receipts`

For every current table, verify the disposition (`KEEP / EVOLVE / SUPERSEDE / OUT-OF-SCOPE`) is consistent with the new canonical truth and does not allow a hidden second writer/state machine.

`assignment_change_request_tasks` must not remain an independent competing assignment-negotiation truth after the new Request/Attempt cutover.

## 8. HIGH-5 — Shopping connection to `誰でもOK`, actual, and duplicate safety

Previous problem:

`shopping_items` was an existing independent aggregate, but the new design's claim/participant/duplicate-sensitive UX was only modeled for Task.

Verify the current design explicitly keeps shopping separate and evolves it with:

- assignment mode
- assignee ActorRef compatibility
- anyone claim / release / takeover
- revision/concurrency
- participant/recorder history
- duplicate sensitivity
- direct test context
- neutral `対応済み` behavior when purchase/order completion changes partner action

Check the exact UX:

`牛乳を買う / 誰でもOK -> 自分がやる -> claimed -> purchase -> partner sees neutral handled state`.

Also check correction/undo: a previously neutral handled item restored to actionable state produces a neutral correction when needed, rather than leaving the partner with stale “対応済み” belief.

## 9. HIGH-6 — DailyBrief schedule persistence and one-day override

CURRENT `household_routine_schedules` has the old fixed schedule-kind CHECK.

Verify the design now provides an executable persistence path for:

- weekday morning brief 06:30
- weekend/JP-holiday morning brief 09:00
- evening brief 20:30
- household setting changes
- date-specific one-day time/disable override

Verify the physical path includes:

- CHECK evolution/new brief kinds in `household_routine_schedules`;
- explicit disposition of the old nine kinds;
- date-specific override persistence;
- `notification_preferences` mapping;
- `private.scheduled_dispatch_receipts`/dispatcher dedup path;
- current `apps/web/src/features/settings/RoutineSchedule.tsx` and `update-routine-schedule` path being evolved rather than ignored.

After cadence cutover, old checklist/check-in schedules must not continue generating normal-day extra pushes that violate the two-anchor UX.

## 10. HIGH-7 — all-day event display versus conflict exclusion

Fresh-read the current queries that use `all_day_start is null`.

Verify the design separates:

- **display**: relevant all-day Family Event/Google occurrence must appear in DailyBrief/PWA schedule;
- **conflict**: all-day remains excluded from timed person-specific assignment conflict under current requirements.

Mandatory scenarios:

1. nursery/Codmon intake creates an all-day school event -> relevant morning brief shows it;
2. direct Google all-day event -> DailyBrief shows it;
3. the same all-day event does not create a false timed assignment-conflict warning.

If the new DailyBrief display still reuses the old `all_day_start is null` filter, this remains HIGH.

## 11. MEDIUM closure — implementation-defining items

### 11.1 Task outcome/disposition storage

Verify current representation distinguishes:

- unknown/unentered
- could not do
- not needed this occurrence
- cancelled
- replanned

without audit-event replay as the only current source.

Legacy unknown skipped reason must not be guessed.

### 11.2 Compatibility-primary performer

Verify multi-performer whole completion has an exact deterministic temporary legacy mirror rule, and that it is never exposed as a contribution ranking.

### 11.3 Consulting proposer confirmation

Verify:

- an actor explicitly proposing exact terms is atomically considered confirmed for that revision;
- the other actor must confirm;
- an AI/system-generated synthesis implies zero confirmations unless the humans explicitly confirm;
- any terms edit changes revision and invalidates old confirmations.

## 12. Regression re-check — earlier detailed-design HIGH 3

Report `PASS / PARTIAL / FAIL` again for:

1. Task `待ち` current truth
2. simulated actor persistence identity
3. post-P1 rollback/feature-off safety

The new physical alignment must not regress these.

## 13. Requirements Final-GO MEDIUM 3

Report `PASS / PARTIAL / FAIL`:

1. `大体やった` + carryover UX noise
2. duplicate-sensitive neutral completion notification
3. one-user synthetic delivery vs production delivery boundary

The expected target after this remediation is 3/3 PASS, including domain-state isolation for #3 and undo/correction semantics for #2.

## 14. Required output

Start with:

- `GO`
- `GO WITH CONDITIONS`
- or `NO-GO`

Then provide:

- BLOCKER/HIGH/MEDIUM/LOW counts
- Section 3 BLOCKER as PASS/PARTIAL/FAIL
- Sections 4–10 HIGH findings individually as PASS/PARTIAL/FAIL
- Sections 11.1–11.3 MEDIUM items individually
- earlier HIGH 3 regression check
- Requirements Final-GO MEDIUM 3
- only genuinely new findings that remain implementation-blocking or materially risky
- concise CURRENT implementation leverage/migration-safety updates where the new physical alignment changes prior conclusions
- final verdict on whether PR #41 may merge and ADR 0013 may become Accepted

## 15. Gate

- Any `BLOCKER` or `HIGH` remaining => **NO GO**.
- A physical migration/read-path ambiguity that forces implementers to invent truth counts as HIGH even if product intent is clear.
- Do not fail the design for exact SQL constraint names, Flex JSON, OCR model, or other implementation details that can be safely decided during implementation review.

The key question is:

**Does the current PR head now align the accepted product/domain design with the actual CURRENT main physical schema closely enough that implementation can begin without inventing migration compatibility, test identity, schedule, shopping, or all-day behavior?**