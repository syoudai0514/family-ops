# CF-14 Requirement Evidence / E2E Matrix — F1 Authoring

## Status

**CF-14 = FAIL / PENDING.** This document is F1 verification architecture and test-authoring evidence only. It is not an acceptance result.

F2 may mark CF-14 PASS only after every implementation lane has converged and all required evidence is executed against **one exact final HEAD**. Missing provider/device evidence must remain FAIL/PENDING; `skip` is never PASS.

**Acceptance priority:** technical completeness is subordinate to Family Ops purpose, Requirements compliance, approved UX, and real family usability. A green unit/DB/Edge/browser/provider suite cannot override a known product or UX mismatch.

## Authority and source cut

- F1 base HEAD: `6d93ba0d5b6ed1d6dbc3bbf8ec0a973f898d30ff`
- Requirements/UX SOT: `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`
- Governance: Accepted ADR `0012-requirements-ux-canonical-governance.md`
- Detailed design: non-conflicting `docs/design/current/`
- Historical implementation conformance: `docs/implementation/ISSUE-48-Q1-Q112-CONFORMANCE-MATRIX.md`

The Issue #48 matrix is useful implementation history, but its PASS labels are not sufficient CF-14 evidence when the actual requirement entry boundary or approved user experience was not exercised. F1 therefore adds a stricter evidence layer instead of rewriting that historical closeout record.

`AGENTS.md` was not present in the CURRENT root Contents API at this source cut. A stale/inconsistent tree lookup had exposed an `AGENTS.md` entry, but direct Contents/blob/raw reads returned 404; F1 does not claim it was read.

## Evidence taxonomy

| Evidence class | What it proves |
| --- | --- |
| `unit-domain` | Pure/domain invariant without transport claims |
| `db-rpc` | Canonical persistence/RPC state transition |
| `edge-api` | Authenticated Edge/API boundary and command contract |
| `browser` | Real rendered browser interaction/result at the declared entry boundary; jsdom/source-string presence alone is insufficient |
| `line-transport` | LINE Messaging API webhook/postback/reply boundary |
| `google-provider` | Controlled Google Calendar provider response boundary |
| `image-ocr-ai` | Actual image bytes through classify → OCR → AI → review/provenance |
| `physical-iphone-manual` | Real iPhone/PWA behavior that desktop Chrome/jsdom cannot establish |
| `cross-channel-concurrency` | Actual LINE and PWA racing the same canonical aggregate |
| `whole-day-scenario` | Clock-controlled morning → daytime → evening user journey |

No evidence class is inherently sufficient by itself. Every scenario also carries a **user-visible assertion**. If the technical path works but the user-visible result conflicts with the Requirements or approved UX, the scenario remains FAIL/PENDING.

Component interaction tests remain useful regression evidence, but F1 does not relabel React Testing Library/jsdom as `browser`, nor desktop responsive emulation as `physical-iphone-manual`.

## Requirement → scenario → boundary traceability

The executable manifest is `tests/evidence/cf14/scenarios.mjs`. It validates that every Q1–Q112 appears in at least one scenario and that no F1 scenario can declare `PASS`.

