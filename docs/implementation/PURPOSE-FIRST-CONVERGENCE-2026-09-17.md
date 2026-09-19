# Family Ops Purpose-first convergence implementation

Status: **CHECKPOINT / NOT MERGE-READY**  
Date: 2026-09-20 07:14 JST  
Branch: `impl/purpose-first-convergence-20260917`  
Code HEAD before this checkpoint document: `987ff61cc9b91b750cc511cefecbdd9258c04c25`  
CURRENT main: `371164f90d602108858f299ffb47f671e8ed4e27`  
PR: #113 (Draft)  
Astra review source: `review/astra-purpose-ux-20260917@8e1e00e9aa0b8d7c5bae45e4e3bc776bfb5dba14`

## 1. CURRENT alignment

CURRENT main was fresh-read and merged into this implementation branch through synchronization PR #117.

Current comparison at this checkpoint:

- branch is **ahead of CURRENT main**
- ahead: 52 commits
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

## 4. Verification at code HEAD 987ff61c...

### PASS
- Operational safety CI: **PASS**
- Today Navigation Evidence, real Chrome mobile viewport: **PASS**
- DB migrations / RLS / RPC / idempotency / quota: **PASS**
- Supabase integration, real CLI stack: **PASS**
- Edge functions lint/check/auth matrix: **PASS**

### Remaining FAIL
- Exact code HEAD CI #1295 fails only in the web job at the early **CF-14 real-browser authoring E2E** step.
- On the same HEAD, DB, Supabase real CLI integration, Edge checks, Operational Safety CI, and Today Navigation Evidence are PASS.
- The harness has been moved off CDP response interception and through a real local HTTP/same-origin gateway. The `complete-task` POST now reaches that gateway, so the earlier preflight/CDP ambiguity is closed.
- Chrome still reports `net::ERR_ABORTED` for that mutation response, so the expected post-mutation stale-state assertion is not reached. The next debugging boundary is the mock response/request-stream handling around that POST, not the Today stale-state product semantics.
- `useTodayData` already has a focused regression proving **successful snapshot -> failed refresh -> stale while retaining the last good snapshot**.
- Because CF-14 runs before the ordinary web lint/typecheck/unit/build stages, those later stages still lack exact-head final evidence.

## 5. Important defects closed

- old main divergence: **closed**
- Codmon SQL placement failure: **closed**
- app-wide Vite/AuthenticatedApp dynamic-import failure: **closed**
- Today real-browser navigation evidence failure: **closed**
- unscoped Concierge draft privacy gap: **closed**
- new PR #114 reopen/evidence operations bypassing PF-04 stable attempts: **closed**
- Today direct assignment resolution bypassing PF-04 stable attempts/CAS: **closed**

## 6. Progress estimate

**Overall convergence progress: 90%.**

Basis for this estimate:

- purpose-first implementation findings PF-01 / PF-02 / PF-03 / PF-04 / PF-07 are implemented;
- PF-05 / PF-06 remain intentionally deferred pending PO decisions and are not counted as defects;
- CURRENT main is reconciled (behind 0);
- DB, real Supabase integration, Edge, Operational Safety, and Today Navigation evidence are green;
- canonical design updates for command recovery, Today stale behavior, Codmon readiness, and recovery evidence are incorporated;
- the remaining merge-readiness blocker is CF-14 browser authoring evidence plus the downstream exact-head web lint/typecheck/unit/build run and final self-review.

This percentage is a work-completion estimate, not a CI pass score and not a production/F2 GO declaration.

## 7. Remaining work before merge-ready

1. fix the CF-14 browser harness interception race without weakening product behavior;
2. rerun CF-14 and then obtain web lint/typecheck/test/build on the exact same HEAD;
3. finish targeted regressions for request edit -> confirmed payload, mixed shopping + pickup assignment change, unknown-response recovery, and Codmon UI states where not already covered;
4. update the relevant `docs/design/current/` clauses for the implemented recovery/readiness details where clarification is still missing;
5. complete the final Purpose -> Requirements -> CURRENT design -> implementation -> tests -> real-use scenario review;
6. update PR #113 body/checklist and only remove Draft if the exact final HEAD is fully GREEN.

## 8. Explicitly not done

- no production deployment or production mutation
- no merge of PR #113 to main
- no Physical F2
- no notification to the real wife account
- no PF-05/PF-06 product decision change

## 9. Checkpoint judgment

The implementation is materially further along than the previous checkpoint. Main is reconciled, Codmon DB verification is green, app boot is repaired, Today navigation evidence is green, and PF-04 coverage is broader and safer.

**The branch is still NOT merge-ready / NOT fully GREEN.**

The immediate blocker is now narrowly isolated to CF-14 around the real-browser `complete-task` response boundary. Once that evidence passes, the exact-head web lint/typecheck/unit/build stages and the final cross-product alignment review remain before PR #113 can be considered merge-ready.
