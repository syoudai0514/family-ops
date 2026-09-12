# Family Ops / おうちノート
# AI Natural-Language Gap Test Plan — 2026-09-12

- **Status:** checkpoint plan derived from `AI-NL-COVERAGE-MATRIX-2026-09-12.md`
- **Starting main:** `d123dc5f4a38392c0e5d8d07ffe5df11b10bdbc2`
- **Branch:** `test/ai-nl-addressee-coverage-2026-09-12`
- **Issue:** #97
- **Physical F2:** not executed by this lane

## 1. Goal

Prove the uncovered semantic boundary:

> a user can talk **to おうちノート/AI** without accidentally creating a family Request or mutation, while an actual request **to a family member** still reaches the family-action path.

The corpus is selected by coverage gap, not by a predetermined total.

## 2. Development corpus — 44 unique scenarios

### ADDR-A — AI direct question / advice / meta safety: 12

Purpose:

- direct question to AI;
- spouse-mentioned advice that is still addressed to AI;
- explicit “do not send / do not register / draft only” instructions.

Representative semantic shapes:

- “これどう思う？”
- “今日どうするのがいいと思う？”
- “妻にどう言えば角立たない？”
- “こういう時どう頼めばいい？”
- “これはまだ送らないで”
- “登録せずに相談だけしたい”
- “相手には送らず文章だけ考えて”

Expected:

- no family Request creation;
- no notification;
- no business mutation;
- advice/draft/read-only response or safe clarification;
- explicit no-send/no-register dominates action words.

### ADDR-B — explicit family action contrast: 4

Purpose: guard against over-correcting the safety classifier.

Representative shapes:

- “ママに牛乳買ってってお願い”
- “妻に今日のお迎えお願いしたい”
- “今日どうするかママに聞いて”
- “迎えお願いできる？”

Expected:

- action path remains reachable;
- explicit family role is preserved;
- no invented role when none is written.

### ADDR-C — AI + family action in one utterance: 4

Purpose: prove conversation-only spans are not mutated while explicit family action is retained.

Representative shapes:

- “あなたならどう伝える？妻にはお迎えお願いしたい”
- “これどう思う？よさそうならママにお願いしたい”

Expected:

- conversation/advice part does not become a candidate;
- explicit actionable family part is preserved as one candidate;
- if wording is conditional rather than an actual send instruction, fail closed instead of silently sending.

### ADDR-D — omitted / ambiguous recipient: 4

Representative shapes:

- “これお願いできる？”
- “今日どうする？”
- “そっちはどう？”
- “これいける？”

Expected:

- no invented family recipient;
- no unsafe Request creation;
- safe clarification/conversation when recipient/action is genuinely ambiguous.

### ADDR-E — correction and reverse correction: 4

Covers:

- “違う、あなたに聞いてる”
- “妻じゃなくてAIに聞いてる”
- “送ってじゃなくて相談”
- “いや、あなたじゃなくて妻にお願いしたい”

Expected:

- superseded draft is cancelled when appropriate;
- no stale draft remains actionable;
- reverse correction can deliberately switch from AI conversation to family Request;
- no hidden duplicate candidate.

### ADDR-F — minimal-pair set embedded above: 4 additional unique scenarios

Pairs include:

- “今日どうする？” vs “今日どうするかママに聞いて”
- “迎えどうなってる？” vs “迎えお願いできる？”
- “迎えお願いできる？” vs “迎えお願いできると思う？”
- “文章考えて” vs “その文章をママに送るお願いにして”

These four bring addressee development total to **28**.

Minimal-pair is also a cross-cutting tag; it is not counted a second time.

## 3. Multi-turn corpus — 8 scenarios

Each case is one 2–4-turn scenario, not four independent “cases”.

Required patterns:

1. request → task-type correction → time correction → cancel;
2. AI consultation → explicit family request;
3. family request draft → “AIに聞いてる” repair → no stale draft;
4. AI question → reverse correction to family request;
5. wrong family role → corrected role → time edit;
6. explicit no-send meta → wording edit → still no mutation;
7. multi-intent draft → cancel one candidate → retain others;
8. prior request recollection → explicit proceed → later cancellation.

State assertions:

- pending-action count/state;
- active candidate identity;
- superseded/cancelled status;
- notification/mutation absence where expected;
- exact surviving recipient/role/date/time.

## 4. Broken/speech Japanese corpus — 8 scenarios

Coverage shapes:

- filler-heavy dictation;
- punctuation-free;
- kana/hiragana;
- typo;
- cut-off ending;
- self-correction mid-utterance;
- role correction without particles;
- advice-vs-request with speech noise.

Examples are synthetic only. No real family LINE text is copied.

At least half of these cases must exercise addressee/recipient safety, not merely generic task decomposition.

## 5. Held-out set — 12 scenarios

