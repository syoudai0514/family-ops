# Family Ops / おうちノート
# AI Natural-Language Quality Results — 2026-09-12

- **Status:** IN PROGRESS — baseline checkpoint
- **Starting CURRENT main:** `d123dc5f4a38392c0e5d8d07ffe5df11b10bdbc2`
- **Branch:** `test/ai-nl-addressee-coverage-2026-09-12`
- **PR:** #99
- **Issue:** #97
- **Physical F2:** not executed by this lane

## 1. Documentation set

- Coverage matrix: `docs/implementation/AI-NL-COVERAGE-MATRIX-2026-09-12.md`
- Gap plan: `docs/implementation/AI-NL-GAP-TEST-PLAN-2026-09-12.md`
- Result report: this file
- Existing robustness record: `docs/implementation/AI-NL-ROBUSTNESS-MATRIX.md`

## 2. Existing evidence baseline

Verified from CURRENT repository:

- live Gemini campaign: 180 aggregate cases;
  - rewrite/handover 111;
  - single-intent 40;
  - multi-intent 29;
  - original baseline 114/180;
  - converged 180/180.
- zero-live robustness layer: 56 units, converged 56/56.
- exact wording for the full 180 live corpus is not committed on CURRENT main; subcategory-level case detail remains UNKNOWN and is not treated as proven.
- Physical F2 overlap is representative real-entry proof only; this lane does not execute Physical F2.

## 3. Coverage-derived additional plan

- development: 44 unique scenarios;
- held-out: 12 unique scenarios;
- total additional unique scenarios: 56;
- first-pass live Gemini ceiling: <=42 calls.

No fixed 500-case target is used.

## 4. Baseline semantic execution — checkpoint 1

### Exact baseline head

`952468cb16facd25b19fb66124d468d4c9dd9db8`

### Added corpus at this checkpoint

`supabase/functions/process-line-inbox/lineAddresseeQualityCorpus.test.ts`

Development cases exercised so far:

- addressee: 28;
- broken/speech Japanese: 8;
- total: 36.

The remaining 8 planned development cases are multi-turn scenarios and are not counted as executed yet.

### Result

**PASS 5 / 36**
**FAIL 31 / 36**
**baseline success rate: 13.9%**

GitHub Actions CI #1104:

- edge Deno lint: PASS;
- edge Deno type-check: PASS;
- edge Deno unit tests: **FAIL** due to the new semantic corpus;
- unit summary at the failure point: **265 passed / 31 failed**;
- Operational Safety CI #199: PASS;
- unrelated web/db jobs observed GREEN at the time of this checkpoint; full CI #1104 final conclusion was not yet claimed here.

### Failure taxonomy

| Taxonomy | Count | Severity | Meaning |
| --- | ---: | --- | --- |
| addressee / conversation-only action leakage | 29 | HIGH | model-returned task/request/share candidates for AI-directed advice/question/meta-no-send/mixed/ambiguous spans are currently accepted by the semantic boundary |
| hiragana family-role loss | 2 | HIGH for recipient correctness | explicit `まま` in model source span is not preserved by `lineMultiIntent.ts` explicit-role normalization |
| **Total failures** | **31** | | |

### What passed

Five cases already behaved correctly:

- three clear explicit family requests;
- one reverse correction from AI to wife/family request;
- one speech-like final-role correction.

This is important evidence against a blanket fix. The correct solution must preserve explicit family action while blocking only conversation/meta/ambiguous action leakage.

## 5. Concrete implementation defect demonstrated

CURRENT semantic normalization accepts only operation kinds:

- task;
- request;
- shopping;
- share;
- actual.

It has no explicit conversation/no-action candidate contract. If a model returns an operation candidate for:

- “これどう思う？”
- “妻にどう言えば角立たない？”
- “これはまだ送らないで”
- “相手には送らず文章だけ考えて”
- “迎えお願いできると思う？”

the current strict normalizer can still accept that candidate when source-span/fact shape is otherwise valid.

For mixed utterances, it also accepts the conversation-only span alongside the legitimate explicit family-action span.

This is a genuine safety-boundary defect, not merely missing test coverage.

## 6. F2 impact / escalation

Severity: **HIGH**.

Control tower Issue #96 received an immediate finding comment from this baseline.

Action:

- do not globally stop unrelated Physical F2;
- do not accept the natural-LINE read-only/mutation/addressee boundary on the pre-fix implementation;
- if later handler/live testing proves an explicit no-send/no-register utterance actually triggers partner notification or executes business mutation, escalate to BLOCKER.

## 7. Planned fix shape

The planned remediation is deliberately two-layered:

1. **deterministic fail-closed safety boundary**
   - direct AI consultation/question;
   - explicit no-send/no-register/draft-only;
   - clearly ambiguous generic recipient;
   - assistant-address correction;
   - preserves clear family-action counterexamples.

2. **semantic-provider / candidate boundary**
   - prompt explicitly excludes conversation-only spans from operation candidates;
   - candidate normalization rejects conversation-only/conditional/meta spans even if the model returns them;
   - mixed utterances may retain explicit actionable spans while discarding conversation-only spans;
   - no role is invented;
   - hiragana role variants are normalized only when present in source.

No one-case regex fix is acceptable.

## 8. Live Gemini

Not executed yet in this lane.

- total calls: 0;
- peak RPM: 0;
- 429: 0;
- RPD headroom: unchanged by this lane.

L0/L1 regression must converge before live quota is used.

## 9. Current severity count

- BLOCKER: 0 observed
- HIGH: 2 failure classes / 31 failing scenarios
- MEDIUM: 0 new
- LOW: 0 new

## 10. Current gates

- Coverage inventory: PASS
- Gap plan: PASS
- Baseline L0/L1 semantic corpus: **FAIL as expected; defect reproduced**
- Fix: PENDING
- 8 multi-turn development scenarios: PENDING
- 12 held-out scenarios: PENDING
- live Gemini: PENDING
- targeted tests: PENDING
- full CI final: PENDING
- main merge: NO
- production deploy: NO
- documentation complete: NO
