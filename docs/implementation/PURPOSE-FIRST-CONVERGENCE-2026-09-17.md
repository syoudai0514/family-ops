# Family Ops Purpose-first convergence implementation

Status: **CHECKPOINT / NOT MERGE-READY**  
Date: 2026-09-19 19:58 JST  
Branch: `impl/purpose-first-convergence-20260917`  
Code HEAD before this checkpoint document: `3f340fbc3d2344f7fdae13cc7ae99d81ea813c3c`  
CURRENT main: `371164f90d602108858f299ffb47f671e8ed4e27`  
PR: #113 (Draft)  
Astra review source: `review/astra-purpose-ux-20260917@8e1e00e9aa0b8d7c5bae45e4e3bc776bfb5dba14`

## 1. CURRENT alignment

CURRENT main was fresh-read and merged into this implementation branch through synchronization PR #117.

Current comparison at this checkpoint:

- branch is **ahead of CURRENT main**
- ahead: 34 commits
- behind: 0
- PR #113 remains Draft
- GitHub reports the PR as mergeable, but it is not yet merge-ready because one required browser evidence lane is still failing

The previous main-divergence blocker is therefore closed.

## 2. Purpose-first findings

| Finding | Current state | Main implementation |
|---|---|---|
| PF-01 Quick Add input-first | **implemented** | canonical + opens free-input Concierge first; manual category routes remain secondary |
| PF-02 confirmed outbound truth | **implemented; final verification pending** | reviewed recipient message is the mutation source; raw/private source text is not an implicit request body; condition edits invalidate stale review |
| PF-03 Codmon readiness | **implemented; DB verification PASS** | shared readiness projection feeds DailyBrief/LINE/guard/09:00 reminder; Today gates final submit and shows remaining inputs |
| PF-04 bounded wait / unknown outcome | **implemented across required primary consumers; final verification pending** | deadlines, conservative unknown outcome, scoped stable command journal, same operation ID + exact payload recovery |
| PF-07 semantic parity | **implemented; final verification pending** | mixed pickup intent uses assignment-change path with revision CAS; subtasks/context/calendar visibility retained |
| PF-05 PWA AI consultation | **DEFERRED** | PO decision required |
| PF-06 Codmon bulk exclusion | **DEFERRED** | PO decision required; bulk semantics intentionally unchanged |

## 3. Material fixes completed after the previous checkpoint

### CURRENT main reconciliation
- merged CURRENT main through `371164f90d602108858f299ffb47f671e8ed4e27` into the implementation branch
- preserved PR #114 behavior: direct anyone actuals, completion undo, completed-today correction surface
- kept the approved label `自分がやる`

### Codmon
- fixed the regression test itself: readiness assertion now runs after daily occurrence materialization, not immediately after recurrence seeding
- DB SQL suite is GREEN again
- real Supabase CLI stack is GREEN

### Browser/app boot defect
- diagnosed the prior Today loading failure to a Vite 500 on `ConciergeResultsPage.tsx`
- root cause was three literal `\\n` tokens accidentally embedded in TSX source
- restored actual newlines
- Today Navigation real-Chrome evidence now PASS

### PF-04 recovery/privacy
- Concierge draft storage is now scoped by household + user
- old unscoped draft is not adopted and is cleared, preventing same-browser cross-user draft leakage
- `reopen-task` is classified as a mutation and uses stable command-attempt recovery
- task completion evidence uses the same recovery path
- Today unresolved-assignment actions now use stable command attempts
- partner assignment-change requests carry `expected_task_revision`
- backend review confirmed the principal mutation endpoints pass `operation_id` into canonical server transaction/RPC boundaries

## 4. Verification at code HEAD 3f340fbc...

### PASS
- Operational safety CI: **PASS**
- Today Navigation Evidence, real Chrome mobile viewport: **PASS**
- DB migrations / RLS / RPC / idempotency / quota: **PASS**
- Supabase integration, real CLI stack: **PASS**
- Edge functions lint/check/auth matrix: **PASS**

### Remaining FAIL
- Web job fails only at the early **CF-14 real-browser authoring E2E** step.
- Because that step precedes normal web lint/typecheck/test/build, the later web stages are not yet final evidence for this HEAD.
- Current CF-14 failure occurs after Today renders successfully and after the canonical task is visible.
- The failure log contains `Fetch.fulfillRequest: Invalid InterceptionId` around the mocked `complete-task` boundary. The expected post-mutation stale-state assertion is therefore not reached correctly.
- `useTodayData` already has a focused regression proving **successful snapshot -> failed refresh -> stale while retaining the last good snapshot**. Current evidence points to the browser harness interception race, not a need to weaken product stale semantics.

## 5. Important defects closed

- old main divergence: **closed**
- Codmon SQL placement failure: **closed**
- app-wide Vite/AuthenticatedApp dynamic-import failure: **closed**
- Today real-browser navigation evidence failure: **closed**
- unscoped Concierge draft privacy gap: **closed**
- new PR #114 reopen/evidence operations bypassing PF-04 stable attempts: **closed**
- Today direct assignment resolution bypassing PF-04 stable attempts/CAS: **closed**

## 6. Remaining work before merge-ready

1. fix the CF-14 browser harness interception race without weakening product behavior;
2. rerun CF-14 and then obtain web lint/typecheck/test/build on the exact same HEAD;
3. finish targeted regressions for request edit -> confirmed payload, mixed shopping + pickup assignment change, unknown-response recovery, and Codmon UI states where not already covered;
4. update the relevant `docs/design/current/` clauses for the implemented recovery/readiness details where clarification is still missing;
5. complete the final Purpose -> Requirements -> CURRENT design -> implementation -> tests -> real-use scenario review;
6. update PR #113 body/checklist and only remove Draft if the exact final HEAD is fully GREEN.

## 7. Explicitly not done

- no production deployment or production mutation
- no merge of PR #113 to main
- no Physical F2
- no notification to the real wife account
- no PF-05/PF-06 product decision change

## 8. Checkpoint judgment

The implementation is materially further along than the previous checkpoint. Main is reconciled, Codmon DB verification is green, app boot is repaired, Today navigation evidence is green, and PF-04 coverage is broader and safer.

**The branch is still NOT merge-ready / NOT fully GREEN.**

The immediate blocker is now narrowly isolated to the CF-14 browser evidence harness around the mocked post-mutation boundary. After that is repaired, the exact-head web lint/typecheck/test/build and final cross-product alignment review are still required.