| Scenario | Requirement IDs | Entry boundary | Required evidence | F1 state |
| --- | --- | --- | --- | --- |
| CF14-TODAY-DAY-FLOW | Q1,Q9,Q13,Q15,Q23,Q24,Q35,Q40,Q68,Q75,Q87 | PWA Today route at controlled clock | domain, DB, browser, iPhone, whole-day | expected-failing / real-browser state subset authored; Today+iPhone+whole-day pending |
| CF14-REQUEST-LIFECYCLE | Q2,Q30,Q36,Q41-Q47,Q51 | PWA + LINE Request entry | domain, DB, Edge, browser, LINE | expected-failing / Request owner |
| CF14-HANDOVER-SHARE | Q3,Q16,Q37,Q38,Q48,Q49 | PWA/LINE share/ack | domain, DB, Edge, browser, LINE | external-pending |
| CF14-CHECKIN-RECONCILIATION | Q5,Q6,Q31,Q53,Q54,Q59-Q61,Q63,Q64,Q76 | PWA/LINE check-in | domain, DB, Edge, browser, LINE, whole-day | external-pending |
| CF14-TASK-QUICK-ADD | Q8,Q21,Q22,Q55-Q57,Q69,Q74 | PWA Quick Add/task interaction | domain, DB, Edge, browser | external-pending |
| CF14-PLANNING-ASSIGNMENT | Q10-Q12,Q50,Q52,Q83-Q86 | assignment/rule change | domain, DB, Edge, browser, LINE, concurrency | external-pending |
| CF14-EVENT-PLANNING | Q17-Q19 | event planning/review | domain, DB, Edge, browser | external-pending |
| CF14-HISTORY-ACTUALS | Q7,Q20,Q28,Q29,Q32,Q62 | History/actuals UI | domain, DB, browser | external-pending |
| CF14-NOTIFICATION-SCHEDULE | Q14,Q25,Q26,Q88 | scheduler → LINE delivery at explicit JST clock | domain, DB, Edge, LINE, whole-day | external-pending |
| CF14-LINE-DAILY-ENTRY | Q4,Q39,Q65-Q67,Q72,Q73,Q78-Q80 | actual LINE webhook/postback | domain, DB, Edge, LINE, browser, concurrency | external-pending |
| CF14-Q27-LINE-WEBHOOK-POSTBACK | Q27 | signed LINE-compatible HTTP webhook/postback, then actual provider in F2 | DB, Edge, LINE | external-pending |
| CF14-Q70-RAW-MULTI-INTENT | Q70 | raw LINE text before candidates | domain, Edge, LINE | expected-failing / interpretation owner |
| CF14-Q71-RAW-AMBIGUITY | Q71 | raw LINE text with one ambiguity | domain, Edge, LINE | expected-failing / interpretation owner |
| CF14-NAVIGATION-RETURN | Q77 | PWA secondary nav → back/return | browser, iPhone | real Chrome authoring evidence GREEN; physical iPhone pending |
| CF14-DUPLICATE-TERMINAL-GUARDS | Q81,Q82 | Edge duplicate/stale/terminal mutation | domain, DB, Edge, concurrency | external-pending |
| CF14-Q58-DEFERRED-DAG | Q58 | domain/schema/user-surface audit | domain | runnable |
| CF14-SHOPPING-ACTION | Q33 | PWA shopping completion | domain, DB, Edge, browser | external-pending |
| CF14-Q107-Q109-SHOPPING-INTERACTION | Q107-Q109 | rendered PWA anyone-owner interaction | DB, Edge, browser | **expected-failing / Shopping UX owner** |
| CF14-NURSERY-ACTUAL-INPUT | Q89-Q106 | representative image bytes before OCR/AI | DB, Edge, LINE, image/OCR/AI, browser | expected-failing / Nursery+provider |
| CF14-GOOGLE-BASELINE | Q34 | controlled Google provider response | DB, Edge, Google, browser | external-pending |
| CF14-Q110-Q112-GOOGLE-PROVIDER | Q110-Q112 | controlled Google change/delete/duplicate response | DB, Edge, Google, browser | controlled harness authored; real provider pending |
| CF14-LINE-PWA-CONCURRENT-RACE | cross-cuts Q78,Q79,Q81,Q84,Q108,Q109 | concurrent actual LINE + PWA | DB, Edge, browser, LINE, concurrency | external-pending |
| CF14-WHOLE-DAY-ORCHESTRATION | cross-cuts Q1,Q5,Q9,Q14,Q23,Q25,Q26,Q39,Q40,Q63,Q75,Q87,Q88 | morning → daytime → evening | browser, LINE, iPhone, concurrency, whole-day | skeleton |

The executable manifest, not this compressed table, is the checkable coverage record.

## F1 harnesses authored

`tests/evidence/cf14/harness.mjs` and the adjacent boundary harnesses provide reusable drivers rather than copies of production business semantics:

- raw-language Q70/Q71 corpus runner; rejects prebuilt `candidateJson`
- response-loss/retry runner; requires one canonical mutation + replay
- Request lifecycle/stale/expiry fixture validator
- component Loading/Error/Stale observation runner
- Back/return-state journey runner
- dependency-free real-Chrome/CDP authoring runner for Today Loading/Ready/Stale/Error + Back/return, using test-only HTTP interception at the Supabase boundary
- explicit JST clock-boundary runner for weekday 06:30, weekend/holiday 09:00, and 20:30 evening edges
- Nursery actual-image-byte runner; requires classify/OCR/AI/review, provenance, no pre-confirm mutation, and representative OCR/source hints
- signed LINE HTTP envelope runner using the Messaging API `X-Line-Signature` HMAC-SHA256 contract for text and postback fixtures
- LINE boundary runner that rejects DB/RPC evidence as LINE transport evidence
- deterministic Google provider harness for Q110 change, Q111 delete, and Q112 duplicate resolution; rejects DB/RPC-only evidence
- LINE/PWA concurrency runner with final canonical readback
- whole-day ordered orchestration runner
- evidence assessor: missing required evidence is `PENDING` in authoring and `FAIL` in strict F2
- acceptance blocker: a scenario still marked `expected-failing` or `skeleton` **cannot become F2 PASS solely because every technical evidence record is green**

