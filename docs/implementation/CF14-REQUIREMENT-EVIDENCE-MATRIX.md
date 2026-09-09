# CF-14 Requirement Evidence / E2E Matrix — F1 Authoring

## Status

**CF-14 = FAIL / PENDING.** This document is F1 verification architecture and test-authoring evidence only. It is not an acceptance result.

F2 may mark CF-14 PASS only after every implementation lane has converged and all required evidence is executed against **one exact final HEAD**. Missing provider/device evidence must remain FAIL/PENDING; `skip` is never PASS.

## Authority and source cut

- F1 base HEAD: `6d93ba0d5b6ed1d6dbc3bbf8ec0a973f898d30ff`
- Requirements/UX SOT: `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`
- Governance: Accepted ADR `0012-requirements-ux-canonical-governance.md`
- Detailed design: non-conflicting `docs/design/current/`
- Historical implementation conformance: `docs/implementation/ISSUE-48-Q1-Q112-CONFORMANCE-MATRIX.md`

The Issue #48 matrix is useful implementation history, but its PASS labels are not sufficient CF-14 evidence when the actual requirement entry boundary was not exercised. F1 therefore adds a stricter evidence layer instead of rewriting that historical closeout record.

`AGENTS.md` was not present in the CURRENT root Contents API at this source cut. A stale/inconsistent tree lookup had exposed an `AGENTS.md` entry, but direct Contents/blob/raw reads returned 404; F1 does not claim it was read.

## Evidence taxonomy

| Evidence class | What it proves |
| --- | --- |
| `unit-domain` | Pure/domain invariant without transport claims |
| `db-rpc` | Canonical persistence/RPC state transition |
| `edge-api` | Authenticated Edge/API boundary and command contract |
| `browser` | Rendered user interaction/result, not source-string presence |
| `line-transport` | LINE Messaging API webhook/postback/reply boundary |
| `google-provider` | Controlled Google Calendar provider response boundary |
| `image-ocr-ai` | Actual image bytes through classify → OCR → AI → review/provenance |
| `physical-iphone-manual` | Real iPhone/PWA behavior that jsdom cannot establish |
| `cross-channel-concurrency` | Actual LINE and PWA racing the same canonical aggregate |
| `whole-day-scenario` | Clock-controlled morning → daytime → evening user journey |

## Requirement → scenario → boundary traceability

The executable manifest is `tests/evidence/cf14/scenarios.mjs`. It validates that every Q1–Q112 appears in at least one scenario and that no F1 scenario can declare `PASS`.

| Scenario | Requirement IDs | Entry boundary | Required evidence | F1 state |
| --- | --- | --- | --- | --- |
| CF14-TODAY-DAY-FLOW | Q1,Q9,Q13,Q15,Q23,Q24,Q35,Q40,Q68,Q75,Q87 | PWA Today route at controlled clock | domain, DB, browser, iPhone, whole-day | expected-failing / Today owner |
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
| CF14-NAVIGATION-RETURN | Q77 | PWA secondary nav → back/return | browser, iPhone | external-pending |
| CF14-DUPLICATE-TERMINAL-GUARDS | Q81,Q82 | Edge duplicate/stale/terminal mutation | domain, DB, Edge, concurrency | external-pending |
| CF14-Q58-DEFERRED-DAG | Q58 | domain/schema/user-surface audit | domain | runnable |
| CF14-SHOPPING-ACTION | Q33 | PWA shopping completion | domain, DB, Edge, browser | external-pending |
| CF14-Q107-Q109-SHOPPING-INTERACTION | Q107-Q109 | rendered PWA anyone-owner interaction | DB, Edge, browser | runnable now (browser slice authored) |
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
- browser Loading/Error/Stale observation runner
- Back/return-state journey runner
- explicit JST clock-boundary runner for weekday 06:30, weekend/holiday 09:00, and 20:30 evening edges
- Nursery actual-image-byte runner; requires classify/OCR/AI/review, provenance, no pre-confirm mutation, and representative OCR/source hints
- signed LINE HTTP envelope runner using the Messaging API `X-Line-Signature` HMAC-SHA256 contract for text and postback fixtures
- LINE boundary runner that rejects DB/RPC evidence as LINE transport evidence
- deterministic Google provider harness for Q110 change, Q111 delete, and Q112 duplicate resolution; rejects DB/RPC-only evidence
- LINE/PWA concurrency runner with final canonical readback
- whole-day ordered orchestration runner
- evidence assessor: missing required evidence is `PENDING` in authoring and `FAIL` in strict F2

