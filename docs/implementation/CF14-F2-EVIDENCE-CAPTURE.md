# CF-14 F2 Evidence Capture Contract

## Status

This is the execution contract for final CF-14 verification after all implementation lanes converge on one exact final HEAD.

**CF-14 remains FAIL / PENDING until that final execution happens.**

The acceptance order is:

1. Family Ops purpose / household outcome
2. canonical Requirements
3. approved UX
4. real user-visible behavior
5. technical correctness/evidence

Technical evidence can support acceptance; it cannot override a known Requirement or approved-UX mismatch.

## Why this file exists

A PASS record must not be manufacturable from a test name, a Q-number, a source-string assertion, a DB-only simulation for a provider scenario, or a screenshot with no user interaction history.

The executable validator is `tests/evidence/cf14/evidence-records.mjs`. The capture checklist is `tests/evidence/cf14/evidence/README.md`.

## Common F2 payload

```json
{
  "exactHead": "<40-char converged final SHA>",
  "records": [
    {
      "scenarioId": "CF14-Q27-LINE-WEBHOOK-POSTBACK",
      "evidenceClass": "line-transport",
      "status": "PASS",
      "exactHead": "<same SHA>",
      "capturedAt": "2026-09-10T12:00:00+09:00",
      "source": "artifact://cf14/q27-line",
      "details": {
        "entryBoundary": "actual LINE Messaging API webhook/postback",
        "providerEventId": "<provider event id>",
        "requestArtifact": "artifact://cf14/q27-line/webhook.json",
        "replyArtifact": "artifact://cf14/q27-line/reply.json",
        "userVisibleResult": "<actual family-visible reply>"
      }
    }
  ]
}
```

`source` is only the bundle pointer. It does **not** make the record substantive by itself. Class-specific `details` are mandatory.

## Class-specific proof

| Evidence class | Required proof |
| --- | --- |
| `unit-domain` | assertions exercised at domain boundary |
| `db-rpc` | canonical readback artifact + assertions |
| `edge-api` | actual request/response artifacts + assertions |
| `browser` | **real browser** interaction artifact/trace + steps + visible assertions + browser/viewport; jsdom/happy-dom/Vitest are not browser evidence |
| `line-transport` | provider event id + webhook/postback artifact + reply artifact + family-visible result |
| `google-provider` | provider event id + operation + provider response artifact + family-visible result |
| `image-ocr-ai` | raw image artifact + classify→OCR→AI→review evidence + provenance + review artifact + visible assertions |
| `physical-iphone-manual` | physical iPhone/iOS + Safari/PWA surface + interaction steps + screenshots + visible assertions |
| `cross-channel-concurrency` | LINE artifact + PWA artifact + measured concurrency window + canonical readback + visible assertions |
| `whole-day-scenario` | timezone-explicit chronological morning/daytime/evening timeline + visible assertions |

## F2 fail-closed rules

`scripts/run_cf14_f2.mjs` must FAIL when any of these is true:

- evidence payload HEAD differs from runtime HEAD;
- PASS record HEAD differs from payload HEAD;
- PASS record has no captured timestamp with timezone;
- PASS record has no substantive class-specific details;
- browser evidence has no interaction artifact/steps/visible assertions or identifies a simulated DOM/test runner instead of a real browser;
- LINE evidence has no actual reply artifact/family-visible result;
- Google evidence begins after the provider boundary;
- Nursery evidence begins after image intake/OCR;
- physical-iPhone evidence comes from desktop responsive emulation, lacks real iPhone/iOS identity, or has no screenshots/interaction history;
- concurrency evidence does not contain both LINE and PWA sides plus canonical readback;
- whole-day evidence is not timezone-explicit and chronological through multiple material day steps;
- required evidence class is missing;
- the scenario is still `expected-failing` or `skeleton` because a known Requirement/approved-UX gap remains.

## Manual physical-iPhone standard

For scenarios requiring `physical-iphone-manual`, F2 must use a real iPhone. Record:

- device model;
- iOS version;
- `installed-pwa` or `safari`;
- exact final HEAD/deployment under test;
- user journey from the actual Requirement entry point;
- material before/after screenshots;
- scenario user-visible assertions;
- any clipping, hidden content, confusing wording, unexpected reset, duplicate noise, or behavior that contradicts approved UX.

A technically functioning action is FAIL if the family-facing result is materially worse or contradicts the approved experience.

## Relationship to F1

F1 authors the architecture, harnesses and evidence requirements. It does not fabricate external/device proof and does not modify out-of-scope product behavior merely to make the verifier green.

Vitest/React Testing Library component interaction tests authored in F1 are useful regression evidence, but they do **not** satisfy the final `browser` or `physical-iphone-manual` evidence classes by themselves.

F1 also runs a real headless Chrome authoring journey (`npm run test:cf14:browser`) for Today Loading/Ready/Stale/Error and Back/return behavior. That run is stronger than jsdom because it executes the real built application DOM and browser HTTP boundary, and it stores screenshots plus `evidence.json`. However, it uses controlled test-only Supabase HTTP responses and explicitly records `physicalDevice: false`.

Therefore the F1 Chrome artifact is a **browser harness/proof-of-execution artifact**, not an automatic final F2 PASS record. F2 must rerun the required browser scenarios against the one converged final HEAD and the final deployment/service boundary required by the scenario. It also cannot substitute the Chrome artifact for physical iPhone/Safari/PWA evidence.

Final F2 execution starts only after implementation lanes converge and the exact final HEAD is known.
