# Family Ops Purpose-first convergence implementation

Status: **IMPLEMENTATION CHECKPOINT / NOT MERGE-READY**  
Date: 2026-09-19  
Branch: `impl/purpose-first-convergence-20260917`  
Checkpoint HEAD before this status update: `6205298b31f3db7fafae2d5bf06838ae67aeff6e`  
CURRENT main at checkpoint: `789b81ee26a7b370528ad7c16ae8ff50a0c25efb`  
PR: #113 (Draft)  
Astra review source: `review/astra-purpose-ux-20260917@8e1e00e9aa0b8d7c5bae45e4e3bc776bfb5dba14`

## 1. CURRENT / authority

Implementation started from a fresh-read `main=900313187c2460901f91d8aea66051e57729b50b`.
During implementation, CURRENT main advanced via PR #114 to:

`789b81ee26a7b370528ad7c16ae8ff50a0c25efb`

Therefore the implementation branch is no longer based on CURRENT main. Current comparison:

- merge base: `900313187c2460901f91d8aea66051e57729b50b`
- branch: 17 commits ahead of CURRENT main
- branch: 25 commits behind CURRENT main
- status: diverged
- GitHub currently reports PR #113 as mergeable, but it is intentionally still Draft and must be reconciled with CURRENT main before merge-ready judgment.

Authority remains:

1. Accepted ADRs governing the exact architecture decision.
2. `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`.
3. `docs/design/current/`.
4. non-conflicting legacy design.
5. implementation/tests.

Astra review/design is implementation input, not a replacement source of truth.

## 2. Purpose-first findings / current implementation state

| Finding | State at this checkpoint | Main implementation |
|---|---|---|
| PF-01 Quick Add input-first | **implemented, verification incomplete** | `+` opens free input first; old category-first entry moved under secondary “選んで入力” |
| PF-02 confirmed outbound truth | **implemented, verification incomplete** | confirmed payload builder; raw/private `sourceText` is not request-body fallback; request condition edits invalidate message review |
| PF-03 Codmon readiness | **implemented, DB regression failing** | shared readiness projection; DailyBrief/LINE projection; Today submit row shows remaining inputs/assignees and gates normal completion |
| PF-04 bounded wait / unknown outcome | **implemented across primary consumers, verification incomplete** | auth/read/mutation/proposal deadlines; mutation `unknown`; stable operation ID/payload journal; Requests/Today task/Checkin/Shopping/Handover/Nursery/TaskForm consumers connected |
| PF-07 semantic parity | **implemented, verification incomplete** | shared pickup resolver; assignment-change request path retained; expected task revision CAS; subtasks/context/calendar visibility preserved |
| PF-05 PWA AI consultation | **DEFERRED** | PO decision required; not implemented |
| PF-06 Codmon bulk exclusion | **DEFERRED** | PO decision required; bulk semantics intentionally unchanged |

## 3. Key safety/behavior changes now present

### PF-01
- Quick Add no longer requires category choice before typing.
- Concierge heading/CTA are ordinary “追加 / 内容を確認”; no unapproved PWA-consultation scope is introduced.
- Manual task/event/request/shopping/handover/nursery/routine/preparation/actual routes remain reachable as fallback.

### PF-02 / PF-07
- `confirmedCommand.ts` is the normalization boundary used for preview and mutation payload.
- Recipient-facing request body must be explicitly reviewed; raw/private source text is not sent implicitly.
- Title/date/recipient changes advance candidate revision and invalidate stale body review.
- Pickup-change cues resolve to the existing assignment-change domain rather than silently degrading to a generic light request.
- Assignment proposal carries expected task revision and the DB command fails stale rather than applying an old target.
- Parsed preparation subtasks, context, and calendar visibility survive into create-task payloads.
- LINE no longer silently truncates an overlong context-expanded task title; it requests correction instead.

### PF-04
- Common client deadlines:
  - auth: 12s
  - read: 12s
  - mutation: 30s
  - AI proposal: 45s
- Mutation dispatch timeout/network/5xx/malformed-success is treated conservatively as `outcome=unknown`, not “not sent”.
- Stable command attempts are scoped by user/household and preserve the same operation ID and exact payload for retry/recovery.
- Same operation ID with a different payload is rejected.
- Requests cleanup failure after confirmed send is separated from send failure to avoid duplicate request creation.

### PF-03
- `private.fn_codmon_readiness_v1` is the shared readiness source for DailyBrief, LINE text, submit guard, and 09:00 reminder logic.
- States: `not_applicable / data_incomplete / waiting_inputs / ready_to_submit / acknowledged`.
- The existing `codmon_submit` task is retained; no separate provider-submission model is created.
- Today shows remaining Codmon inputs and their assignees inline.
- Final acknowledgement uses the existing complete-task command only after all four required inputs are ready.
- PF-06 bulk eligibility is unchanged.

## 4. CURRENT CI at checkpoint HEAD 6205298b...

### PASS
- Operational safety CI: **PASS**
- Supabase real CLI integration stack: **PASS**
- Edge functions: deno lint / type-check / unit / auth matrix: **PASS**

### FAIL
1. **DB SQL suite**
   - Failing test: `tests/sql/92_codmon_daily_submission.sql`
   - Current failure is in the newly added readiness assertion:
     `initial waiting projection` sees `data_incomplete` with all four input rows missing.
   - The assertion was inserted before this fixture materializes the Codmon occurrences. This must be moved after materialization; CURRENT DB migration application itself and real Supabase integration completed successfully.

2. **Web CI / CF-14 real-browser evidence**
   - Browser run times out waiting for `ブラウザ証拠タスク`.
   - Captured browser evidence showed Today remaining at `読み込み中…`; this is not yet closed.
   - Because CF-14 runs before lint/typecheck/test/build, those later web steps were skipped in the failing run. Web cannot be called GREEN yet.

## 5. Main divergence

CURRENT main advanced after this branch began through PR #114 (“Allow direct anyone actuals and safe completion undo”).

Before continuing implementation or declaring merge-ready, required next step is:

1. fresh-read PR #114/current main changes,
2. reconcile/rebase or merge CURRENT main into this branch without losing either lane,
3. rerun targeted tests,
4. rerun full CI,
5. repair any semantic conflicts rather than resolving mechanically.

The old `90031318...` anchor is now historical only.

## 6. Remaining work before merge-ready

- fix Codmon SQL test placement and rerun DB suite;
- diagnose and fix CF-14/Today loading failure, then obtain web lint/typecheck/test/build results;
- reconcile CURRENT main `789b81ee...` and re-check affected source;
- finish targeted regressions for request edit→actual payload, mixed pickup+shopping, unknown-response recovery, and Codmon UI states;
- update canonical `docs/design/current/` in the same change unit where current design needs clarification;
- complete Purpose → Requirements → CURRENT design → implementation → tests → real-use scenario self-review;
- update PR #113 final report/checklist.

## 7. Explicitly not done

- no production deploy/mutation;
- no main merge;
- no Physical F2;
- no notification to the real wife account;
- no PF-05 or PF-06 requirement change.

## 8. Checkpoint judgment

The work is safely persisted and the material conforming implementation is substantially in place, but **this branch is not merge-ready and must not be described as GREEN**.

The two immediate blockers are:
1. CURRENT main divergence;
2. CI failures in Codmon regression placement and CF-14 browser/Today loading.

This document is the implementation checkpoint. CURRENT GitHub remains authoritative for subsequent continuation.
