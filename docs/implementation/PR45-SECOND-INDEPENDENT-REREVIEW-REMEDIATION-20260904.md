# PR #45 — second independent re-review remediation

This addendum is authoritative for the second independent re-review findings against historical PR #45 head `768cf228378f3982c72acbed04fdb5a4a13c3ca0`.

The historical review verdict was:

- BLOCKER: 0
- HIGH: 1
- MEDIUM: 1
- LOW: 0
- Verdict: NO-GO

The final independent reviewer must fresh-read CURRENT source at the exact PR head recorded in the PR body. This document describes the remediation contract; CURRENT source and exact-head CI remain authoritative.

## HIGH — DD9 `current_snapshot_hash` / model technical-field durable escape hatch

### Historical failure

The nursery extraction command accepted AI/model supplied `current_snapshot_hash` when it matched 64 hex characters and persisted that caller value into `public.change_candidates.current_snapshot_hash`. A caller could therefore encode 32 reversible arbitrary bytes per candidate and use a nominal hash field as durable pre-review storage for third-party PII. Model supplied `target_id` was also not a trusted canonical target binding.

### Current remediation

Migration:

- `supabase/migrations/20260904000001_dd9_pre_review_candidate_technical_field_minimization.sql`

The durable table boundary now applies a BEFORE INSERT and BEFORE UPDATE minimizer to nursery-extraction `ai_inference` rows. When `source_ref` resolves to the same-household/same-test-context `private.document_extractions` row, the trigger forces:

- `current_snapshot_hash = NULL`
- `target_id = NULL`

This is intentionally stronger than only changing `private.fn_command_record_nursery_extraction_v1`: a future service-role insertion/update path cannot re-open the same covert channel while the row remains a nursery pre-review AI candidate.

Caller/model supplied values are therefore not trusted technical metadata. If a later workflow needs a target binding or snapshot hash, a trusted server-side resolver must bind the target and/or compute the snapshot from the canonical target after the appropriate human-confirmation boundary rather than persisting model supplied bytes.

### Adversarial coverage

Test:

- `tests/sql/53_second_independent_rereview_remediation.sql`

It constructs 32 AI candidates. Each candidate supplies a valid 64-hex `current_snapshot_hash` that is demonstrably reversible to 32 caller-controlled bytes containing third-party/contact-shaped data, and also supplies a model-controlled `target_id`.

The test requires:

1. the hostile request reaches the normal `review` boundary;
2. all 32 durable review-marker rows exist;
3. every durable row has `current_snapshot_hash IS NULL` and `target_id IS NULL`;
4. a subsequent service-role UPDATE attempting to rehydrate both fields is also minimized back to NULL.

At remediation code head `04f03d811cb0a2cdb62e9188ff18bfccf031771b`, CI run #400 DB evidence includes:

- `52_independent_rereview_high_remediation: PASS`
- `53_second_independent_rereview_remediation: PASS`
- `98_dd11_full_readiness_zero: PASS`
- `99_canonical_reconciliation_zero: PASS`
- all true-parallel concurrency tests PASS

The final review anchor is the later documentation-inclusive exact head and exact-head CI recorded in the PR body, not this intermediate code head.

## MEDIUM — DD8 DELETE must never degrade to unconditional mutation

### Historical failure

`getEvent()` allowed HTTP 200 with a nullable/missing ETag, while `deleteEvent()` accepted an optional `ifMatchEtag`. In an abnormal provider response, Task DELETE or target deletion could therefore omit `If-Match`, undermining the provider-side ETag handoff proof used to fence stale mutations.

### Current remediation

Source:

- `supabase/functions/_shared/googleCalendar.ts`

`GoogleEventGetResult` is now discriminated:

- 404 => `body: null`, `etag: null`
- 200 => `body` present and `etag: string`

For HTTP 200, `getEvent()` requires a non-empty trimmed ETag. A missing/empty ETag throws before the worker establishes provider mutation authorization and before DELETE is attempted.

`deleteEvent()` now:

- requires `ifMatchEtag: string` at the TypeScript boundary;
- rejects an empty/whitespace ETag before `fetch()`;
- always emits the `If-Match` header for an existing-event DELETE.

This contract is shared by both Task mirror DELETE and target-deletion flows.

### Adversarial coverage

Test:

- `supabase/functions/process-family-ops-calendar-outbox/deleteEtagFence.test.ts`

It verifies:

1. Task DELETE: GET 200 without ETag fails closed before provider authorization/delete;
2. target deletion: GET 200 without ETag fails closed before provider authorization/delete;
3. direct `deleteEvent()` with an empty ETag sends no provider request;
4. valid DELETE always carries the exact `If-Match` header.

At remediation code head `04f03d811cb0a2cdb62e9188ff18bfccf031771b`, CI run #400 Edge evidence shows all four tests PASS, the prior provider-mutation fence tests PASS, the 412 -> re-GET -> new ETag provider handoff test PASS, Deno type-check PASS, and the complete Edge unit suite reports 114 passed / 0 failed.

Again, the final review anchor is the documentation-inclusive exact PR head and exact-head CI recorded in the PR body.

## Regression areas that remain required in independent review

The reviewer should still independently verify that these remediations do not regress previously-passing contracts:

- DD8 durable `inflight` / `uncertain` provider mutation fence;
- DD8 provider-side handoff token + ETag advancement barrier and DD11 blocking of unresolved/unconsumed fence state;
- DD9 prior free-text minimization for facts, source locators, AI title/notes/explanation, school/class text, and technical metadata sanitizer idempotency;
- DD10 completed archive receipt replay and active-context guard;
- Request terminal-state safety after linked Task completion;
- Handover legacy/canonical acknowledgement compatibility;
- R0 canonical-reader fence and explicit Shopping `legacy_r0` compatibility;
- DD11 Shopping `anyone` reconciliation and final-zero gates;
- test-context isolation from production notification, Google, canonical-reader, and analytics paths.

## Activation boundary

This remediation does not authorize production activation.

PR #45 must remain Draft and unmerged during review. No production migration apply, Edge deployment, P1 activation, real LINE delivery, or real Google provider mutation is part of this source-review gate.