Held-out cases are authored after the development taxonomy is fixed but are not consulted while changing prompt/regex/fallback implementation.

Composition:

- 6 addressee/minimal-pair;
- 2 multi-turn;
- 2 broken/speech;
- 2 mixed-action/counterexample.

A development fix cannot be accepted solely because the development 44 become green. Held-out must pass without expectation weakening.

## 6. Test layers

### L0 — deterministic safety

Proves:

- high-confidence explicit meta no-send/no-register;
- direct assistant-address repair;
- minimal-pair request/question guard;
- no dangerous recipient invention;
- cancellation/supersession behavior;
- no stale actionable draft.

### L1 — injected semantic provider

Proves:

- conversation-only spans are discarded from action candidates;
- family-action spans survive in mixed utterances;
- empty/no-action model meaning does not get turned into deterministic mutation fallback;
- ambiguous addressee stays ambiguous;
- source-span safety.

### L2 — live Gemini

Use only where actual language understanding matters:

- advice vs family request;
- mixed conversation+action;
- omitted subject/addressee;
- broken Japanese semantic recovery;
- selected correction nuance.

Development live ceiling: **34 calls** before reruns.

Held-out live ceiling: **8 calls**.

Total planned first-pass live calls: **<=42**.

### L3 — Physical F2

Not executed here.

Real LINE/iPhone/Android/PWA/provider acceptance remains with the F2 lane.

## 7. Baseline-first execution order

1. Author development cases with expected semantic outcome.
2. Run L0/L1 against CURRENT-derived branch **before changing behavior**.
3. Record exact failures and taxonomy.
4. For any genuine defect, compare Purpose → Requirement → current design → implementation.
5. If product behavior needs clarification, update canonical Requirements/current design in the same change unit before implementation.
6. Implement the smallest general fix.
7. Add original failure + >=2 neighboring paraphrases + >=1 counterexample.
8. Rerun L0/L1.
9. Run selected live Gemini cases within quota.
10. Run held-out set.
11. Run targeted Edge tests and full CI.
12. Update result report and existing robustness matrix with permanent coverage.

## 8. Product-spec implication of the addressee gap

The CURRENT Baseline §28.3 clearly requires question/correction before mutation, including explicit assistant-address repair. The Product Owner's 2026-09-12 instruction further specifies durable behavior for:

- first-turn AI question/consultation;
- explicit no-send/no-register;
- family request contrast;
- mixed AI + family utterances;
- ambiguity;
- reverse correction.

Because these are product semantics, not merely test preferences, any implementation that formalizes them must update the canonical Baseline/current design in the same PR. The code must not become the only source of this new boundary.

No canonical edit is made in this planning checkpoint yet; baseline execution evidence will determine the exact minimal wording and implementation contract.

## 9. Quota plan

Known project limits for this lane:

- 15 RPM;
- 250K TPM;
- 500 RPD.

Execution rules:

- <=6 RPM while F2 is active;
- aggregate project target <=11 RPM;
- sequential or otherwise paced to the <=6 RPM lane ceiling;
- preserve >=150–200 RPD headroom;
- stop on first 429;
- no retry loop that pushes through quota;
- verify CURRENT provider reset semantics before relying on a new daily budget;
- do not rerun already-strong 111 rewrite cases or the full 180 corpus merely for reassurance.

## 10. Decision log

| Decision | Reason |
| --- | --- |
| Do not target 500 cases | existing 111 rewrite + 40 single + 29 multi and zero-live regressions make broad random expansion low-value |
| Use 44 development + 12 held-out | directly covers every THIN/MISSING high-risk class found by inventory while preserving an independent overfit check |
| Add 0 standalone rewrite cases initially | rewrite is already STRONG; add only if a new fix touches that path |
| Add 0 standalone fact-integrity cases initially | 56 shared invariant fixtures + permanent live-finding regressions are already strong |
| Treat 180 case details as UNKNOWN where not committed | category totals are evidence; unrecoverable per-case wording is not |
| Classify addressee gap HIGH, not yet BLOCKER | unintended draft/recipient risk is material, but destructive/no-send violation has not yet been observed in baseline execution |
| Keep Physical F2 separate | synthetic semantic breadth and real transport/device acceptance answer different questions |
| Minimal pairs are a tag, not a separate additive bucket | avoids inflating “case count” through semantic double counting |

## 11. Traceability convention

New cases will use stable IDs:

- `NL-ADDR-D001...`
- `NL-CTX-D001...`
- `NL-BROKEN-D001...`
- `NL-ADDR-H001...` for held-out addressee, etc.

Result report will trace:

`Coverage ID -> Case ID -> test file -> baseline result -> defect/fix -> final result`.

A statement such as “56/56 PASS” is not sufficient unless the covered semantic dimensions remain visible through this mapping.