Fixtures live in `tests/evidence/cf14/fixtures.mjs`. Nursery uses a synthetic Japanese nursery-notice PNG containing representative date/class/event/bring-item/submission text, not a 1x1 placeholder and not post-OCR candidate JSON.

## Today state / navigation evidence

There are now two deliberately separate evidence layers.

### Component regression layer

`apps/web/src/features/today/Today.states.interaction.test.tsx` renders the real `Today` component while controlling its external data hooks. It establishes that:

- Loading renders `読み込み中…` and does not pretend the page has loaded.
- canonical Today read error remains an explicit user-visible alert rather than becoming empty success.
- `calendar_stale=true` reaches the real Today surface as `⚠ Google予定を最新化できていません`.

Existing `TodaySchedule.test.tsx` independently covers the stale calendar rendering. These are useful component regressions, not final `browser` or device evidence.

### Real-Chrome F1 authoring layer

`scripts/run_cf14_browser_e2e.mjs`, supervised by `scripts/run_cf14_browser_e2e_ci.mjs`, launches the actual web app in a real headless Chrome/Chromium process and exercises the DOM and HTTP boundaries rather than jsdom. The CI artifact contains screenshots plus `evidence.json` and is exact-head named.

The runner proves the following F1 authoring scenarios:

1. **Loading:** while the canonical Today brief read is deliberately unresolved, the real rendered page visibly shows `読み込み中…`.
2. **Ready:** after HTTP reads complete, the rendered Today route visibly shows `今日の状況` and the representative task.
3. **Back/return:** Today → Concierge → draft entry → `戻る` → Today → Concierge preserves the Concierge draft and keeps Today reachable.
4. **Stale refresh:** a real task interaction succeeds, the subsequent canonical Today refresh fails, `読み込みに失敗しました。` is visible, and the previously rendered task remains visible rather than disappearing into false empty success.
5. **Initial Error:** a failing canonical read on fresh Today navigation renders `読み込みに失敗しました。` as the family-visible failure.

The test-only Supabase service is intercepted at the real browser HTTP boundary. F1 is therefore proving browser rendering/interaction against controlled service responses, not claiming a production provider/deployment run. The artifact explicitly records `physicalDevice: false` and cannot satisfy `physical-iphone-manual`.

This closes the F1 authoring gap where Today state and Q77 return behavior existed only in jsdom. It still does **not** close daypart ordering/content, actual production deployment behavior, physical iPhone/PWA clipping/safe-area behavior, scheduler delivery, or whole-day continuity.

## Q88 clock boundaries

The authoring harness covers explicit JST boundary pairs rather than merely placing 06:30/20:30 timestamps inside a whole-day skeleton:

- weekday `06:29:59` → `06:30:00`
- weekend `08:59:59` → `09:00:00`
- holiday `08:59:59` → `09:00:00`
- evening `20:29:59` → `20:30:00`

The harness rejects evidence that loses the explicit `+09:00` clock. Final Q88 acceptance still requires actual scheduler/delivery behavior and user-visible LINE evidence, not just the clock fixture.

## Q107-Q109 interaction — state transition is not UX acceptance

`apps/web/src/features/shopping/AnyoneOwnerPage.interaction.test.tsx` renders the real component and exercises the real claim/takeover/release commands. It proves useful state-transition behavior:

- Q107/Q108: unclaimed `誰でもOK` can be claimed using `自分がやる`, then canonical reload shows the current user as claimant.
- Q108: `引き継ぐ` sends `takeover` and canonical reload converges on the new claimant.
- Q109: merely rendering a self-claimed item does not release it; a user action is required before `release` is sent.

However, the Requirements/approved UX are stronger and CURRENT does not yet satisfy them:

1. **Q108:** takeover must show who is currently acting (`現在○○が対応中`) before takeover. CURRENT only says `現在: 家族が対応中`, so the user cannot tell who already owns the work.
2. **Q109:** the approved claimant release action is `[手放す]`. CURRENT labels it `担当を戻す`.
3. **Q109:** deadline arrival must not auto-release a claim. The current component interaction proves only “no release on render”; DB/domain + clock evidence is still required.
4. **Q107:** `誰でもOK` as a formal assignment type still needs domain/DB evidence in addition to the page interaction.

Therefore Q107-Q109 is **expected-failing / FAIL-PENDING**, even though the state-transition portion is green. The two known Q108/Q109 approved-UX mismatches are executed as Vitest `it.fails` assertions, not skipped TODOs; a product fix that makes them unexpectedly pass therefore forces the test owner to remove the expected-failure marker and reclassify evidence deliberately.

