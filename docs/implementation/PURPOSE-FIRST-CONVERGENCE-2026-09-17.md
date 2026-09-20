# Family Ops Purpose-first convergence implementation

Status: **FINAL CLOSURE / MERGE-READY SUBJECT TO FINAL DOCUMENTATION-HEAD CI**  
Date: 2026-09-20  
Target branch: `impl/purpose-first-convergence-20260917`  
PR: #113  
CURRENT main reconciled: `6f8d901d8bac7ddf14673f0e061860da0d00b59f`  
Verified implementation HEAD before this documentation-only closure update: `4afda982041d1c83b670a1e552d6a518e8cfe620`  
Astra review source: `review/astra-purpose-ux-20260917@8e1e00e9aa0b8d7c5bae45e4e3bc776bfb5dba14`

> The exact SHA containing this report is intentionally recorded in PR #113 rather than embedded here: changing this file changes that SHA. This report records the verified implementation baseline and the final closure criteria; PR #113 is the authoritative exact-head/CI record.

## 1. Authority and CURRENT reconciliation

Authority used for the final convergence:

1. accepted ADRs;
2. `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`;
3. `docs/design/current/`;
4. non-conflicting legacy design;
5. implementation/tests.

Astra review/proposed design were treated as input, not as higher authority than canonical requirements/current design.

CURRENT main `6f8d901d...` was reconciled into the convergence line before final verification. The main-side reopen correction was preserved by folding whole-task reopen into the existing `complete-task` Edge Function with `action=reopen`, while retaining Purpose-first stable command recovery. The reconciled candidate is behind CURRENT main by zero commits.

Main-derived UX preserved:

- anyone work can be completed / checked without first pressing claim;
- claim label remains `自分がやる`, not `予約する`;
- whole-task completion can be reopened from the completed surface;
- completed checklist subtasks can be corrected;
- completed-today correction behavior remains present.

## 2. Purpose-first finding closure

| Finding | Final state | Evidence / implementation |
|---|---|---|
| PF-01 Quick Add category-first friction | **IMPLEMENTED** | primary `＋追加` opens free-text Concierge directly; category/manual routes remain secondary |
| PF-02 outbound request truth | **IMPLEMENTED** | recipient payload is built only from reviewed `sharedMessage`; private/raw `sourceText` is never a request-body fallback; request review is revision-bound |
| PF-03 Codmon readiness clarity | **IMPLEMENTED** | shared readiness projection distinguishes incomplete/waiting/ready/acknowledged; Today explains remaining input and uses `コドモンで送信した` only after external submission |
| PF-04 bounded wait / unknown recovery | **IMPLEMENTED** | finite deadlines; `not_sent / rejected / unknown`; stable logical operation; same endpoint/payload/operation_id retry; user+household scope; 24h resume; memory fallback |
| PF-07 mixed pickup semantic parity | **IMPLEMENTED** | unique current pickup resolution; expected task revision; fail-closed ambiguity/stale handling; task context/subtasks/calendar visibility retained in candidate creation |
| PF-05 PWA AI consultation response | **DEFERRED** | intentional PO decision; not treated as a defect |
| PF-06 Codmon generic bulk-completion exclusion | **DEFERRED** | intentional PO decision; bulk semantics not silently changed |

## 3. CF-14 root cause and closure

CF-14 is closed.

The real product defect was in Edge Function request policy lookup:

- callers use deployed kebab-case function names such as `list-pending-actions` and `complete-task`;
- the request-policy source was keyed by camelCase property names;
- policy lookup therefore returned `undefined`;
- the effective request deadline collapsed to immediate abort;
- Chrome surfaced `net::ERR_ABORTED` even though the local mock server had received and completed the request.

Fix:

- build a deployed-name -> policy map from `EDGE_FUNCTIONS`;
- lock the mapping with regression tests;
- retain existing timeout/unknown semantics.

The CF-14 harness was also aligned to the CURRENT Today initial-error wording without weakening the scenario.

Final CF-14 evidence proves:

1. Today loading;
2. Today ready;
3. Quick Add -> Concierge -> Back draft persistence;
4. real task completion mutation succeeds;
5. subsequent canonical Today read fails;
6. prior successful snapshot remains visible;
7. stale warning is rendered;
8. initial Today read error is separately rendered;
9. request sender consultation remains covered.

The product stale semantic was not weakened.

## 4. Recovery and privacy closure

The client recovery model conforms to current design:

- auth/read/mutation/proposal waits are bounded;
- mutation dispatch uncertainty becomes `unknown`, not `not_sent`;
- `unknown` attempts are persisted;
- retries reuse the same logical operation, endpoint, exact normalized payload and `operation_id`;
- same operation ID with a changed payload is rejected as `IDEMPOTENCY_CONFLICT`;
- recovery links are scoped by user + household;
- automatic resume expires after 24 hours;
- session-storage failure falls back to in-tab memory rather than silently minting another operation ID.

Concierge draft storage is likewise user+household scoped; the old unscoped draft is not silently adopted across identities.

## 5. Request truth / semantic parity closure

Request confirmation is revision-bound:

