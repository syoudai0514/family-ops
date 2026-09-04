# PR #45 — fourth independent re-review remediation

This addendum is authoritative for the fourth independent review finding against historical PR #45 head `010bd08cf39e0c5023b9f8282345d85735b68055`.

Historical verdict:

- BLOCKER: 0
- HIGH: 1
- MEDIUM: 0
- LOW: 0
- Verdict: NO-GO

The final reviewer must fresh-read CURRENT source and the exact PR head/CI recorded in the PR body.

## HIGH — caller-controlled `provider_metadata.schema_version`

### Historical failure

`private.fn_minimize_nursery_provider_metadata_v3(jsonb)` discarded arbitrary model/extractor strings but retained a caller supplied `schema_version` whenever it matched `^[0-9]{1,6}$`.

That was syntactic validation, not provenance. A caller/model could divide 128 arbitrary bytes into 64 two-byte integers, persist each integer as a valid decimal `schema_version` on a separate extraction, and reconstruct the original bytes from durable `private.document_extractions.provider_metadata`.

The existing table trigger reapplied the same minimizer, so service-role UPDATE did not close the channel.

## Current remediation

Migration:

- `supabase/migrations/20260904000003_dd9_pre_review_schema_version_minimization.sql`

R0 has no trusted server-issued schema registry or adapter-issued schema identity. Therefore the minimizer no longer preserves the submitted `schema_version` at all.

The durable pre-review metadata shape now consists only of controlled values:

- `provider`: existing low-cardinality enum (`codmon`, `openai`, `google`, `manual`, `test`, `unknown`);
- `schema_version`: server-issued fixed marker `"1"`;
- model/model-version/extractor-version presence: fixed `redacted-pre-review` markers only.

The migration keeps `document_extractions_minimize_pre_review_metadata_v1` as the authoritative BEFORE INSERT / BEFORE UPDATE table boundary and explicitly recreates it. A later service-role write therefore crosses the same minimizer.

Rows already persisted behind the R0 marker `pre_review_minimized_v3` are rewritten through the new minimizer so a previously retained numeric schema cell is normalized to the same fixed marker.

No OCR, AI, Storage, target writer, production provider, or P1 activation is introduced.

## Adversarial SQL #55

Test:

- `tests/sql/55_fourth_independent_rereview_schema_version.sql`

The fixture constructs exactly 128 bytes of third-party/contact-shaped caller-controlled data and divides them into 64 two-byte integers. Every integer is represented as an individually valid 1–6 digit decimal `schema_version`.

Before persistence, the test reconstructs the exact original 128 bytes from the 64 decimal cells and requires byte-for-byte equality. This proves the attack fixture is genuinely reversible.

All 64 cells then travel through the ordinary canonical nursery path:

1. `private.fn_command_create_nursery_intake_v1`;
2. `private.fn_command_record_nursery_extraction_v1`;
3. state reaches `review`.

The test requires all 64 durable extraction rows to contain only the fixed server schema marker `"1"` together with controlled provider/presence markers. It then performs service-role UPDATE attempts restoring every original decimal cell and requires all 64 rows to remain fixed at `"1"`.

At intermediate code/test head `66c9b5fe11aaf5de448c81fdde5e5814c43c775d`, CI run #413 DB raw evidence includes:

- `52_independent_rereview_high_remediation: PASS`
- `53_second_independent_rereview_remediation: PASS`
- `54_third_independent_rereview_source_locator: PASS`
- `55_fourth_independent_rereview_schema_version: PASS`
- `98_dd11_full_readiness_zero: PASS`
- `99_canonical_reconciliation_zero: PASS`
- `all concurrency tests passed`
- `all SQL tests passed`

The final review anchor is the later documentation-inclusive exact head and exact-head CI recorded in the PR body, not this intermediate head.

## Privacy invariant for re-review

The invariant is semantic rather than field-name based:

> Pre-review durable structured/technical persistence must not retain attacker/model-controlled high-cardinality values that can encode unrelated third-party data.

A value is not trusted merely because it is numeric, UUID-shaped, hash-shaped, provider metadata, a schema/version field, a locator, or stored in the private schema.

Previous defenses remain required regression areas, including free-text minimization, school/class text, model labels, `current_snapshot_hash`, model-supplied `target_id`, `source_locator`, and technical metadata presence markers.

## Other regression areas

The next independent review should also confirm no regression in:

- DD8 durable inflight/uncertain mutation fences and provider-side handoff/ETag advancement;
- DD10 completed archive receipt replay and active-context guards;
- Request terminal-state preservation;
- Handover legacy/canonical acknowledgement compatibility;
- R0 canonical reader fence and Shopping `legacy_r0` compatibility;
- DD11 reconciliation/readiness final-zero gates;
- test-context isolation from production notification, outbox, Google projection/write, canonical-reader, and analytics paths.

## Activation boundary

PR #45 remains source-readiness only. It must remain Draft/open/unmerged for independent review. This remediation does not authorize production migration apply, Edge deployment, P1 activation, real LINE delivery, or real Google provider mutation.
