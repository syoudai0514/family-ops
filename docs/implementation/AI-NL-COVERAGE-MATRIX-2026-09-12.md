# Family Ops / おうちノート
# AI Natural-Language Coverage Matrix — 2026-09-12

- **Status:** parallel-lane checkpoint / coverage inventory before implementation changes
- **Starting CURRENT main:** `d123dc5f4a38392c0e5d8d07ffe5df11b10bdbc2`
- **Branch:** `test/ai-nl-addressee-coverage-2026-09-12`
- **Issue:** #97
- **Physical F2:** explicitly out of scope for this lane
- **Product authority:** `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`
- **Detailed design:** `docs/design/current/`
- **Existing QA record:** `docs/implementation/AI-NL-ROBUSTNESS-MATRIX.md`

## 0. Authority / CURRENT inventory

Fresh-read at lane start:

- CURRENT `main` exact HEAD = `d123dc5f4a38392c0e5d8d07ffe5df11b10bdbc2`.
- PR #95 is merged. Its live-Gemini quality campaign is part of CURRENT main.
- PR #98 is merged. Its F2 handoffs and parallel-lane document are part of CURRENT main.
- PR #98 head CI #1101 = SUCCESS and Operational Safety #196 = SUCCESS.
- CURRENT merge commit exposes Vercel = success through combined-status readback; no separate PR-triggered Actions run is claimed for that merge commit.
- `AGENTS.md`, root `START-HERE.md`, and `docs/START-HERE.md` were not present at CURRENT main when directly fetched.
- ADR 0012 and ADR 0013 are Accepted. Product behavior follows the Requirements Baseline; exact-scope architecture follows accepted ADR/current design.
- Requirements §28.3 requires natural LINE questions/corrections, including direct repair such as “あなたに聞いている”, to be interpreted before mutation.
- Current design 04 §26.2 mirrors that requirement.

This document is **test/coverage evidence**, not a competing requirements source.

## 1. What is actually recoverable from the existing 180 live cases

The CURRENT repository proves the following aggregate live-campaign facts:

| Area | Baseline | Final |
| --- | ---: | ---: |
| partner-facing rewrite / handover | 76 / 111 | 111 / 111 |
| single-intent extraction | 28 / 40 | 40 / 40 |
| multi-intent decomposition | 10 / 29 | 29 / 29 |
| **overall** | **114 / 180** | **180 / 180** |

The repository also records the major failure taxonomy and the permanent regressions created from those failures.

However, a fresh search of CURRENT main and commit history did **not** locate a committed 180-row live fixture/case manifest. The live runner was temporary and the production `test-simulation` function was restored after the canary. Therefore:

- category totals and final results are verified;
- material failure classes are verified;
- exact per-case wording / per-subcategory distribution for all 180 cases is **UNKNOWN**;
- no row below treats an unrecoverable live case detail as independently proven coverage.

This is a traceability limitation, not a claim that the campaign did not happen.

## 2. Existing zero-live regression inventory

`supabase/functions/process-line-inbox/lineRobustnessCorpus.test.ts` contains the defined 56-unit zero-live layer. The 56 units are not 56 independent semantic topics:

- pickup assignment boundary rows: 25;
- schedule/read-only rows: 13;
- partner-facing pickup rewrite rows: 6;
- invariant rows: 7;
- correction-cue test: 1;
- injected-provider semantic tests: 3;
- corpus-size guard: 1.

Important overlap exists among those units and with the 180 live campaign.

Additional CURRENT tests materially relevant to this matrix include:

- `lineConversation.test.ts`: 10 Deno tests; schedule questions, assistant-address correction, mutation guards, conversational acknowledgement;
- `lineIntent.test.ts`: 14 Deno tests; single-intent classification, role/correction, pickup boundary, colloquial shopping, hiragana role;
- `lineMultiIntent.test.ts`: 23 Deno tests; colloquial/multi-intent, one ambiguity, corrections, source span, role invention guard, punctuation-free fallbacks;
- `_shared/gemini.test.ts`: 56 named invariant fixtures for date/time/quantity/identity/negation/reason/gratitude and related equivalences.

These suites overlap semantically; their raw test counts are **not** added to claim a synthetic “total coverage count”.

## 3. Coverage matrix

Definitions:

- **STRONG:** multiple independent layers and representative variants cover the semantic risk; no material gap currently identified.
- **ADEQUATE:** core behavior is covered, but edge diversity or traceability is not complete.
- **THIN:** some relevant tests exist, but a real-use class is poorly represented.
- **MISSING:** the material behavior is not directly proven.
- “Additional” means unique new scenario cases for the development set unless marked held-out.

| Coverage ID | 観点 | sub-category | 既存case数 / evidence | live Gemini | deterministic / L1 | Physical F2 overlap | coverage | risk | 不足理由 | 追加必要 | 追加case | live必要 | regression化 |
| --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | --- | ---: | --- | --- |
| NL-RW-01 | partner-facing rewrite | blame / sarcasm / guilt / scorekeeping / coercion / reason preservation | live **111 aggregate**; robustness rewrite 6; invariant fixtures include scorekeeping/reason | YES, 111 aggregate; exact subcategory distribution UNKNOWN | YES | LOW; F2 uses representative real request only | **STRONG** overall | HIGH | exact 111-case subcategory trace is unavailable, but observed failure classes have permanent regressions | NO standalone expansion | 0 | NO | keep existing regressions; add neighbors only if a new rewrite defect changes code |
| NL-SI-01 | single-intent colloquial | omission / rough request / shopping / role | live **40 aggregate**; pickup boundary 25 plus targeted lineIntent tests | YES, 40 aggregate; detail UNKNOWN | YES | representative raw LINE overlaps | **ADEQUATE** | HIGH | live detail is not reproducible; current deterministic variants are action-oriented, not addressee-oriented | only addressee-specific neighbors | 0 standalone | selected addressee cases only | existing tests + addressee corpus |
| NL-MI-01 | multi-intent | request+shopping/task/share/actual; punctuation-free | live **29 aggregate**; robustness injected-provider 3; lineMultiIntent targeted suite | YES, 29 aggregate; detail UNKNOWN | YES | Q70/Q71 representative raw input overlaps | **ADEQUATE** | HIGH | generic decomposition is covered; “AI conversation + family action in one utterance” is not | YES | 4, counted under addressee | YES for all 4 | injected provider + live semantic subset |
| NL-MUT-01 | mutation/read-only | pickup request vs recollection / negation / no-change | robustness pickup 25 incl. non-mutation rows; read-only 13; extra conversation tests | live detail UNKNOWN | YES | YES, representative physical LINE | **STRONG** for basic pickup/schedule boundary | BLOCKER/HIGH if violated | basic boundary is strong; generic AI-directed consultation is a different uncovered boundary | NO generic expansion | 0 | NO | keep existing |
| NL-ADDR-01 | addressee | AI direct question | schedule-specific read-only exists; generic first-turn AI question direct proof = **0 verified** | UNKNOWN | only correction-oriented assistant address exists | YES conceptually; physical transport proof remains F2 | **MISSING** | HIGH | first utterance such as “これどう思う？” reaches semantic decomposition; current candidate schema has no conversation kind | YES | 4 | YES | new deterministic/L1 safety corpus + live model cases |
| NL-ADDR-02 | addressee | AI consultation/advice | **0 verified** first-turn consultation cases | UNKNOWN | NO direct corpus | limited representative overlap | **MISSING** | HIGH | “妻にどう言えば角立たない？” can mention spouse yet is advice, not request | YES | 4 | YES | same as above |
| NL-ADDR-03 | addressee | AI confirmation / state question outside schedule shortcuts | schedule questions covered; generic state/addressee examples incomplete | UNKNOWN | PARTIAL | YES | **THIN** | HIGH | CURRENT read-only grammar is mainly today/tomorrow/week/menu; generic state questions are not systematically covered | YES | 2 | selective | deterministic read-only / injected semantic tests |
| NL-ADDR-04 | addressee | meta: do not send / do not register / draft only | **0 verified** | UNKNOWN | NO direct corpus | NO physical expansion in this lane | **MISSING** | HIGH | explicit no-mutation instruction must dominate recipient/action words | YES | 2 | YES | hard fail-closed guard + injected/live semantic tests |
| NL-ADDR-05 | addressee | explicit family request | pickup/request variants strong; explicit role recovery exists | live single-intent aggregate includes requests but detail UNKNOWN | YES | YES | **ADEQUATE/STRONG** | HIGH | only contrasting neighbors are needed so a safety guard does not swallow real requests | YES, neighbor only | 4 | 2 | minimal-pair regression |
| NL-ADDR-06 | addressee | AI + family action in same utterance | **0 verified** explicit conversation+action decomposition cases | UNKNOWN | NO direct case | representative F2 may later cover one path | **MISSING** | HIGH | current model schema can represent actions but not the conversation-only span; risk of dropping action or mutating advice text | YES | 4 | YES | injected provider + live model; conversation span must not become mutation |
| NL-ADDR-07 | addressee | subject/recipient omitted / ambiguous | pickup “迎えできる？” non-mutation exists; one-assignee ambiguity exists | UNKNOWN | PARTIAL | YES | **THIN** | HIGH | generic “これお願いできる？” / “今日どうする？” addressee ambiguity is not systematically fail-closed | YES | 4 | YES | ambiguity tests + no-recipient-invention assertion |
| NL-ADDR-08 | addressee | correction AI↔family / reverse correction | assistant-address correction phrases exist; family-role correction exists | UNKNOWN | PARTIAL | YES | **THIN** | HIGH | “違う、あなたに聞いてる” is partially covered; reverse “あなたじゃなくて妻に” and draft cleanup chain are not | YES | 4 | YES | pending-action sequence tests + neighbor/counterexample |
| NL-CTX-01 | multi-turn context | 2–4 turn correction / field edit / cancel / addressee flip | pending-reference/correction functions and isolated tests exist; full multi-turn scenario corpus = **0 verified** | NO verified multi-turn live campaign | PARTIAL | YES representative | **THIN** | HIGH | single utterance correction does not prove stateful 2–4 turn behavior or draft cleanup | YES | 8 | 4 semantic turns only | stateful handler/unit sequence regression |
| NL-BROKEN-01 | speech / typo / broken Japanese | filler / no punctuation / typo / cut-off / mid-sentence repair | a few verified examples: spoken 2-intent, hiragana role, schedule typo, punctuation-free fallbacks | live 40/29 may contain some; exact count UNKNOWN | PARTIAL | representative raw LINE overlap | **THIN** | MEDIUM/HIGH | current verified diversity is narrow, especially around addressee safety | YES | 8 | 6 | focused variants tagged with addressee/action expected mode |
| NL-FACT-01 | fact integrity | date/time/daypart/quantity/role/reason/negation/gratitude | `gemini.test.ts` 56 invariant fixtures + robustness invariant 7 + live finding regressions | YES through campaign failures/convergence | YES | low | **STRONG** | HIGH | no material uncovered fact class found in inventory | NO standalone expansion | 0 | NO | existing invariant suite |
| NL-SPAN-01 | source-span / one ambiguity | no fabricated span; isolate ambiguity | robustness injected 2 relevant cases + lineMultiIntent tests | live multi aggregate detail UNKNOWN | YES | low | **ADEQUATE** | MEDIUM | conversation-only spans are the only new gap and are covered under NL-ADDR-06 | NO standalone | 0 | NO standalone | addressee mixed cases |
| NL-ACT-01 | actual/shopping/store semantics | completed purchase / store visit / terse shopping | permanent regressions in lineIntent/lineMultiIntent after live campaign | YES, campaign finding | YES | Q107-Q109 F2 is state/physical, not language breadth | **ADEQUATE** | MEDIUM | no new language-specific gap found | NO | 0 | NO | existing |