- `requestMessageIsReviewed()` requires non-empty reviewed `sharedMessage`;
- `messageReviewedRevision` must equal current `candidateRevision`;
- changing title/date/message increments candidate revision as appropriate;
- changing request conditions without re-review blocks registration;
- recipient-facing mutation payload uses `shared_message: sharedMessage`;
- private/raw `sourceText` is display-only for the author and is not a recipient mutation fallback.

Pickup assignment-change resolution is fail-closed:

- target date is required;
- recipient must resolve uniquely;
- exactly one current open pickup task must exist;
- task must still be assigned to the actor;
- task must not already be assigned to the requested recipient;
- reviewed proposal carries exact task revision;
- DB v2 transaction rejects stale revision/ownership/state with `ASSIGNMENT_PROPOSAL_STALE`.

Task candidates preserve structured semantics:

- context can be included in task title;
- subtasks are retained and set completion mode;
- calendar visibility is retained;
- assignment remains revision-safe.

## 6. Codmon closure

Codmon remains coordination-only; Family Ops does not claim provider submission.

CURRENT behavior:

- `data_incomplete`: input state cannot be trusted;
- `waiting_inputs`: remaining inputs are shown;
- `ready_to_submit`: UI says inputs are ready and instructs the user to send in Codmon first;
- CTA is `コドモンで送信した`;
- `acknowledged`: records that the user confirmed external submission.

The DB boundary still prevents the final Codmon submit task from completing while required input tasks are incomplete.

PF-06 remains intentionally deferred; no silent product-policy change was made.

## 7. Today stale-state closure

After at least one successful Today snapshot, a later refresh/read failure sets status to `stale` while preserving the existing snapshot.

User-facing warning:

`通信が不安定なため、最後に取得できた内容を表示しています。`

An initial read failure remains a separate error state. CF-14 browser evidence and focused unit tests cover this distinction.

## 8. CURRENT main reopen reconciliation

CURRENT main's correction path is preserved without reintroducing a standalone Edge endpoint:

- UI uses `EDGE_FUNCTIONS.reopenTask`;
- that alias points to deployed `complete-task`;
- payload includes `action: 'reopen'` and `expected_revision`;
- `complete-task` dispatches reopen to `server_tx_reopen_task`;
- standalone `reopen-task` function/config/auth allowlist entry is removed;
- mutation-contract/auth documentation is aligned.

This preserves the user requirement that accidental completion can be undone while avoiding duplicate Edge surface area.

## 9. Verification result at implementation HEAD `4afda982...`

### CI #1309 — **SUCCESS**

- DB migrations / RLS / RPC / idempotency / quota: **PASS**
- Supabase integration, real CLI stack: **PASS**
- Edge Functions Deno lint / typecheck / unit auth helpers / auth-matrix lint: **PASS**
- Web CF-14 authoring self-test: **PASS**
- Web CF-14 real-browser authoring E2E: **PASS**
- Web lint: **PASS**
- Web typecheck: **PASS**
- Web unit tests: **211 / 211 PASS**
- Web build: **PASS**

### Independent workflow evidence

- Operational Safety CI #404: **SUCCESS**
- Today Navigation Evidence #221: **SUCCESS**

The final documentation-only closure commit must retain these results on its own exact HEAD before PR #113 leaves Draft. The exact final SHA and final run numbers are recorded in PR #113.

## 10. Final Purpose -> Requirements -> Design -> Implementation -> Tests -> household UX self-review

| Check | Result |
|---|---|
| Quick Add is free-text first | **PASS** |
| private source text cannot become recipient request body | **PASS** |
| request condition edits invalidate stale message review | **PASS** |
| uncertain mutation is not blindly duplicated | **PASS** |
| retry keeps operation_id and exact payload | **PASS** |
| Codmon readiness is understandable in Today | **PASS** |
| UI does not imply Family Ops submitted to Codmon | **PASS** |
| pickup assignment change is revision-safe | **PASS** |
| subtasks/context/calendar visibility are preserved | **PASS** |
| stale Today keeps the previous successful snapshot | **PASS** |
| main-derived direct actuals / reopen correction remain | **PASS** |
| label remains `自分がやる`; no regression to `予約する` | **PASS** |

No unresolved implementation blocker was found in the final self-review.

## 11. Deliberate non-goals / remaining decisions

These are not implementation defects in this convergence:

- PF-05 PWA AI consultation response — PO decision required;
- PF-06 Codmon final-submit exclusion from generic bulk completion — PO decision required.

They remain explicitly deferred.

## 12. Release boundary

This convergence does **not** authorize or perform:

- merge of PR #113 into main;
- production deployment;
- production mutation;
- Physical F2;
- notification to the real wife LINE account.

Those require separate explicit instruction/evidence.

## 13. Final judgment

The Purpose-first convergence implementation is functionally complete against the accepted/current scope.

At verified implementation HEAD `4afda982...` all implementation gates are GREEN, CURRENT main is reconciled, CF-14 is closed, and the final cross-layer self-review is PASS.

After the documentation-only closure HEAD itself is confirmed GREEN, PR #113 may be marked **Ready for review / merge-ready**. It must still **not** be merged to main without explicit user instruction.
