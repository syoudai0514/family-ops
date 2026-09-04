# PR #45 — third independent re-review remediation

This addendum is authoritative for the third independent review findings against historical PR #45 head `54daa1ef9c1a55ed946fe8ed2c565e069774c648`.

The historical verdict was:

- BLOCKER: 0
- HIGH: 1
- MEDIUM: 0
- LOW: 1
- Verdict: NO-GO

The final independent reviewer must fresh-read CURRENT source at the exact PR head recorded in the PR body. CURRENT source and exact-head CI remain authoritative.

## HIGH — DD9 `source_locator` was model-controlled durable provenance

### Historical failure

`private.fn_command_record_nursery_extraction_v1` accepted an extractor/model supplied `source_locator` when it matched:

`^(page|block|line|item):[0-9]{1,5}$`

and persisted it into `private.document_facts.source_locator`.

Syntax validation did not establish provenance. Because the caller/model controlled the numeric suffix, 64 individually valid locators could encode roughly 128 caller-controlled bytes and remain in pre-review durable structured storage even when the normalized business facts were correctly minimized.

### Current remediation

Migration:

- `supabase/migrations/20260904000002_dd9_pre_review_source_locator_minimization.sql`

There is currently no trusted server-issued locator inventory in R0. Therefore every `source_locator` attached to a `private.document_facts` row that resolves to a same-household / same-test-context `private.document_extractions` row is treated as untrusted extractor/model metadata.

The durable table boundary now:

1. scrubs pre-existing matching `source_locator` values to `NULL`;
2. applies a BEFORE INSERT trigger that forces `source_locator = NULL`;
3. applies a BEFORE UPDATE trigger that again forces `source_locator = NULL`, including later service-role re-injection attempts.

This is deliberately stronger than changing only `private.fn_command_record_nursery_extraction_v1`. A future service-role path cannot re-open the same covert channel while it persists a fact linked to the document-extraction boundary.

A future product requirement for exact source provenance must introduce trusted server-side provenance, for example a server-generated locator inventory tied to the source document and a validated ID/reference. Model output may select a trusted existing locator; it must not manufacture durable locator values.

## Adversarial coverage — SQL #54

Test:

- `tests/sql/54_third_independent_rereview_source_locator.sql`

The test constructs a 128-byte caller-controlled payload containing third-party/contact-shaped data and divides it into 64 two-byte integers. It emits all 64 values as syntactically valid `item:NNNNN` locators.

Before invoking the command, the test reconstructs the exact original 128 bytes from those numeric locator suffixes and asserts byte-for-byte equality. This proves that the fixture is a real reversible storage channel rather than merely suspicious formatting.

The test then requires:

1. all 64 hostile facts reach the ordinary nursery `review` boundary;
2. all 64 minimized durable `private.document_facts` rows exist;
3. every durable row has `source_locator IS NULL`;
4. a later service-role UPDATE attempting `source_locator='item:18537'` is minimized back to `NULL`.

At remediation code head `75fbe6d3fd176d63d749455def95e3f524e7922b`, CI run #405 DB evidence includes:

- `52_independent_rereview_high_remediation: PASS`
- `53_second_independent_rereview_remediation: PASS`
- `54_third_independent_rereview_source_locator: PASS`
- `98_dd11_full_readiness_zero: PASS`
- `99_canonical_reconciliation_zero: PASS`
- all true-parallel concurrency tests PASS

The final review anchor is the later documentation-inclusive exact head and exact-head CI recorded in the PR body, not this intermediate code head.

## Previous DD9 privacy remediations remain in force

The independent reviewer should still verify that the complete pre-review durable boundary has no equivalent model-controlled escape hatch. Prior remediations cover, among others:

- free-text fact notes;
- title / notes / explanation in AI candidates;
- school/class free text;
- provider/model metadata minimization and idempotency;
- `current_snapshot_hash`;
- model-supplied `target_id`;
- now `source_locator`.

The invariant is semantic, not field-name-based: model-controlled strings, bytes, numeric cells, UUID-like fields, hash-like fields, base64/hex-like fields, or nominal metadata must not become reversible third-party durable storage merely because they satisfy a syntactic type.

## LOW — DD8 missing-ETag test precision

The third review also returned a LOW because the previous missing-ETag tests proved provider DELETE was not sent, but did not directly assert that the DB authorization callback was never invoked.

### Current remediation

Production source:

- `supabase/functions/process-family-ops-calendar-outbox/conditionalDeleteWorkflow.ts`
- `supabase/functions/process-family-ops-calendar-outbox/index.ts`

Tests:

- `supabase/functions/process-family-ops-calendar-outbox/deleteEtagFence.test.ts`

Both Task mirror DELETE and stale target deletion now call the same production `deleteExistingEventWithFence` workflow. Its ordering is explicit and dependency-injected:

`read provider event -> require usable 200 ETag -> fresh DB authorize/fence -> conditional DELETE`

If the provider read is 404, it returns without authorization or mutation. If DELETE returns 412, the workflow performs another provider read and then a separate fresh DB authorization before the retry DELETE.

Because production `readEvent` is `getEvent()`, an HTTP 200 response with missing/null/empty/whitespace ETag throws before `authorize` can run.

The tests now directly assert for both Task DELETE and target deletion:

- provider GET count = 1;
- DB authorization callback count = 0;
- delete-workflow callback count = 0;
- provider DELETE count = 0;

They additionally verify:

- a 412 retry performs exactly two reads, two authorizations, and two DELETE attempts using `etag-v1` then `etag-v2`;
- a provider 404 performs zero authorization and zero DELETE;
- direct `deleteEvent()` rejects empty `If-Match` before fetch;
- a valid DELETE emits the exact `If-Match` value.

This closes the LOW using the exact helper that the production worker calls; it is not a test-only surrogate.

The earlier DD8 durable provider mutation fence, provider-side handoff token, 412 re-GET/retry, ETag advancement, and DD11 blocker coverage remain required regression checks.

## Regression areas required in the next independent review

The reviewer should independently confirm no regression in:

- DD8 durable `inflight` / `uncertain` provider mutation fence;
- DD8 provider-side handoff token + ETag advancement barrier;
- DD11 blocking of unresolved/unconsumed `inflight`, `uncertain`, `prepared`, and `provider_fenced` states;
- DD9 complete pre-review minimization boundary including SQL #52, #53, and #54;
- DD10 completed archive receipt replay and active-context guard;
- Request terminal-state safety after linked Task completion;
- Handover legacy/canonical acknowledgement compatibility;
- R0 canonical-reader fence and explicit Shopping `legacy_r0` compatibility;
- DD11 Shopping `anyone` reconciliation and final-zero gates;
- test-context isolation from production notification, Google, canonical-reader, and analytics paths.

## Activation boundary

This remediation does not authorize production activation.

PR #45 must remain Draft and unmerged during review. No production migration apply, Edge deployment, P1 activation, real LINE delivery, or real Google provider mutation is part of this source-review gate.
