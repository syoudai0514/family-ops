# Family Ops / おうちノート
# F2 CONTROL TOWER HANDOFF — 2026-09-12

## 0. Purpose

This is the authoritative continuation handoff for the F2 control tower after the LINE / Gemini natural-language quality convergence work.

Do **not** resume F2 from the older 2026-09-11 handoff mechanically.
Fresh-read CURRENT main after this documentation PR merges, then freeze one exact HEAD.

Authoring anchor before this docs PR:
- main: `edba26a862cd3c5e7995423e7ebebf1a11c57afb`
- PR #95: merged
- PR #95 head: `2d201e3c99e4bddda07b918b863351eae51679d2`
- main CI #1100: SUCCESS 4/4
- Operational Safety #195: SUCCESS
- Vercel production: READY on `edba26a...`

This document intentionally does **not** predeclare the final frozen F2 SHA because merging this docs PR changes main.
The control tower must fresh-read main after merge and freeze that new exact HEAD.

## 1. Authority order

Use, in order:

1. `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`
2. Appendix A Q1-Q112 / Q60-1 / Q60-2
3. `docs/design/current/`
4. accepted ADRs
5. CURRENT GitHub source/schema
6. `docs/implementation/CF14-REQUIREMENT-EVIDENCE-MATRIX.md`
7. physical/device/provider evidence from the same exact HEAD

Old screenshots from another HEAD are defect-discovery history, not final strict PASS evidence.

## 2. AI / natural-language quality work now merged

The live Gemini quality campaign is no longer an unmerged side experiment.

Merged behavior includes:
- partner-facing rewrite preserves the real request/reason while removing blame, sarcasm, scorekeeping and partner assumptions;
- no polite rephrasing of hostility as still-hostile content;
- no model-invented Papa/Mama assignment;
- no daypart -> fabricated concrete clock time;
- shopping commands remain shopping;
- completed purchases can be actual rather than future shopping;
- store/pharmacy visit does not invent a purchase;
- colloquial role correction is preserved;
- comma-only / punctuation-free multi-intent handling is strengthened;
- deterministic fallbacks cover material live failures;
- handover preserves pending next actions, not only state.

Canonical QA record:
- `docs/implementation/AI-NL-ROBUSTNESS-MATRIX.md`

Live Gemini campaign:
- model: `gemini-3.1-flash-lite`
- real family LINE text: **not used**
- synthetic live corpus: 180 cases
- strict baseline: **114/180 = 63.3%**
- converged result: **180/180 = 100%**
- rewrite/handover: 111/111
- single intent: 40/40
- multi-intent: 29/29
- observed 429: 0

This is regression evidence for the defined corpus, not a claim that arbitrary Japanese is solved.

## 3. Current production runtime binding at authoring anchor

Fresh readback before this docs PR:

- `process-line-inbox`: v38 ACTIVE
- `propose-ai-draft`: v13 ACTIVE
- `test-simulation`: v17 ACTIVE, normal JWT-protected test function restored
- `send-notifications`: v26 ACTIVE
- Vercel production: READY on authoring main `edba26a...`

Exact source readback:
- process `_shared/gemini.ts`: matches authoring main
- process `lineIntent.ts`: matches authoring main
- process `lineMultiIntent.ts`: matches authoring main
- process `lineMessageBuilders.ts`: matches authoring main
- process `index.ts`: matches authoring main
- propose-ai-draft index/shared Gemini: matches authoring main
- test-simulation index: matches authoring main

The temporary live-canary replacement of `test-simulation` has been restored. Do not treat the canary runner as production state.

## 4. Queue / safety snapshot

At authoring anchor:

- active notification queue: 0
- active webhook queue: 0
- active pending-action execution: 0
- draft pending actions: 0
- known `test_delivery_outbox` queued rows: 3
- max attempts on those known test rows: 0

Do not clean the three known test-delivery rows merely to make the dashboard look empty.

## 5. Exact pickup scenario precondition for F2 restart

Target task:
- task instance: `ad0ae730-da16-475b-8ce7-11843e9e2885`
- title: お迎え
- scheduled date: 2026-09-14
- due: 18:20 JST
- status: todo
- revision: 3
- assignment source: legacy_snapshot
- planned assignee: Papa production member
- active claimant: none
- open assignment-change requests for this task: 0
- draft pending actions for this task: 0

This is currently a clean restart point.

## 6. First physical F2 scenario after the new exact HEAD is frozen