Fixtures live in `tests/evidence/cf14/fixtures.mjs`. Nursery uses a synthetic Japanese nursery-notice PNG containing representative date/class/event/bring-item/submission text, not a 1x1 placeholder and not post-OCR candidate JSON.

## Today actual user-visible state evidence

`apps/web/src/features/today/Today.states.interaction.test.tsx` renders the real `Today` component while controlling its external data hooks. It establishes that:

- Loading renders `読み込み中…` and does not pretend the page has loaded.
- canonical Today read error remains an explicit user-visible alert rather than becoming empty success.
- `calendar_stale=true` reaches the real Today surface as `⚠ Google予定を最新化できていません`.

Existing `TodaySchedule.test.tsx` independently covers the stale calendar rendering. Physical-iPhone state and final converged whole-day behavior remain F2 evidence.

## Q107-Q109 actual interaction

`apps/web/src/features/shopping/AnyoneOwnerPage.interaction.test.tsx` renders the real component and clicks the real user actions while controlling only its external boundaries. It verifies:

- Q107/Q108: unclaimed `誰でもOK` item shows no claimant, click `自分がやる`, Edge action=`claim`, canonical workspace reload shows self claimant.
- Q108: another family claimant shows the takeover disclosure, click `引き継ぐ`, Edge action=`takeover`, canonical reload shows self claimant.
- Q109: rendering a self-claimed item performs no automatic Edge mutation; click `担当を戻す` is required and sends action=`release`.

This browser interaction is additive evidence. Q109's time-based “no automatic release by deadline” still needs its DB/domain evidence at F2; the browser test alone is deliberately not labeled sufficient.

## Tests runnable now

- `npm run test:cf14:authoring` — manifest, boundary harness, clock, signed LINE, controlled Google, Nursery, retry, concurrency, F2-guard self-tests. Must be GREEN; it does not claim product acceptance.
- normal Web Vitest suite includes `AnyoneOwnerPage.interaction.test.tsx` and `Today.states.interaction.test.tsx`.
- `npm run test:cf14:f2` — strict final evidence runner. It is expected to FAIL until an evidence payload from one final exact HEAD exists.

The default CI suite runs authoring tests, but deliberately does not run the expected-failing F2 acceptance command during lane development.

## Expected failures / ownership

| Evidence gap | Expected F1 result | Owner before F2 |
| --- | --- | --- |
| Q70/Q71 raw natural-language through production LINE interpretation | FAIL/PENDING | LINE/Concierge implementation lane |
| Request lifecycle against converged Request implementation | FAIL/PENDING | Request lane |
| Today physical-device/whole-day/transport clock behavior after convergence | FAIL/PENDING | Today/notification owner + F2 |
| Nursery actual provider classify/OCR/AI from representative image bytes | FAIL/PENDING | Nursery/provider integration owner |
| LINE Messaging API real webhook/postback transcript | FAIL/PENDING | F2 with controlled LINE credentials |
| Google Calendar real controlled-provider boundary | FAIL/PENDING | Google lane + F2 provider run |
| actual simultaneous LINE/PWA race | FAIL/PENDING | F2 after convergence |
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

A missing record, skipped provider run, stale artifact from another HEAD, source-string assertion, or manually relabeled old evidence cannot close CF-14.

## F1 exit condition

F1 is ready to hand to F2 when:

1. authoring tests are green,
2. actual-interaction tests added by F1 are green,
3. expected failures are attributable to implementation/provider/device owners,
4. no production business semantics were changed,
5. the final F2 run is still explicitly pending.

**Current verdict remains CF-14 FAIL / PENDING.**
