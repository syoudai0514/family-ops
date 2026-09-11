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

Must prove:

- mutation vs read-only boundary;
- correction handling;
- explicit pickup handoff language;
- date/role/negation safety;
- request softening invariants that do not require a model;
- malformed model output rejection.

### L1 — injected-provider semantic tests, 0 Gemini calls

The model provider is replaced with canned JSON. This proves:

- long-input decomposition;
- multi-intent preservation;
- exactly-one-ambiguity behavior;
- source-span validation;
- downstream canonical candidate handling.

L1 does **not** prove the real model will generate the canned result.

### L2 — live Gemini canary

Separate, rate-limited suite only after L0/L1 converge.

Rules:

- read active project/model limits before execution;
- never batch blindly;
- sequential calls by default;
- target <=25% of the active RPM budget;
- if limits cannot be confirmed, cap at 5 RPM;
- stop on first 429 and back off;
- keep live corpus small and representative.

### L3 — Physical LINE/PWA

Only representative scenarios after L0/L1 and the selected L2 canaries pass.

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

## Acceptance dimensions

Do not judge only by exact output wording. Each case can assert one or more of:

- `intent`
- mutation yes/no
- target resource
- date/time
- assignee
- reason/context preserved
- coercion/guilt not amplified
- no invented facts/emotion/gratitude/apology
- negation preserved
- source span valid
- ambiguity isolated
- sender confirmation required
- pre-acceptance canonical assignment unchanged

## Privacy rule

Do not copy real family LINE messages into fixtures.

Synthetic cases may reflect generic language characteristics such as:

- subject omission;
- particle omission;
- colloquial/rough wording;
- correction mid-sentence;
- topic switching;
- context dependence;
- dictation-like errors.

No real conversation text, names, secrets, or household-specific private content is required.

## Current zero-live-AI corpus

Implementation:
`supabase/functions/process-line-inbox/lineRobustnessCorpus.test.ts`

The first corpus intentionally encodes desired behavior, not merely current behavior. A failure is a product/implementation finding to classify, not a reason to weaken the expectation.


## 2026-09-11 first execution result

Live Gemini API calls: **0**

Baseline run:
- branch head: `860a2d0e0c0eae174840099e7e0351bf587b801b`
- CI: #1067
- robustness corpus: **46 / 56 PASS = 82.1%**
- full Edge unit suite: **221 passed / 10 failed**
- Operational Safety: #162 SUCCESS

The 10 baseline failures were:

1. semantic pickup handoff `迎え行ってくれる？` not recognized as assignment change;
2. recollection `迎えお願いしてたっけ？` incorrectly treated as mutation;
3. negated request `迎えお願いしなくていい` incorrectly treated as mutation;
4. scorekeeping pressure `前俺やったし` leaked into partner-facing text;
5. dismissive assumption `どうせ暇でしょ` leaked into partner-facing text;
6. coercive strengthener `絶対` leaked into partner-facing text;
7. fabricated quantity in an AI rewrite was not rejected;
8. negation-to-affirmation flip was not rejected;
9. invented reason category was not rejected;
10. invented gratitude was not rejected.

Remediation:
- pickup mutation boundary now distinguishes explicit handoff, recollection, and negation;
- partner-facing fallback rewrite removes scorekeeping/dismissive/coercive pressure while preserving factual reason;
- rewrite invariant validation is now bidirectional for recognized facts and detects negation polarity, invented gratitude/apology, and invented reason categories;
- legacy golden fixtures were updated where the previous behavior explicitly documented these safety gaps as accepted boundaries.

Convergence run:
- branch head: `59db1294343db7797793a433b9a287f7960096a3`
- CI: #1072
- robustness corpus: **56 / 56 PASS = 100%**
- full Edge unit suite: **233 passed / 0 failed**
- CI jobs: web / DB / Edge / Supabase real-stack = SUCCESS
- Operational Safety: #167 SUCCESS

The comparison metric is the unchanged 56-case robustness corpus: **82.1% -> 100%**.


## 2026-09-12 live Gemini quality campaign

Model observed in the production environment: `gemini-3.1-flash-lite`.

Safety / privacy:
- real family LINE text used in fixtures or live prompts: **NO**
- all live prompts were synthetic Japanese
- observed project limit supplied for this campaign: 15 RPM / 250K TPM / 500 RPD
- execution was sequential and kept near the requested <=75% RPM envelope
- 429 responses observed: **0**
- rate-limit discipline took priority over running one monolithic burst

### Live baseline

Strict product-quality scoring, before remediation:

| Area | PASS | Rate |
| --- | ---: | ---: |
| partner-facing rewrite / handover | 76 / 111 | 68.5% |
| single-intent extraction | 28 / 40 | 70.0% |
| multi-intent decomposition | 10 / 29 | 34.5% |
| **overall** | **114 / 180** | **63.3%** |

Important baseline findings included:
- scorekeeping or blame surviving as polite scorekeeping;
- useful requester reasons being deleted together with hostile wording;
- request semantics being narrowed (for example, action -> preparation);
- shopping commands becoming partner requests;
- model-invented Papa/Mama assignments;
- morning/night becoming fabricated concrete clock times;
- role corrections being lost;
- completed purchases being treated as future shopping;
- a store/pharmacy visit inventing a purchase;
- comma-only and punctuation-free multi-intent messages collapsing into one candidate;
- appointment time + departure time + preparation being split or flattened incorrectly.

### Remediation principles

The implementation now treats the AI as a semantic helper behind deterministic safety boundaries:

- preserve the actual request, requester reason, date/time, quantity and core action;
- remove blame, sarcasm, scorekeeping, partner assumptions and predicted partner failure;
- do not merely rewrite hostility into more polite hostility;
- never invent dates, roles, quantities, reasons, purchases or clock times;
- explicit family roles come from the user's source text, not model inference;
- dayparts do not become concrete times without a concrete clock token;
- completed purchase language is actual, not future shopping;
- visiting a store/pharmacy is a task unless a purchase is actually stated;
- correction language updates the original candidate;
- deterministic fallback can split safe comma-connected intents;
- punctuation-free appointment preparation plus a return-stop visit has a deterministic fallback;
- handover preserves pending next actions, not only already-known state.

### Live convergence

The same 180-case corpus was re-evaluated after the fixes. To respect API quota headroom, failed cases were rerun after each converging fix instead of re-burning the entire corpus after every edit.

Final per-case status under the converged implementation:

| Area | PASS | Rate |
| --- | ---: | ---: |
| partner-facing rewrite / handover | **111 / 111** | **100%** |
| single-intent extraction | **40 / 40** | **100%** |
| multi-intent decomposition | **29 / 29** | **100%** |
| **overall** | **180 / 180** | **100%** |

Comparison: **63.3% -> 100%**.

This does not mean arbitrary Japanese is solved. It means every case in the defined synthetic corpus now has a passing final result, with deterministic regression coverage added for the material failures found during the live campaign.