Use the real Papa LINE on iPhone.

Send exactly:

`仕事でどうしても難しくなりました。9/14のお迎えお願いできる？`

Expected sender preview:
- assignment-change flow, not generic request
- reason preserved in softened form
- target date/time: 9/14 18:20
- scope: 今回だけ
- route: 自分 → パートナー
- no invented facts
- do not press Send until screenshot/readback is captured

Then continue **one physical operation at a time**:
1. sender preview
2. sender Send
3. recipient Mama test LINE card
4. recipient action
5. canonical/provider readback
6. sender result notification
7. PWA Today consistency

Do not bundle multiple physical operations into one instruction.

## 7. Recipient / two-party requirements

Use:
- requester: Papa real LINE / iPhone
- recipient: Mama **test** LINE / Android
- same F2 household
- never notify the real spouse

Recipient assignment-change card must expose:
- target context/date/time
- 今回だけ
- softened message/reason
- explanation that assignment does not change before acceptance
- first tier for assignment change: `引き受ける / 難しい / 相談する`

Before acceptance, canonical task assignment must remain Papa.

After acceptance, verify:
- Request / attempt accepted
- pickup occurrence changes to Mama test
- unprotected same-day `pickup_assignee` dependents re-resolve to Mama test
- unique `nonpickup_adult` dependents re-resolve to Papa
- protected/fixed/agreement/override/claimed/terminal work is unchanged
- recurrence/future dates unchanged
- audit evidence exists
- sender receives explicit accepted outcome
- PWA Today matches canonical state

## 7.1 2026-09-12 physical F2 material UX remediation

The two-account pickup run on frozen HEAD `d123dc5f4a38392c0e5d8d07ffe5df11b10bdbc2` successfully proved the underlying transport/canonical assignment transition, but exposed four material user-facing findings before the scenario could be accepted as final PASS:

1. assignment-change recipient action `やる` did not describe the consequence clearly;
2. one tap accepted and mutated assignment with no final mis-tap guard;
3. `その他の返答` handed assignment consultation to PWA instead of completing the normal consultation path in LINE;
4. requester accepted notification only identified `お迎え`, so concurrent requests could not be distinguished safely.

Product Owner approved remediation on 2026-09-12:
`引き受ける / 難しい / 相談する` for assignment changes, one final accept confirmation, LINE consultation, and context-rich acceptance notifications.

Therefore every pickup-flow physical artifact captured on `d123dc5f...` is **DEFECT-DISCOVERY HISTORY / STALE FOR FINAL PASS** once this remediation merges. After merge/deploy, fresh-read CURRENT main/runtime, freeze the new exact HEAD, restore a clean pickup precondition, and rerun the affected two-party scenario from the actual Papa LINE entry.

## 7.2 2026-09-12 Android PWA transport-role finding

On exact HEAD `3fa849eef535a1e95d9a198ab2d6499e6d73050f`, the two-party 9/21 pickup change correctly reassigned the pickup occurrence and its same-day `pickup_assignee` dependents. Android PWA Today then exposed a separate CURRENT-day defect on 9/12: the transport template has no Saturday pickup/dropoff, but open role-derived routines contained a mixed stale snapshot (some Papa, some unassigned), and `assignment_needed` cards had no usable PWA resolution action.

Classification: **IMPLEMENTATION DEFECT**, separate from the successful 9/21 assignment-change dependency proof.

Approved remediation:
- explicit recurrence fallback assignee for role-derived strategies;
- live transport > explicit fallback > unassigned, never guessed;
- cancellation/unassignment triggers same-day convergence of open unprotected dependents;
- true unassigned Today cards provide direct assignment resolution;
- backfill only where historical transport ownership gives deterministic evidence; do not invent a person where there is no evidence.

Affected PWA/Today evidence is stale after the fix merges and must be recaptured on the new exact HEAD.

## 7.3 2026-09-13 weekend-anyone product refinement

After PR #103 fixed stale/unknown transport-role convergence, Product Owner clarified the actual household rule:

- Saturday/Sunday both adults are normally home;
- if there is no live transport assignee, recurring role-derived work should be `誰でもOK`, not Papa-fixed and not `担当未定`;
- this explicitly includes Shino medication and medication/bowel-record routines that continue on weekends.

