# AI Natural-Language Robustness Matrix

Status: implemented regression architecture + F2 remediation  
Source of truth for product meaning remains `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`.

## Purpose

Physical F2 exposed multiple failures that should have been detected before real-device execution:

- polite wording routed correctly while blunt/colloquial wording did not;
- reason/context was dropped during softening;
- coercive wording was preserved too literally;
- read-only recollection/questions risked falling into mutation paths;
- deterministic fact validation did not cover every semantic corruption.

This matrix defines a zero-live-AI regression layer that runs before any live Gemini canary or Physical F2.

## Test layers

### L0 — deterministic safety boundary, 0 Gemini calls

Must prove mutation vs read-only boundary, correction handling, explicit pickup handoff language, date/role/negation safety, request softening invariants that do not require a model, and malformed model output rejection.

### L1 — injected-provider semantic tests, 0 Gemini calls

The model provider is replaced with canned JSON. This proves long-input decomposition, multi-intent preservation, exactly-one-ambiguity behavior, source-span validation, and downstream canonical candidate handling. L1 does **not** prove the real model will generate the canned result.

### L2 — live Gemini canary

Separate, rate-limited suite only after L0/L1 converge. Read active project/model limits before execution; never batch blindly; stop on first 429; keep the live corpus small and representative. Do not mutate production/F2 infrastructure merely to manufacture a live score.

### L3 — Physical LINE/PWA

Only representative scenarios after L0/L1 and selected safe L2 canaries pass.

## Synthetic language categories

| Category | Example | Expected |
| --- | --- | --- |
| Polite handoff | `9/14のお迎えお願いできる？` | assignment change |
| Blunt handoff | `9/14のお迎え変われ` | same assignment change |
| Colloquial | `迎え代わってくんない？` | same semantics |
| Recollection only | `変わってくれるって言ってたよね？` | read-only/no mutation |
| Recollection + proceed | `変わってくれるって言ってたよね？よろしく` | assignment change |
| Negated request | `迎えお願いしなくていい` | no new request |
| Reason + request | `仕事で難しいから迎えお願い` | preserve reason; soften ask |
| Guilt/coercion | `前俺やったし迎え変われ` | do not amplify scorekeeping pressure |
| Dismissive assumption | `どうせ暇でしょ迎え行って` | do not forward fabricated/hostile assumption |
| Long mixed input | task + shopping + request + share | independent candidates |
| One ambiguity | known shopping + request with missing assignee | ask only assignee |
| Correction | `土曜…違う日曜` | update original candidate |
| Typing/speech noise | kana/particle errors | avoid unsafe mutation; AI canary covers semantic recovery |
| Fact corruption | date/quantity/role changes | reject |
| Negation flip | `しなくていい` -> `してください` | reject |
| AI consultation | `妻にどう言えば角立たない？` | assistant conversation; no family mutation |
| Draft review/meta | `まだ送らないで、文章だけ見て` | assistant conversation; no send/register |
| Generic recipient | `これってお願いできる？` | fail closed / clarify recipient |
| Mixed conversation + action | advice + explicit family request | discard advice span; keep explicit action only |
| Family→AI repair | `お願いじゃなくて、あなたに相談` | repair pending action into assistant conversation |
| AI→family reverse | `AIじゃなくてママにお願いしたい` | actionable edit direction |
| Valid semantic no-action | model returns `candidates=[]` | authoritative no-action; no deterministic mutation fallback |

## Acceptance dimensions

Do not judge only by exact output wording. Each case can assert intent, mutation yes/no, target resource, date/time, assignee, reason/context preservation, coercion/guilt suppression, no invented facts/emotion/gratitude/apology, negation preservation, source-span validity, ambiguity isolation, sender confirmation, and pre-acceptance assignment state.

## Privacy rule

Do not copy real family LINE messages into fixtures. Synthetic cases may reflect generic language characteristics such as subject/particle omission, colloquial wording, correction mid-sentence, topic switching, context dependence, and dictation-like errors.

## 2026-09-11 zero-live corpus result

Implementation: `supabase/functions/process-line-inbox/lineRobustnessCorpus.test.ts`

Baseline:
- head `860a2d0e0c0eae174840099e7e0351bf587b801b`
- CI #1067
- robustness corpus **46 / 56 PASS = 82.1%**
- full Edge unit suite **221 passed / 10 failed**
- Operational Safety #162 SUCCESS

The 10 failures covered semantic pickup handoff, recollection/negation mutation leakage, scorekeeping/dismissive/coercive rewrite leakage, fabricated quantity, negation flip, invented reason, and invented gratitude.

Convergence:
- head `59db1294343db7797793a433b9a287f7960096a3`
- CI #1072
- robustness corpus **56 / 56 PASS = 100%**
- full Edge unit suite **233 passed / 0 failed**
- web / DB / Edge / Supabase real-stack SUCCESS
- Operational Safety #167 SUCCESS

## 2026-09-12 addressee / context expansion

PR #99 added a coverage-driven expansion rather than a fixed case-count campaign.

Baseline addressee/broken-speech development corpus:
- 36 scenarios;
- **5 PASS / 31 FAIL**;
- failure taxonomy: 29 conversation/addressee action-leakage + 2 hiragana-role recovery;
- severity HIGH and shared to F2 control tower Issue #96.

Permanent remediation now covers:
- AI direct question/advice and spouse-mentioned consultation;
- no-send/no-register/no-notify/draft-only meta intent;
- explicit-family-action counterexamples;
- mixed AI conversation + family action source spans;
- omitted/generic recipient ambiguity;
- AI↔family correction direction;
- multi-turn repair/edit/cancel;
- broken/speech Japanese;
- valid semantic `candidates=[]` vs unavailable/malformed provider fallback.

Held-out discipline:
- any earlier held-out set used to tune a failure was downgraded to diagnostic evidence;
- `lineNlFinalHeldOut20260912.test.ts` was sealed only after CI #1140 was fully GREEN;
- final untouched held-out result: **12 / 12 PASS** in CI #1141.

Final automated evidence before documentation-only closeout:
- implementation head `110560569caa07485d5655a8fdb80640bafb7699`;
- CI #1141 SUCCESS;
- Operational Safety #236 SUCCESS;
- all Edge Deno tests/lint/type-check/auth-matrix, web lint/typecheck/test/build, DB tests, and real local Supabase integration GREEN.

Additional live Gemini calls in PR #99: **0**. The historical live campaign remains 180/180. PR #99 did not redeploy the production `test-simulation` canary or create a paid Supabase branch while Physical F2 was active; safe isolated L2 re-validation is deferred to a release/canary point where it cannot interfere with production/F2.