## F2 acceptance precedence

`assessEvidence(..., { strict: true })` enforces the following:

- required technical evidence missing → `FAIL`
- every technical evidence class green, but scenario remains `expected-failing` or `skeleton` → **`FAIL`**
- every required evidence class green and no known acceptance blocker → eligible for `PASS`

This prevents a known Requirement/UX defect from being hidden by adding more tests around the wrong behavior. The owning implementation lane must fix the product gap; only then can the scenario's blocking status/reason be cleared before F2 acceptance.

## Tests runnable now

- `npm run test:cf14:authoring` — manifest, boundary harness, clock, signed LINE, controlled Google, Nursery, retry, concurrency, F2-guard self-tests. Must be GREEN; it does not claim product acceptance.
- `npm run test:cf14:browser` — real headless Chrome F1 authoring run for Today Loading/Ready/Stale/Error and Back/return; writes screenshots + `evidence.json`. It is real-browser evidence, but deliberately not physical-iPhone or final-production evidence.
- normal Web Vitest suite includes `AnyoneOwnerPage.interaction.test.tsx` and `Today.states.interaction.test.tsx`.
- `npm run test:cf14:f2` — strict final evidence runner. It is expected to FAIL until an evidence payload from one final exact HEAD exists **and every known acceptance blocker is cleared**.

The default CI suite runs both F1 authoring self-tests and the real-browser authoring run, but deliberately does not run the expected-failing F2 acceptance command during lane development.

## Expected failures / ownership

| Evidence/product gap | Expected F1 result | Owner before F2 |
| --- | --- | --- |
| Q70/Q71 raw natural-language through production LINE interpretation | FAIL/PENDING | LINE/Concierge implementation lane |
| Request lifecycle against converged Request implementation | FAIL/PENDING | Request lane |
| Today daypart ordering + production deployment + physical iPhone + whole-day experience | FAIL/PENDING | Today/notification owner + F2 |
| Q107-Q109 claimant identity / `[手放す]` UX / deadline non-release | FAIL/PENDING | Shopping/AnyoneOwner UX implementation owner + F2 |
| Nursery actual provider classify/OCR/AI from representative image bytes | FAIL/PENDING | Nursery/provider integration owner |
| LINE Messaging API real webhook/postback transcript | FAIL/PENDING | F2 with controlled LINE credentials |
| Google Calendar real controlled-provider boundary | FAIL/PENDING | Google lane + F2 provider run |
| actual simultaneous LINE/PWA race | FAIL/PENDING | F2 after convergence |
| Q88 actual scheduler → LINE delivery at JST boundary | FAIL/PENDING | scheduler/LINE owner + F2 |
| physical iPhone/PWA screenshots/journeys | FAIL/PENDING | F2 manual/device run |
| full whole-day scenario | FAIL/PENDING | F2 after all lanes converge |

A product defect discovered by these tests is not repaired in F1 unless it is test/evidence infrastructure itself. The defect is attributed to the owning implementation lane.

## F2 exact-HEAD evidence payload

The strict runner defaults to `tests/evidence/cf14/evidence/current.json` and requires both the payload and every PASS record to be bound to the exact runtime Git HEAD:

```json
{
  "exactHead": "<40-char final SHA>",
  "records": [
    {
      "scenarioId": "CF14-Q27-LINE-WEBHOOK-POSTBACK",
      "evidenceClass": "line-transport",
      "status": "PASS",
      "exactHead": "<same 40-char final SHA>",
      "source": "<provider transcript/artifact reference>"
    }
  ]
}
```

`scripts/run_cf14_f2.mjs` compares `exactHead` to the runtime repository HEAD (or an explicitly supplied `--head` / `CF14_EXACT_HEAD`), rejects PASS records from a different HEAD, and rejects PASS records without a non-empty artifact/source reference. Every scenario must then have PASS evidence for every class it declares.

A missing record, skipped provider run, stale artifact from another HEAD, source-string assertion, manually relabeled old evidence, or known Requirement/UX blocker cannot close CF-14.

The F1 Chrome artifact is not automatically imported as final F2 evidence. F2 must run against the one converged final HEAD and must use the final deployment/provider/device boundary demanded by each scenario.

## F1 exit condition

F1 is ready to hand to F2 when:

1. authoring tests are green,
2. component interaction tests and real-browser authoring tests added by F1 are green,
3. known product/UX mismatches remain explicitly FAIL/PENDING and are attributed to an implementation owner,
4. technical green is prevented from overriding a known Requirement/UX blocker,
5. no production business semantics were changed,
6. the final F2 run is still explicitly pending.

**Current verdict remains CF-14 FAIL / PENDING.**