Implementation acceptance for the replacement exact HEAD:
- weekend + live transport -> live role assignee still wins;
- weekend + no live transport -> open unprotected role-derived tasks converge to `assignment_mode=anyone`;
- Shino AM/PM medication and AM/PM medication/bowel records follow the same weekend behavior;
- anyone tasks remain visible to both adults before and after claim, with the current claimant visible, and are not `assignment_needed`;
- PWA and LINE support claim/release/takeover without rewriting recurrence; LINE Today exposes the anyone entry contextually and LINE takeover shows the fresh CURRENT claimant before the confirm tap;
- claim is required before PWA execution controls become active;
- weekday fallback behavior remains unchanged.

Affected weekend Today/PWA evidence on PR #103's exact HEAD is stale and must be recaptured after this refinement is merged/deployed.

### 7.3.1 PR #104 convergence notes

Fresh review against the canonical Baseline, CURRENT implementation and regression suite separated fixture drift from genuine product defects.

Fixture-only corrections:
- `90_transport_role_fallback_resolution.sql` had used the runner's current date while asserting weekday fallback semantics; it is now pinned to Monday and weekend semantics are isolated in test 91.
- the isolated test household did not bootstrap the production-specific Shino medication definitions; test 91 now seeds the same semantic AM/PM medication and AM/PM medication/bowel-record definitions explicitly.
- the generic household bootstrap can materialize Saturday transport; test 91 now cancels both Saturday legs before asserting the transport-free weekend rule.

Genuine defects fixed:
- the legacy task-assignment bridge collapsed an explicitly written `assignment_mode=anyone` with no planned person back to `unassigned`; explicit first-class anyone is now preserved while legacy null behavior remains unchanged.
- claimed anyone work could disappear from the other adult's DailyBrief; it now remains visible to both adults with the CURRENT claimant state.
- LINE Today had no contextual entry to the required LINE-completable anyone claim/release flow; `誰でもOKを確認` is now exposed whenever same-day anyone work exists.
- LINE takeover could mutate without first showing who currently held the claim; the first takeover tap now fresh-reads the task and CURRENT claimant and only a second explicit confirm tap can mutate.

Regression coverage now proves all four Shino weekend routines, weekday fallback preservation, live weekend transport precedence, shared visibility before/after claim, claim/release/takeover CAS/audit behavior, PWA claim gating, LINE Today discoverability, and LINE takeover confirmation.

PR #104 remains a review/merge candidate only. No main merge or production mutation is implied by this section.

## 7.4 2026-09-13 Android PWA stale-shell finding

After PR #104 was merged and the exact production backend was aligned to `52cdf25178f3b018d8a217f24c9688acb34a0f97`, authoritative production state showed 9/13 role-derived work as `assignment_mode=anyone` for both adults with `assignment_needed=0`.

Physical Android PWA screenshots at 20:56 nevertheless rendered those same tasks as `未定` and did not expose `自分がやる`. This is not a DB/fixture defect: the screen shape matches the pre-PR-104 JavaScript bundle while reading the new DailyBrief. The affected physical evidence is therefore **FAIL / STALE-SHELL DEFECT DISCOVERY**, not acceptance evidence.

Root cause in CURRENT web lifecycle:
- Workbox is configured for `autoUpdate`, `skipWaiting`, and `clientsClaim`;
- a newly activated worker already navigates open windows;
- however an Android standalone PWA resumed from a long-lived background process can keep running the old client without causing a service-worker update check, so the new worker is never discovered.

Required remediation:
- check the existing service-worker registration on visible app start and on foreground/focus/pageshow/online;
- debounce duplicate resume events;
- preserve the existing session/local state and never cache mutation requests;
- serve `/sw.js` and `/sw-update.js` as no-cache/no-store;
- update-check failure remains non-blocking and retries on the next lifecycle event.

After merge/deploy, freeze a new exact HEAD and rerun Android Today before any claim mutation. Expected: weekend role-derived items display `誰でもOK` and expose `自分がやる`; they must not display `未定`.

## 7.5 2026-09-13 Android PWA loading/recovery finding

Product Owner reported a second real-use Android PWA problem while rerunning the stale-shell scenario: the PWA can sometimes stop part-way through loading, leave a partially rendered/unresponsive screen, and make bottom-tab navigation unusable until the process is force-closed. Product Owner also requested both pull-to-refresh and an explicit update button.

