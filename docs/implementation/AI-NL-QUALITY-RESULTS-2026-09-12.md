# Family Ops / おうちノート
# AI Natural-Language Quality Results — 2026-09-12

- **Status:** IMPLEMENTATION / L0-L1 QUALITY CLOSEOUT COMPLETE
- **Starting CURRENT main:** `d123dc5f4a38392c0e5d8d07ffe5df11b10bdbc2`
- **Branch:** `test/ai-nl-addressee-coverage-2026-09-12`
- **PR:** #99
- **Issue:** #97
- **Physical F2:** not executed by this lane

## 1. Existing evidence baseline

CURRENT main already carried a live Gemini campaign of 180 aggregate cases: rewrite/handover 111, single-intent 40, multi-intent 29. That campaign moved from 114/180 to 180/180. The committed zero-live robustness layer contains 56 units. The exact wording of all 180 historical live rows is not committed, so subcategory detail remains UNKNOWN and is not invented here.

## 2. Coverage-driven work in PR #99

The lane did not use a fixed “500 cases” target. It concentrated on the material gap: **AI/おうちノート本人への質問・相談・文章レビュー vs 家族への実際の依頼/登録**, including mixed utterances, ambiguity, correction direction, multi-turn repair/cancel, and broken/speech Japanese.

Initial development baseline at `952468cb16facd25b19fb66124d468d4c9dd9db8`:

- 36 addressee/broken-speech cases executed;
- PASS 5 / 36;
- FAIL 31 / 36;
- 29 addressee/conversation-action leakage failures;
- 2 hiragana role-recovery failures.

This HIGH finding was shared to Physical F2 control tower Issue #96. No unrelated Physical F2 work was stopped.

## 3. Implemented behavior

PR #99 now provides:

1. deterministic fail-closed recognition for AI consultation/advice, draft review, explicit no-send/no-register/no-notify, unsafe generic recipient ambiguity, and correction direction;
2. preservation of explicit family actions and role/date/time facts;
3. source-span filtering so mixed AI-conversation + family-action input keeps only authorized action spans;
4. assistant-conversation replies that never claim a family mutation occurred;
5. 2–4 turn pending-action repair/edit/cancel behavior;
6. speech/kana/colloquial role handling;
7. semantic-provider distinction between a **valid `candidates=[]` no-action result** and unavailable/malformed provider output. A valid semantic no-action result is authoritative and does not fall back into deterministic mutation; only unavailable/invalid model output uses the deterministic availability fallback.

The last item closes the structural HIGH discovered during review: model-understood “no business action” can no longer be silently converted back into an action merely because the normalized candidate list is empty.

## 4. Regression and held-out methodology

Development and diagnostic corpora were deliberately separated from held-out acceptance.

- `lineAddresseeQualityCorpus.test.ts`: 36 development scenarios.
- `lineConversationContextQuality.test.ts`: multi-turn development scenarios and direction-sensitive assertions.
- `lineNlDiagnosticRegression20260912.test.ts`: permanent neighboring paraphrases/counterexamples for failure classes.
- earlier held-out sets (`lineNlHeldOut20260912`, V2, V3, and `lineNlFreshHeldOut20260912`) became **diagnostic** whenever their failures were used to tune implementation. They are not claimed as untouched final held-out evidence.
- `lineNlFinalHeldOut20260912.test.ts`: 12 fresh scenarios, sealed only after CI #1140 was fully green. No implementation was tuned from these rows.

Final fresh held-out result: **12 / 12 PASS** in CI #1141.

The final set covers indirect tone advice, pre-send review, no-send meta intent, generic-recipient ambiguity, explicit spouse action, explicit shopping action, mixed semantic spans, valid semantic no-action, family→AI repair, AI→family reverse correction, colloquial cancel, and concrete pending edit.

## 5. Final automated evidence

Pre-final convergence head `cd5fcf2a03360b319f90e2323c59064a15c3b5f9`:

- CI #1140: **SUCCESS**;
- Operational Safety #235: **SUCCESS**;
- all edge Deno tests, lint/type-check/auth-matrix, web lint/typecheck/test/build, DB suite, and real local Supabase integration: PASS.

Fresh final held-out head `110560569caa07485d5655a8fdb80640bafb7699`:

- CI #1141: **SUCCESS**;
- Operational Safety #236: **SUCCESS**;
- fresh held-out: **12 / 12 PASS**;
- existing development/diagnostic/robustness suites remained GREEN.

No migration was added by this lane.

## 6. Live Gemini decision

Additional live Gemini calls from PR #99: **0**.

