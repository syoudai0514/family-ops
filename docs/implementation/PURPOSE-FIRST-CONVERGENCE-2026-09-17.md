# Family Ops Purpose-first convergence implementation

Status: IMPLEMENTATION IN PROGRESS  
Date: 2026-09-17  
Branch: `impl/purpose-first-convergence-20260917`  
CURRENT main anchor: `900313187c2460901f91d8aea66051e57729b50b`  
Astra review source: `review/astra-purpose-ux-20260917@8e1e00e9aa0b8d7c5bae45e4e3bc776bfb5dba14`

## 1. Fresh-read authority result

Implementation began by fresh-reading CURRENT GitHub rather than treating the handoff anchor as truth. At start of this work, `main` was still exactly `900313187c2460901f91d8aea66051e57729b50b`; the Astra review branch was still exactly `8e1e00e9aa0b8d7c5bae45e4e3bc776bfb5dba14`.

Authority follows Accepted ADR 0012/0013:

1. accepted ADR governing the exact architecture decision;
2. `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md` for requirements/UX;
3. `docs/design/current/` for current detailed design;
4. non-conflicting legacy design;
5. implementation/tests.

No `AGENTS.md` or `START-HERE` exists in the CURRENT tree. The Requirements README confirms that the main-branch Baseline is the requirements/UX source of truth even where stale metadata/header text describes a review candidate.

## 2. Purpose and acceptance rule

The implementation is judged by reducing household memory, classification, reconfirmation, and “did it send?” burden, not by feature count or CI alone. Completion must align:

`Purpose -> Requirements -> CURRENT design -> implementation -> tests/evidence -> real-use scenario`.

Physical F2 is explicitly outside this branch task and must be rerun later against the final merged exact HEAD.

## 3. CURRENT finding mapping

| Finding | CURRENT evidence | Requirement/design mapping | Classification | This branch |
|---|---|---|---|---|
| PF-01 | `QuickAdd.tsx` still opens a ten-choice modal before free input; `ConciergePage` still presents “AIで整理” as a separate mechanism | Baseline Q70/Q73/Q74; UX principle “normal case shortest” | conforming UX fix | IMPLEMENT |
| PF-02 | `ConciergeResultsPage.saveEdit` updates title/date but not `sharedMessage`; `ConciergeConfirmPage` does not show the actual outbound body/recipient/time; `conciergeCommit.ts` falls back to raw `sourceText` for request body | human-confirmed authority, Q70/Q71, Request safety | implementation defect / P0 | IMPLEMENT |
| PF-03 | Q113 guard exists, but Today/Task rendering does not expose the same four-input readiness and remaining owner inline; reminder and submit readiness can diverge on missing rows | Baseline Q113; `12_CODMON_DAILY_SUBMISSION.md` | conforming UX/consistency fix | IMPLEMENT |
| PF-04 | `apiClient.callEdgeFunction` has no deadline for auth, fetch, or body read; mutation callers cannot distinguish “not sent” from “outcome unknown” | recovery/idempotency/current design; operation receipts | implementation defect | IMPLEMENT |
| PF-07 | shared LINE parser already has subtasks/context/calendarVisibility, but PWA `conciergeFlow.ts` drops those fields and `conciergeCommit.ts` forces `completion_mode=whole` and `calendar_visibility=hidden`; generic PWA request path does not preserve existing pickup assignment-change semantics | Request agreement vs linked Task execution, assignment safety, Q70/Q71 | implementation defect | IMPLEMENT |
| PF-05 | Astra proposes PWA consultation response | no PO approval in CURRENT canonical or this session | product proposal | **DEFERRED / DO NOT IMPLEMENT** |
| PF-06 | Astra proposes excluding Codmon final send from generic bulk completion | current Q113 does not authorize that exception; no PO approval | product proposal | **DEFERRED / DO NOT IMPLEMENT** |

## 4. Implementation decision

Astra’s PF-01/02/03/04/07 design is materially compatible with CURRENT Requirements and Accepted ADRs. It is used as an implementation design, not as a second source of truth. No new product scope is required.

Implementation order:

- **S1:** PF-07 semantic parity + PF-02 confirmed outbound truth + PF-01 input-first Add.
- **S2:** PF-04 bounded API waits + stable command-attempt recovery using the same operation ID/payload.
- **S3:** PF-03 shared Codmon readiness + inline Today/LINE clarity, without changing PF-06 bulk semantics.
- **Final:** targeted/full CI, five-perspective self-review, canonical design/evidence update, PR merge-ready.

## 5. Non-negotiable boundaries

- Request creation/consultation does not change assignment; accepted linked Task remains execution truth.
- Existing pickup assignment change must not silently degrade into a new light request.
- Raw/private user input must never be an implicit recipient-facing request body.
- Preview and mutation are produced from the same confirmed payload.
- Unknown network outcome is not reported as “not sent”; retry reuses the same operation identity and payload.
- Codmon remains input/send acknowledgement only: no provider auto-submit and no duplicate storage of meal/health text.
- Codmon readiness is the fixed four required input codes, same household/date/test context, row present and completed.
- No extra push notifications, no quota relaxation, no score dashboard.
- Existing migrations are immutable; any schema/RPC addition is a new additive migration.
- No production mutation/deploy, main merge, real-wife notification, or Physical F2 in this task.

## 6. Evidence status at checkpoint S0

Fresh source confirms PF-01, PF-02, PF-04, and the field-loss portion of PF-07 remain present at CURRENT main. Existing tests currently encode the old QuickAdd ten-option-first behavior and do not exercise the Results edit -> exact transported request body integration, so those expectations must be changed rather than treated as proof of correctness.

NEXT ACTION: implement S1 on this branch, add regression coverage for the Tuesday->Wednesday/body mismatch and preparation subtask preservation, then push the S1 exact HEAD before moving to bounded-network recovery.