Fresh CURRENT review found genuine recovery gaps:
- `AuthContext` waited on `getSession()` without a rejection/timeout recovery state;
- initial `HouseholdContext` reads and Today reads had no finite client timeout;
- `HouseholdContext.refresh()` always returned the whole household gate to `loading`, which can unmount the app shell/navigation during a slow refresh even when a valid household snapshot already exists;
- generic `LoadingScreen` had no delayed recovery control;
- AppShell had no explicit reload action and no in-app pull-to-refresh gesture.

Remediation candidate:
- 12s timeout guards for auth, household, and Today read groups;
- auth/initial household failures converge to explicit recovery instead of an infinite spinner;
- once household data has loaded successfully, subsequent household refresh keeps the existing shell/nav mounted and ignores stale earlier responses by sequence;
- all long-running loading screens expose `再読み込み` after 8s;
- header exposes explicit `更新`;
- mobile top-of-page deliberate downward pull triggers reload while short/horizontal/interactive-target gestures do not;
- current URL/session/server state are preserved by normal page reload semantics.

This is a separate genuine PWA resilience defect from the PR #105 stale-shell issue. Affected loading-hang behavior is not accepted until targeted tests + full CI + physical Android rerun pass.

## 7.6 2026-09-14 emergency durable-state recovery after interrupted F2 chat

The previous Physical F2 chat was interrupted. Any local or uncommitted work from that chat is deliberately treated as lost unless it exists in durable GitHub state. No local working tree, prior-chat memory, or imagined patch was used as CURRENT truth.

Fresh recovery readback on 2026-09-14 established:

- durable PR #106 head: `588d939168dd56246945f7b09c159766e2e332b5`;
- PR #106 was already merged before this recovery resumed;
- PR #106 merge commit: `2efc6f22b8a733d529d089562d94d3f1f517816f`;
- PR #107 then corrected a holiday-sensitive **test fixture only**; production behavior was unchanged;
- recovery-anchor CURRENT main after PR #107: `498a1aab7ca82a2999d79a1500858bbcb30e70a0`;
- exact-main CI #1227: SUCCESS across DB, Edge Functions, web lint/typecheck/test/build + browser authoring E2E, and real Supabase CLI integration;
- Operational Safety #322: SUCCESS;
- Vercel production: READY on exact SHA `498a1aab7ca82a2999d79a1500858bbcb30e70a0`.

PR #106 merge-main CI #1224 failed only because `tests/sql/22_routine_line_automation.sql` treated Monday-Friday as sufficient for a Japanese workday and landed its +7-day fixture on 2026-09-21 (敬老の日). Production correctly suppressed the workday-only dispatch. PR #107 made the fixture consult `private.jp_holidays`; current-main CI #1227 is green.

Independent recovery review on CURRENT main rechecked the canonical Requirements/design against implementation and tests. The PR #106 recovery behavior is present on main and no duplicate reimplementation was performed:

- auth, household, and Today reads have finite client-side timeout recovery;
- an already-loaded household shell/navigation remains mounted during refresh;
- stale overlapping household/Today loads are sequence-guarded;
- long generic loading exposes a delayed `再読み込み` action;
- the app header exposes explicit `更新`;
- top-of-page pull-to-refresh is guarded against short/horizontal/scrolled/interactive-target gestures;
- service-worker update checks have a finite timeout and manual recovery reloads even when the update check hangs/fails;
- top-level render errors expose recovery instead of a blank app;
- Today preserves the last good snapshot as stale when a later refresh fails.

The recovery-anchor SHA above is **not** the final Physical F2 frozen SHA because this documentation update itself must merge first. After this documentation PR merges:

1. fresh-read the new CURRENT `main` exact SHA;
2. verify required CI / Operational Safety;
3. verify Vercel production is READY on that exact SHA;
4. freeze that post-merge SHA as the new F2 exact HEAD;
5. then rerun Android PWA evidence. Do not reuse pre-merge screenshots as final PASS evidence.

Required Android rerun, on the same frozen production SHA:

1. resume an installed PWA that previously held an older shell and verify it converges to CURRENT without cache deletion/reinstall;
2. verify loading never remains a permanent spinner;
3. if loading is prolonged, verify the delayed `再読み込み` recovery action appears and works;
4. verify the header `更新` action works;
5. verify top-of-page pull-to-refresh works while short/horizontal/scrolled/interactive gestures do not accidentally refresh;
6. verify auth/session remains signed in after recovery reload;
7. verify bottom navigation remains operable through normal refresh/recovery;
8. verify a partial/stale/failing UI can recover without force-close when the browser event loop remains responsive.