This is intentional, not an omitted test disguised as PASS. The project currently has no isolated committed AI-NL canary runner. The production `test-simulation` function is the normal one-person simulation function, not the temporary Gemini canary used by the earlier 180-case campaign. Running the new PR implementation live would therefore require either:

- temporarily mutating/deploying a production Edge Function while Physical F2 is active; or
- creating a paid Supabase branch.

Neither was authorized for this lane. The lane therefore did **not** spend Gemini quota or create a production/F2 interference risk merely to manufacture a live number. Existing historical live evidence remains 180/180; new addressee/context semantics are proven at L0/L1 and fresh held-out level, with live re-validation deferred to a safe isolated canary/release verification point.

Google Gemini project quota rules are project-scoped; the lane preserved the requested <=6 RPM / <=11 aggregate policy and 150–200 RPD headroom by making no additional calls.

## 7. Severity / gates at closeout

- BLOCKER: **0**
- HIGH: **0 unresolved**
- MEDIUM: **0 unresolved**
- Coverage inventory: PASS
- Coverage-driven development corpus: PASS
- Multi-turn/context regression: PASS
- Structural valid-empty semantic boundary: PASS
- Diagnostic neighbor/counterexample regression: PASS
- Fresh final held-out: **PASS 12/12**
- Full CI: **PASS (#1141)**
- Operational Safety: **PASS (#236)**
- Physical F2: NOT EXECUTED BY THIS LANE
- Main merge: NO
- Production deploy: NO
- Additional live Gemini: NOT EXECUTED FOR SAFETY/ISOLATION REASON ABOVE

## 8. Remaining release action

PR #99 is ready for independent review / release decision. Main and production remain untouched by this lane. If a safe isolated Gemini canary is later available, run only the semantic-risk subset (AI consultation vs family action, mixed spans, ambiguity, broken speech) rather than replaying a fixed arbitrary case count.


## 9. Independent final review closeout

Independent review started from the previously reviewed PR head
`fcac0942b5b0b12e462b459d3b756de5ef788e3c` and fresh-read CURRENT
Requirements/design/source instead of relying on the lane self-review.

The review found four material safety/consistency defects and corrected them on
the PR branch before release:

1. **HIGH — scoped no-send could swallow an independent family action.**
   A whole-utterance hard no-mutation short-circuit could turn
   `この文はまだ送らない、牛乳はパパに買ってもらって` into conversation-only,
   even though the no-send scope applies to the first clause and the second
   clause is an explicit family action. The boundary now bypasses the global
   short-circuit only when no-mutation is clearly referent-scoped or an
   explicit separate-item boundary exists; unscoped `まだ送らない` remains
   fail-closed.

2. **HIGH — hiragana `まま` could invent Mama as recipient inside ordinary
   Japanese words.** Role recovery now masks lexical uses such as
   `わがまま`, `気まま`, `ありのまま`, `思うまま`,
   `なるがまま`, and `ままなら...` before family-role matching.
   Genuine speech input such as `ままにむかえおねがい` remains supported.

3. **HIGH — assignment-change conversational edits could make the preview
   disagree with the canonical task.** Generic pending-edit logic could change
   visible title/date while leaving `task_id` on the old pickup occurrence,
   so confirmation could execute a different assignment change than the user
   saw. Assignment-change kind/date edits now retarget an actual open canonical
   pickup/dropoff occurrence for that household/date; recipient corrections
   update the recipient safely; self-recipient correction cancels the now
   unnecessary assignment request. Unsupported time-only retargeting leaves
   the original draft unchanged and tells the user why.

4. **MEDIUM/HIGH — assistant conversation could falsely claim a mutation was
   performed.** Gemini was prompted not to claim `送信した/登録した`, but the
   response parser did not enforce it. Provider replies that claim an
   unperformed send/notification/registration/request are now rejected and the
   deterministic non-mutating fallback is used.

Permanent independent-review regressions were added for:

- scoped no-send + separate explicit family action;
- unscoped no-send remaining non-mutating;
- lexical `まま` false-role prevention and genuine hiragana Mama recovery;
- false assistant mutation-claim rejection;
- canonical pickup/dropoff correction-label mapping.

The sealed final held-out file
`lineNlFinalHeldOut20260912.test.ts` was **not modified** during this review;
its previously fresh result remains 12/12 and the new findings are captured in
diagnostic/permanent regression tests instead of contaminating held-out
evidence.

Independent-review implementation convergence head before this documentation
update: `d93ea6155dbe2058e66af772763daacb74168a35`.

Additional live Gemini calls during independent review: **0**. The same
isolation rationale in §6 still applies; no production Edge Function or paid
Supabase branch was created merely to manufacture new live evidence.