## 4. Key finding: AI本人への発話 vs 家族向け発話

### Existing coverage

The existing system is strong at:

- schedule-specific read-only questions;
- pickup request vs recollection/negation;
- assistant-address **correction after a misinterpretation**, e.g. “あなたに聞いてる”;
- explicit family-role requests;
- role correction inside an actionable request.

It is **not** yet directly proven for first-turn generic consultation/advice/meta intent.

### Current implementation shape that creates the gap

CURRENT `process-line-inbox` routing handles:

1. must-complete text;
2. known read-only schedule/menu text;
3. pending referent/correction;
4. editable pending correction;
5. creation starter;
6. AI-first semantic decomposition.

The semantic decomposition schema currently permits only:

- `task`
- `request`
- `shopping`
- `share`
- `actual`

There is no explicit “conversation/advice/no-action” representation in that schema.

This does **not** prove every such utterance currently misbehaves. It proves the safety boundary is under-specified and under-tested: a model may return no candidate, misclassify a spouse-mentioned advice question, or send the input into generic review fallback. For a recipient/mutation boundary, that is insufficient evidence.

### Risk judgment

This is **HIGH**, not yet BLOCKER:

- it can create an unintended Request/draft or wrong recipient interpretation;
- the current flow still uses pending/confirmation boundaries for many mutations, so no destructive automatic mutation has yet been demonstrated by this inventory;
- if live or handler-level testing proves a no-send/no-register utterance actually notifies family or executes a mutation, escalate to **BLOCKER** immediately.

