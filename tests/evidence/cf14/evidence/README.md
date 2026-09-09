# CF-14 F2 evidence capture

F2 evidence is acceptance evidence for Family Ops behavior on one exact converged HEAD. It is not a checklist of test names.

A PASS record must prove the declared entry boundary and, where applicable, the family-visible result. A source string by itself is never sufficient for browser, LINE, Google, Nursery, physical-iPhone, concurrency, or whole-day evidence.

## Common PASS fields

Every PASS record requires:

- `scenarioId`
- `evidenceClass`
- `status: "PASS"`
- `exactHead` — the same 40-character SHA as the F2 payload
- `capturedAt` — timestamp with explicit timezone
- `source` — artifact bundle or transcript reference
- `details.entryBoundary` — the boundary actually exercised

The class-specific `details` below are enforced by `evidence-records.mjs`.

## Evidence-class minimums

| Evidence class | Minimum substantive proof |
| --- | --- |
| `unit-domain` | named assertions |
| `db-rpc` | canonical readback artifact + assertions |
| `edge-api` | request artifact + response artifact + assertions |
| `browser` | interaction trace/artifact + steps + visible assertions + browser/viewport |
| `line-transport` | provider event id + webhook/request artifact + reply artifact + family-visible result |
| `google-provider` | provider event id + operation + provider-response artifact + family-visible result |
| `image-ocr-ai` | raw image artifact + classify→OCR→AI→review stage evidence + provenance + review artifact + visible assertions |
| `physical-iphone-manual` | device model + iOS version + Safari/installed-PWA surface + interaction steps + screenshots + visible assertions |
| `cross-channel-concurrency` | LINE artifact + PWA artifact + canonical readback + measured concurrency window + visible assertions |
| `whole-day-scenario` | at least three timezone-explicit clocked steps + visible assertions |

## Browser example

```json
{
  "scenarioId": "CF14-NAVIGATION-RETURN",
  "evidenceClass": "browser",
  "status": "PASS",
  "exactHead": "<final sha>",
  "capturedAt": "2026-09-10T12:00:00+09:00",
  "source": "artifact://browser/navigation-return",
  "details": {
    "entryBoundary": "PWA navigation from daily flow to secondary management and back",
    "interactionArtifact": "artifact://browser/navigation-return/trace.zip",
    "interactionSteps": ["open Today", "open secondary management", "return"],
    "visibleAssertions": ["selection and material daily context remain visible after return"],
    "environment": {
      "browser": "Mobile Safari 26.6",
      "viewport": "393x852"
    }
  }
}
```

## Physical iPhone manual capture

Physical-device evidence must be captured on the same final HEAD used by every other F2 record.

For each physical-iPhone scenario:

1. record the exact device model and iOS version;
2. state whether the surface is `installed-pwa` or `safari`;
3. start from the actual user entry point, not a deep internal test route unless the Requirement itself starts there;
4. perform the user journey without developer tools substituting for taps/navigation;
5. capture screenshots at the material before/after states;
6. record the user-visible assertions from the scenario manifest;
7. mark FAIL if content is clipped, hidden, reset unexpectedly, semantically different from approved UX, or technically successful but confusing for the family.

A physical-iPhone PASS is not permitted from jsdom, desktop responsive mode, source inspection, or a screenshot with no interaction history.

## Provider capture

### LINE

Keep both sides of the provider boundary:

- signed webhook/postback request artifact;
- provider event id;
- actual reply artifact;
- the family-visible reply/result;
- canonical readback when the scenario also requires DB/RPC evidence.

HTTP 2xx, signature verification, or DB mutation alone does not establish LINE UX acceptance.

### Google Calendar

Keep:

- provider event id and operation;
- controlled provider response artifact;
- resulting review/candidate state;
- family-visible review result.

A DB/RPC projection without the provider response is not Google-provider evidence.

## Nursery capture

The first artifact must be the representative raw notice image. Evidence that starts from OCR text, extracted fields, or candidate JSON is invalid for `image-ocr-ai`.

The record must preserve evidence of classify → OCR → AI → review in order, source provenance, the human review artifact, and the material values visible before confirmation.

## Cross-channel concurrency capture

Capture LINE and PWA operations separately, record the measured start/concurrency window, then capture one canonical readback after both settle. The family-visible result must show convergence; a stale loser must not silently overwrite the winner.

## Whole-day capture

Use timezone-explicit timestamps and preserve the order of at least morning, daytime, and evening steps. The acceptance question is continuity for a real household day: no lost state, hidden work, duplicate noise, or UX regression between channels.

## Acceptance rule

Even a structurally complete PASS record does not override a scenario still marked `expected-failing` or `skeleton`. Known Requirement/approved-UX gaps must be fixed by their owning implementation lane before F2 can pass.
