# Family Ops / おうちノート
# NEW F2 EXECUTION OWNER HANDOFF — 2026-09-11

## 0. Role

You are the **new physical F2 execution owner**.

Do not restart product review from scratch and do not treat older screenshots as exact-head PASS.

First receive the frozen exact HEAD from the control tower, then fresh-read:

1. canonical Requirements;
2. Appendix A;
3. current design 04 / 09 / 11;
4. CF14 evidence matrix;
5. CURRENT source/schema for the frozen HEAD.

Do not accept the handoff until the control tower explicitly confirms that the production Supabase runtime has been reconciled with CURRENT main, including the transport dependency migration required by Baseline §28.6 / current design 09 §9.2. PR merge and GREEN CI alone are not deployment evidence.

## 1. Primary success order

Judge in this order:

1. Family Ops purpose achieved in real family use.
2. Canonical Requirements satisfied.
3. Approved UX / current design satisfied.
4. Real iPhone/Android/LINE/PWA experience is understandable and operable.
5. Implementation and technical evidence are correct.

CI GREEN is necessary where applicable but never sufficient by itself.

## 2. Available physical topology

The F2 environment now supports a real two-party flow:

- requester: papa real LINE on iPhone;
- recipient: separate mama test LINE on Android;
- mama test PWA: Android PWA using the mama test member account;
- both members are in the same F2 household.

Use the mama test identity only; do not notify the real spouse.

One-user simulation remains available as supplementary isolation/safety evidence but is not final proof for two-party Request/assignment behavior.

## 3. First scenario to rerun on the frozen exact HEAD

Start with the scenario that most recently exposed a product defect **only after the control tower confirms the pending transport-dependency production migration is actually applied**.

### Scenario: one-off pickup assignment change

Requester LINE:

`今日のお迎えお願いできる？`

Expected requester behavior:

1. canonical assignment-change confirmation appears;
2. date/time and scope are visible;
3. requester confirms send.

Expected recipient LINE behavior:

1. real notification arrives;
2. actionable card is present;
3. first tier includes `やる / 難しい / その他の返答`;
4. recipient presses `やる`;
5. stale/revision guards remain active.

Expected canonical result:

- Request attempt = accepted.
- Today pickup occurrence moves to recipient.
- Same-day open/unprotected `pickup_assignee` tasks automatically move to the new pickup actor.
- Same-day unique `nonpickup_adult` tasks flip to the other adult.
- Protected agreement/override/fixed/claimed/terminal tasks do not change.
- Recurrence strategy and future dates do not change.
- Sender gets the final request update through normal notification behavior.
- PWA Today reflects the same assignments.

Capture provider event IDs / postbacks / canonical readback / physical screenshots against the **same exact HEAD**.

Do not use the historical 2026-09-11 accepted request as final proof: it was the defect-discovery run. At the corrected handoff snapshot, the dependency-reconcile implementation was merged and GREEN but its production migration had not yet been applied; any later operational repair/backfill is production-consistency work, not final F2 evidence.

## 4. Next high-value physical scenarios

After the pickup scenario passes, continue one operation at a time.

### LINE natural conversation

Verify on final HEAD:

- `今日なんか予定あったっけ？` produces no task/request draft;
- natural question returns light conversational acknowledgement then canonical detail;
- literal `今日` stays compact;
- correction such as `ちがうよ、今日の予定教えて` returns to read-only behavior and does not leave a mutation draft.

### Same-start transport template edit

In PWA settings:

- edit the current/future weekly transport pattern;
- save with the same start date;
- verify success rather than internal error;
- verify one template period only;
- verify changed weekday values;
- verify protected individual occurrence is not overwritten.

### LINE linking success UX

If a safe fresh link/relink test identity is available:

- issue link token;
- send it from the intended LINE;
- verify explicit “link complete” response and short usage guide.

Do not disrupt already working production test links solely to obtain this evidence unless the control tower approves the setup.

## 5. Remaining CF14 classes to close

Use the current CF14 manifest/evidence matrix rather than this list as the machine-readable source, but expect remaining exact-head work to include:

- current-head LINE daily/Today behavior;
- Q70 raw multi-intent;
- Q71 ambiguity-only clarification;
- Request lifecycle / assignment responses;
- physical iPhone/PWA;
- Android recipient PWA where useful;
- Nursery Q89-Q106 actual image → classify/OCR/AI/review/provenance;
- Google Q110-Q112 against a controlled provider resource;
- actual LINE/PWA concurrency;
- scheduler → LINE delivery evidence for required JST boundaries;
- whole-day scenario;
- strict final CF14 runner payload bound to the frozen exact HEAD.

## 6. Evidence rules

Never claim PASS from:

- DB-only state for a user-entry LINE/provider scenario;
- mocked LINE/Google;
- prebuilt JSON instead of raw natural language;
- OCR-postfixture instead of raw image intake;
- desktop emulation instead of required physical device;
- screenshots/artifacts from another HEAD;
- source-string assertions;
- old evidence manually relabeled to the new SHA.

For each physical step, preserve:

- exact HEAD;
- timestamp/timezone;
- user-visible screenshot/result;
- provider/webhook/postback evidence when relevant;
- canonical state readback;
- expected vs actual.

## 7. Defect handling

If physical F2 exposes a product defect:

1. classify it as IMPLEMENTATION DEFECT vs EVIDENCE/ENVIRONMENT ISSUE;
2. compare Purpose → Requirement → current design → implementation → real-use behavior;
3. do not rationalize a confusing or unusable screen as PASS;
4. fix through a branch/PR;
5. run targeted + full CI;
6. merge/deploy only after GREEN and authorization;
7. freeze a new exact HEAD;
8. mark affected old evidence stale and rerun it.

If the fix changes product meaning, stop and update the Baseline under ADR 0012 before implementing.

## 8. Known OPEN observations to watch

Not yet canonical product changes:

- household role settings layout can visually look reversed although DB roles are correct;
- direct LINE OA launch after token generation is absent because production `LINE_OA_BASIC_ID` is not configured.

Escalate if either blocks a required F2 scenario.

## 9. Safety constraints

- do not notify the real spouse;
- use the mama test identity for recipient evidence;
- no production Google Calendar mutation without explicit authorization;
- use controlled/scratch Google resources;
- do not touch unrelated recovery data/projects;
- no main merge except for an identified fix with required checks/approval;
- do not hide provider or device failures with synthetic PASS evidence.

## 10. Manual interaction protocol

When user action is needed, give **one action only**:

- exact action;
- expected visible result;
- wait for confirmation/screenshot;
- then inspect provider/state evidence before giving the next action.

Avoid long batches of manual instructions.

## 11. Final F2 report

Final report must include:

- frozen exact HEAD;
- production deployment/runtime binding;
- MATCH / PARTIAL / MISSING / F2-PENDING counts;
- Gate A-D status;
- scenario-by-scenario evidence references;
- explicit remaining blockers, if any;
- final F2 PASS / NO-GO;
- no automatic main merge after F2 unless separately instructed.