## 5. Additional corpus size derived from the matrix

No fixed “500 cases” target is justified.

### Development set: 44 unique scenarios

Primary buckets (mutually exclusive for counting):

| Primary bucket | New scenarios | Why |
| --- | ---: | --- |
| addressee / recipient boundary | **28** | covers direct AI question, advice, meta no-send, explicit-family contrast, mixed AI+family, omitted/ambiguous recipient, AI↔family corrections |
| multi-turn context | **8** | proves 2–4 turn correction/edit/cancel/draft cleanup rather than isolated regex behavior |
| broken/speech Japanese | **8** | fills filler/typo/cut-off/no-punctuation gaps, focused on semantic safety rather than broad random noise |
| generic rewrite | **0** | existing 111 live aggregate + permanent regressions is already strong |
| generic fact integrity | **0** | existing invariant suite is strong |
| generic multi-intent | **0 standalone** | only the 4 addressee-mixed cases are needed; existing generic corpus is adequate |
| **Development total** | **44** | |

### Held-out: 12 unique scenarios

Held-out cases are authored separately and not used to tune prompt/regex/fallback fixes.

### Total additional unique scenarios: **56**

Cross-cutting tags such as **minimal pair**, **fact guard**, and **multi-intent** can apply to a primary scenario but are **not added again** to the 56 total.

Planned cross-cutting minimums:

- minimal-pair tagged scenarios: >=12;
- ambiguous/fail-closed tagged scenarios: >=8;
- explicit no-mutation/meta tagged scenarios: >=6;
- mixed AI+family tagged scenarios: >=4;
- fact/role/date invariant assertions: wherever applicable, without creating redundant standalone cases.

## 6. Live Gemini budget derived from semantic need

Not all 56 scenarios need a live model call.

Provisional maximum:

- development live semantic cases: <=34;
- held-out live semantic cases: <=8;
- **total planned live calls: <=42** before any genuine-failure reruns.

L0/L1 should run first.

Live is reserved for:

- direct addressee nuance;
- spouse-mentioned advice vs request;
- mixed conversation+family action;
- ambiguous omitted-recipient wording;
- broken Japanese semantic recovery;
- selected context-dependent interpretation.

State transition, cancellation, mutation guard, and draft cleanup are primarily deterministic/handler tests.

Quota policy:

- parallel lane <=6 RPM while Physical F2 is active;
- aggregate project target <=11 RPM;
- stop on first 429 and back off;
- preserve at least ~150–200 RPD headroom;
- do not assume reset at JST 00:00;
- do not consume quota merely to repeat already-strong rewrite/fact categories.

## 7. Physical F2 overlap and separation

| Area | Parallel AI lane | Physical F2 |
| --- | --- | --- |
| many synthetic addressee/minimal pairs | YES | NO |
| deterministic pending/mutation safety | YES | representative behavior only |
| live Gemini semantic nuance | YES, quota-limited | not broad campaign |
| real iPhone LINE transport | NO | YES |
| real Android recipient | NO | YES |
| real PWA/device | NO | YES |
| provider/Nursery/Google | NO | YES |
| Q70/Q71 language breadth | regression here | exact-head real-entry proof there |
| read-only vs mutation | broad synthetic here | representative physical proof there |

A BLOCKER/HIGH finding relevant to an imminent F2 acceptance must be shared with the control tower. MEDIUM/LOW findings do not stop unrelated F2.

## 8. First-checkpoint verdict

Coverage summary before new tests:

- **STRONG:** partner-facing rewrite overall; basic pickup mutation/recollection/negation; fact integrity.
- **ADEQUATE:** generic single-intent; generic multi-intent; source-span/one-ambiguity; shopping/actual semantics.
- **THIN:** generic state/read-only outside schedule shortcuts; omitted/ambiguous addressee; reverse correction; multi-turn context; broken/speech Japanese.
- **MISSING:** first-turn AI direct consultation/advice/meta-no-send; mixed AI-conversation + family action boundary.

The next implementation step is therefore **not** “add hundreds of random Japanese strings”. It is to author the 44-case development corpus around these gaps, run zero-live baseline first, and only then select the <=34 cases whose result genuinely depends on live Gemini semantics.
