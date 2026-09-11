# AI Natural-Language Robustness Matrix

Status: test architecture / non-product-behavior change  
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
