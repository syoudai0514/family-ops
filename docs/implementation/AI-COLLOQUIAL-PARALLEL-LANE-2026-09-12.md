# Family Ops / おうちノート
# PARALLEL AI COLLOQUIAL / CONCIERGE QUALITY LANE — 2026-09-12

## 0. Role

Run in parallel with Physical F2.

Goal:
find additional natural-language failures in LINE / AI concierge behavior **without blocking unrelated F2 work**.

This is an exploratory/regression lane, not a replacement for Physical F2.

## 1. Scope

Test whether Family Ops understands and safely rewrites realistic Japanese that is:
- subject-omitted;
- particle-omitted;
- rough / blunt;
- sarcastic / passive-aggressive;
- scorekeeping / guilt-inducing;
- mid-sentence corrected;
- context-dependent;
- dictation-like;
- typo-heavy;
- long and multi-topic;
- punctuation-free;
- mixed request / shopping / task / share / actual;
- ambiguous in exactly one field;
- negative / cancellation / no-change;
- conversational follow-up referring to the immediately previous draft;
- direct questions / consultation addressed to おうちノート itself;
- explicit no-send / no-register meta instructions;
- mixed AI-conversation + family-action utterances;
- ambiguous or omitted addressee / recipient.

Do not copy real family LINE messages.
Use only newly generated synthetic examples that reflect generic linguistic characteristics.

## 2. Quality target

Do not score only exact string equality.

For partner-facing rewrite, grade:
- core request preserved;
- requester reason preserved when materially useful;
- hostile/blaming/scorekeeping material removed;
- hostility is not merely converted into polite hostility;
- recipient assumptions are not invented;
- facts/date/time/quantity/role unchanged;
- no invented gratitude/apology/emotion;
- natural family-level Japanese, not stiff customer-service language;
- recipient can understand what is being asked and why.

For intent/decomposition, grade:
- correct kind;
- mutation vs read-only;
- correct date/time;
- correct explicit role only;
- no role/time/fact invention;
- correction applied to original candidate;
- separate independent intents remain separate;
- one ambiguity does not erase understood content;
- source span / canonical candidate remain safe.

## 3. Corpus strategy

Do **not** choose a fixed corpus size in advance.

First inventory:
- the completed 180-case live corpus at the level that CURRENT evidence can actually reproduce;
- the zero-live robustness layer;
- related CURRENT regression tests;
- Physical F2 overlap.

Then classify every material semantic area as `STRONG / ADEQUATE / THIN / MISSING` and add cases only for THIN/MISSING gaps.

The 2026-09-12 fresh inventory is recorded in:
- `AI-NL-COVERAGE-MATRIX-2026-09-12.md`
- `AI-NL-GAP-TEST-PLAN-2026-09-12.md`

That inventory found the broad rewrite/fact layers already strong enough that hundreds of additional random cases would be low-value. The highest-value gaps are:
- AI itself vs family-member addressee;
- explicit no-send/no-register meta intent;
- mixed AI-conversation + family action;
- omitted/ambiguous recipient;
- multi-turn correction/cancellation;
- broken/speech Japanese around those boundaries.

Current coverage-derived plan:
- development: 44 unique scenarios;
- held-out: 12 unique scenarios;
- total additional: 56 unique scenarios;
- planned first-pass live Gemini subset: <=42 calls.

Minimal pairs and fact guards are cross-cutting tags and must not be double-counted as extra semantic cases.

Run deterministic/injected-provider layers first, then live Gemini only where actual model meaning-understanding is the property under test.

## 4. Gemini project budget

Observed active project limits supplied by the Product Owner:
- 15 RPM
- 250K TPM
- 500 RPD

The Product Owner authorized use up to 75% of the project RPM ceiling.

Because this lane runs in parallel with F2, treat **11 RPM as the aggregate project ceiling across all active lanes**, not a per-chat allowance.

Default parallel-lane budget:
- <= 6 RPM while F2 is active;
- no parallel API bursts;
- if the control tower confirms the F2 lane is not consuming live Gemini, the lane may temporarily rise toward 10 RPM;
- stop on first 429 and back off;
- track daily request count to avoid 500 RPD;
- do not assume API-key separation; project-level limits apply.

## 5. Workflow

1. fresh-read CURRENT main;
2. create a dedicated branch/issue;
3. add synthetic test cases and expected semantic dimensions;
4. establish baseline;
5. classify failures by root cause;
6. fix only genuine implementation/quality defects;
7. targeted + full CI;
8. rerun failed + neighboring cases;
9. run a held-out set to detect overfitting;
10. report baseline -> final success rate and remaining failure classes.

Do not weaken an expectation merely to make a test green.

## 6. Overfitting guard

For every prompt/regex/fallback fix:
- add the failing case;
- add at least 2 neighboring paraphrases;
- add at least 1 counterexample where mutation must not occur;
- keep a held-out synthetic set not used while writing the fix.

A 100% training corpus score is not enough by itself.

## 7. Interaction with F2

This lane should not automatically block Physical F2.

Escalate to the control tower only when:
- BLOCKER: could cause wrong family action / wrong recipient / destructive mutation / serious misunderstanding;
- HIGH: likely real-use failure in a scenario F2 is about to accept.

MEDIUM/LOW findings:
- document them;
- fix in the parallel branch;
- continue unrelated F2.

If a merged fix changes main, affected exact-head F2 evidence must follow the standard stale/rebind rules.

## 8. Deliverables

Each checkpoint should report:
- CURRENT/frozen source HEAD;
- corpus size;
- deterministic vs live-Gemini counts;
- API RPM/TPM/RPD safety status;
- baseline success rate;
- failure taxonomy;
- fixes made;
- post-fix success rate;
- held-out success rate;
- BLOCKER/HIGH findings requiring control-tower attention;
- PR/branch exact HEAD.