Physical status at this recovery point: **PENDING USER DEVICE EVIDENCE**. Do not mark §7.4/§7.5 PASS until the above is captured on the final post-documentation exact production SHA.

## 7.7 2026-09-16 newly discovered Codmon daily-submission requirement

Physical real-use review exposed a material nursery-operation gap that was not covered by Q89-Q106 image/notice intake: the household must complete and submit the Codmon daily contact book by **09:15 JST**, and this is easy to forget.

Product Owner supplied real Codmon screenshots and the household responsibility rules. This is now canonicalized as Requirements §19.18 / Q113 and `docs/design/current/12_CODMON_DAILY_SUBMISSION.md`.

Required daily semantics:
- Masaki pickup person/time (+ pool availability when the Codmon form presents that field) -> today's pickup owner;
- Shino yesterday dinner/condition -> yesterday's responsible evening owner;
- Shino breakfast -> today's morning/dropoff owner;
- Shino pickup -> today's pickup owner;
- final Codmon send -> today's morning/dropoff owner, only after all four input acknowledgements are complete;
- 09:15 hard deadline, with one targeted 09:00 remaining-work reminder;
- Saturdays/Sundays/Japanese holidays suppressed;
- unresolved previous-day ownership fails closed to unassigned rather than guessing;
- Family Ops does not duplicate the Codmon form values or claim provider submission automatically. The final task is the human acknowledgement that Codmon was actually sent.

Implementation candidate PR #111 adds a dedicated `previous_evening_assignee` strategy, workday-only Codmon materialization, DB-level final-send readiness guard, quota-aware reminder dispatch, household-specific seed, and regression `92_codmon_daily_submission.sql`.

Because this requirement changes the production DB/runtime and creates new daily tasks, all prior F2 exact-HEAD evidence becomes pre-Q113 evidence. After PR #111 is approved/merged and the migration is applied, freeze a new exact production HEAD and physically verify the five Codmon tasks, assignments, 09:15 visibility, early-send rejection, final-send success, and 09:00 reminder behavior.

Physical status: **PENDING POST-MERGE / POST-MIGRATION EVIDENCE**.

## 8. Remaining F2 work after pickup scenario

Continue from the current CF14 matrix, not from memory.

High-value remaining classes include:
- natural LINE conversation / read-only vs mutation;
- Request lifecycle branches;
- same-start transport edit;
- daily operations / Today;
- Q70/Q71 raw natural language;
- physical iPhone/PWA;
- Android PWA where required;
- shopping Q107-Q109;
- Nursery Q89-Q106 actual image path;
- Codmon Q113 daily input / 09:15 final submission / 09:00 reminder;
- Google Q110-Q112 actual controlled provider;
- LINE/PWA concurrency;
- scheduler -> actual LINE delivery;
- whole-day scenario;
- final strict `scripts/run_cf14_f2.mjs` evidence payload.

## 9. Defect rule

If F2 exposes a product defect:

1. stop the affected scenario;
2. classify IMPLEMENTATION DEFECT vs EVIDENCE/ENVIRONMENT ISSUE;
3. compare Purpose -> Requirement -> current design -> implementation -> real behavior;
4. fix on branch/PR;
5. run targeted + full CI;
6. merge/deploy after GREEN;
7. fresh-read and freeze a new exact HEAD;
8. mark affected strict evidence stale and rerun.

Do not rationalize confusing family UX as PASS.

## 10. Parallel language-quality lane

A separate parallel lane is authorized to continue broader colloquial / hostile / long-form AI quality testing while F2 proceeds.

It must not block F2 unless it finds a genuine BLOCKER/HIGH that affects a scenario about to be accepted.

See:
- `docs/implementation/AI-COLLOQUIAL-PARALLEL-LANE-2026-09-12.md`

The parallel lane must use synthetic text only and obey the shared Gemini project budget.

## 11. Control-tower start checklist

After this docs PR merges:

1. fresh-read CURRENT main;
2. confirm CI and Operational Safety GREEN;
3. confirm Vercel production READY for the new main;
4. confirm process-line-inbox / propose-ai-draft / test-simulation runtime alignment;
5. confirm queues and the 9/14 task precondition;
6. freeze one exact HEAD;
7. hand that SHA plus the 2026-09-12 new-owner handoff to the F2 execution owner;
8. resume with exactly one physical operation.

