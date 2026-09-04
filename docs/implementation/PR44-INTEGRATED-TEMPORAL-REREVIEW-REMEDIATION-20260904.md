# PR #44 — integrated temporal covert-channel re-review remediation

This addendum is authoritative for the integrated-source-review finding against historical PR #44 head `6017bc08fc72c249a78bcb2580984901321d7a4c`.

Historical verdict:

- BLOCKER: 0
- HIGH: 1
- MEDIUM: 0
- LOW: 0
- Verdict: NO-GO

The independent reviewer found a new DD9 pre-review privacy channel: syntactically valid temporal scalars were still treated as trusted structured facts even though R0 has no trusted server-side inventory proving those dates/times/timestamps were actually observed in the source document.

## Historical failure

A model/extractor could split 128 arbitrary bytes into 64 unsigned 16-bit cells and encode each cell as a valid date:

`DATE '2000-01-01' + n`

where `n` is 0..65535.

Every date is syntactically valid.  Before this remediation, `event.date` survived `fn_minimize_nursery_fact_value_v3`, so the original 16-bit value was recoverable as:

`stored_date - DATE '2000-01-01'`

Across 64 facts, that produced a reversible 128-byte pre-review durable channel in `private.document_facts.normalized_value`.

The same trust-boundary issue also existed on other caller/model temporal surfaces such as deadline date/time, recurrence until/effective dates, AI task/event timestamps, school-context effective dates, and caller-supplied `source_documents.captured_at`.

## Current remediation

Migration:

- `supabase/migrations/20260904000004_dd9_pre_review_temporal_grounding_minimization.sql`

R0 has no separately reviewed trusted temporal-token inventory.  Therefore caller/model supplied temporal scalars are not persisted in the pre-review structured representation.

### Command-level minimization

The existing v3 minimizers were hardened and kept idempotent:

- source `event`: retain controlled `event_type` and boolean `all_day`; discard date/start/end dates;
- source `deadline`: retain only controlled review marker; discard date/time;
- source `recurrence`: retain controlled frequency/day-of-week; discard `until`;
- school-context candidate: retain only validated household `child_school_context_id`; discard effective dates;
- AI task: discard scheduled/due/calendar timestamps and keep review marker;
- AI Family Event: retain only boolean `all_day` when supplied; discard all date/timestamp values;
- AI recurrence: retain only low-cardinality frequency (`daily`, `weekly`, `monthly`); do not retain raw RRULE, interval, BYDAY, UNTIL, or effective dates;
- AI info: discard effective dates and keep review marker.

Controlled non-temporal semantics remain available for human review.  No target is applied pre-review.

### Durable table boundaries

The remediation does not rely on the command function alone.

`private.source_documents`

- BEFORE INSERT: `uploaded_at` is server-issued with `statement_timestamp()`;
- `captured_at` is forced to the same server-issued timestamp;
- BEFORE UPDATE of capture/upload time: original server `uploaded_at` is retained and `captured_at` is reset to it.

`private.document_extractions`

- BEFORE INSERT / UPDATE of `school_context_candidate`: the same school-context minimizer is re-applied.

`private.document_facts`

- BEFORE INSERT / UPDATE of fact identity/value/scope fields: `normalized_value` is re-minimized for extraction-backed facts.

`public.change_candidates`

- the existing nursery AI table-boundary trigger now also re-minimizes `proposed_patch`;
- model-supplied `target_id` and `current_snapshot_hash` remain NULL;
- only a validated same-household `child_school_context_id` may be retained together with fixed origin/reason markers and low-cardinality non-temporal review fields.

The migration also scrubs rows produced by earlier review heads through these same minimizers.

## Adversarial SQL #56

Test:

- `tests/sql/56_integrated_rereview_temporal_covert_channel.sql`

The fixture constructs exactly 128 bytes of third-party/contact-shaped data and divides it into 64 two-byte integers.  Each integer is converted to a valid date using `2000-01-01 + n`.

Before persistence, the test reconstructs the original 128 bytes from the 64 dates and requires byte-for-byte equality.  This proves a real reversible channel rather than a merely theoretical malformed-input case.

The hostile payload then travels through the ordinary R0 path:

1. `private.fn_command_create_nursery_intake_v1`;
2. `private.fn_command_record_nursery_extraction_v1`;
3. extraction reaches `review` with 64 source facts and four AI candidates.

The test requires:

- caller-supplied `captured_at` does not survive; durable `captured_at = uploaded_at` from the server;
- all 64 durable source facts exist but contain no date/start/end/time/until scalar;
- controlled event semantics (`food_education`, `all_day`) remain;
- school-context effective dates do not persist but the validated child-school context ID remains;
- task/event/recurrence/info AI candidates contain no caller/model temporal scalar or raw RRULE;
- service-role UPDATE attempts to re-inject all 64 hostile dates are re-minimized;
- service-role UPDATE attempts to re-inject school-context dates, candidate timestamps/RRULE, and source capture time are also re-minimized.

At intermediate code/test head `8e3bb26b176f3b369558c440168fa195dce09a3e`, CI run #417 DB raw evidence includes:

- `47_dd9_nursery_intake_pipeline: PASS`
- `52_independent_rereview_high_remediation: PASS`
- `53_second_independent_rereview_remediation: PASS`
- `54_third_independent_rereview_source_locator: PASS`
- `55_fourth_independent_rereview_schema_version: PASS`
- `56_integrated_rereview_temporal_covert_channel: PASS`
- `98_dd11_full_readiness_zero: PASS`
- `99_canonical_reconciliation_zero: PASS`
- `all concurrency tests passed`
- `all SQL tests passed`

The final review anchor is the later documentation-inclusive exact PR #44 head and exact-head CI recorded in the PR body, not this intermediate head.

## Privacy invariant for re-review

The invariant is semantic:

> Pre-review durable structured/technical persistence must not retain attacker/model-controlled high-cardinality values unless the value is bound to trusted server-issued provenance or a separately reviewed trusted source-token inventory.

A scalar is not trusted merely because it parses as a date, time, timestamp, number, UUID, hash, version, locator, or other business-looking type.

Previous DD9 remediations remain mandatory regression areas: free-text minimization, model/provider metadata, `current_snapshot_hash`, model-supplied `target_id`, `source_locator`, and `schema_version`.

## Activation boundary

This remains source-readiness only.

- PR #44 must remain Draft / open / unmerged until independent integrated re-review returns GO.
- No September 2026 DD1-DD11 migration is production-applied by this remediation.
- No Edge production deployment is authorized.
- P1 remains inactive.
- DD9 OCR / AI / Storage / target-apply adapters remain inactive.
- No real LINE delivery or new Google provider mutation is authorized.