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
- first tier: `やる / 難しい / その他の返答`

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

