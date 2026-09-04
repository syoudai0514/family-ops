# PR #45 Independent Re-review — HIGH Remediation Addendum

This addendum is the authoritative review note for the two HIGH findings returned
by the independent re-review of PR #45 after head
`dad5faa24ebc8383bf3d827316e8f8fa872e77df`.

If older DD8/DD9 wording in `WP-DD4-DD11-SOURCE-REVIEW.md`,
`FAMILY-OPS-WORK-INTEGRATION-STATUS.md`, or
`FAMILY-OPS-CUTOVER-READINESS-RUNBOOK.md` conflicts with this addendum, use this
addendum and the CURRENT source. In particular, **ordinary worker lease expiry is
not sufficient evidence for provider ownership transfer after an uncertain
provider mutation**.

The exact review head and exact-head CI run are intentionally pinned in the PR
body only after the final CI completes. A reviewer must fresh-read CURRENT GitHub
at review start.

No production Supabase apply, production Edge deploy, production cron change,
real LINE delivery, real Google provider mutation, P1 activation, Draft removal,
or merge is authorized by this addendum.

## HIGH-1 / DD8 — in-flight stale provider mutation

### Broken path from the prior review

The prior implementation authorized a Google mutation in DB and then issued the
HTTP request after the transaction. A worker lease could expire while that
request remained in flight. A Family Event transfer could then become the
logical owner before the old request completed, allowing an old PATCH/DELETE to
land late.

### Current remediation

The current source separates the ordinary worker lease from provider-mutation
ownership.

1. Every provider mutation authorization establishes a durable row in
   `private.google_provider_mutation_fences` with an exact
   `(calendar_connection_id, provider_event_id)` identity and state `inflight`.
2. The provider-call wrapper has a bounded local request deadline. A provider
   outcome that cannot be proven completed becomes `uncertain`; it is not
   treated as harmless merely because the worker lease expired.
3. `private.fn_transfer_task_mirror_to_family_event_v1(...)` refuses transfer
   while a mutation is `inflight`.
4. If any mutation for the exact provider identity is `uncertain`, a later GET
   or fixed quarantine delay is **not** sufficient. Transfer requires a
   provider-side handoff fence:
   - prepare a unique durable handoff token;
   - GET the exact Google event and current ETag;
   - PATCH the exact event with `If-Match` and write the token to
     `extendedProperties.private.familyOpsOwnershipFenceToken`;
   - on `412`, re-GET and retry against the newer ETag;
   - re-GET after success and require the exact token plus an ETag different
     from the pre-PATCH ETag;
   - persist that exact new ETag/snapshot as `provider_fenced` evidence;
   - only then may DB ownership transfer consume the handoff evidence and mark
     the uncertain mutation `reconciled`.
5. DD11 readiness blocks on either unresolved provider mutation state
   (`inflight`/`uncertain`) or unconsumed provider handoff state
   (`prepared`/`provider_fenced`).

This makes an uncertain old PATCH/DELETE use a stale `If-Match` ETag after the
handoff PATCH advances provider state, so a late request cannot successfully
mutate the transferred identity. Deterministic INSERT uses the same stable event
ID and cannot overwrite an already-created event under the normal create path.

### Source to inspect

- `supabase/migrations/20260903030020_independent_rereview_remediation.sql`
- `supabase/migrations/20260903030021_independent_rereview_audit_precision.sql`
- `supabase/migrations/20260903030024_dd8_provider_side_handoff_fence.sql`
- `supabase/functions/process-family-ops-calendar-outbox/providerMutationFence.ts`
- `supabase/functions/process-family-ops-calendar-outbox/providerMutationFence.test.ts`
- `supabase/functions/process-family-ops-calendar-outbox/providerOwnershipHandoffFence.ts`
- `supabase/functions/process-family-ops-calendar-outbox/providerOwnershipHandoffFence.test.ts`
- `supabase/functions/_shared/googleCalendar.ts`
- `tests/sql/52_independent_rereview_high_remediation.sql`

### Adversarial evidence required

`tests/sql/52_independent_rereview_high_remediation.sql` covers both Task-mirror
and target-deletion paths:

- authorize provider mutation;
- keep durable `inflight` state;
- expire ordinary worker lease;
- require transfer to fail while provider call remains `inflight`;
- make the provider outcome uncertain;
- require transfer to fail with provider-handoff evidence absent;
- prepare/confirm an exact handoff token and a new provider ETag;
- require transfer to succeed only with that exact confirmed snapshot/ETag;
- require the uncertain provider mutation to become `reconciled`;
- require readiness to contain no unresolved/unconsumed handoff state.

The Edge unit test separately models the provider race where an old mutation wins
between the first GET and the barrier PATCH: first PATCH receives `412`, the
helper re-GETs the newer ETag, retries, confirms the handoff token and returns an
ETag advanced again by the barrier. Additional tests fail closed if the token is
missing or the ETag does not advance.

### Scope limit

The Family Event production Google writer/transfer coordinator is still not
activated. The provider-side handoff helper and DB gates are source-readiness
machinery; this PR does not call a real Google provider as part of review or CI.

## HIGH-2 / DD9 — allowed free-text durable privacy bypass

### Broken path from the prior review

A structural key/type allowlist still permitted third-party roster/contact/
profile text to be embedded inside allowed scalar fields such as `note`, `notes`,
`title`, `summary`, `location`, or `explanation`, including splitting a transcript
across many otherwise valid facts.

### Current remediation

The pre-review persistence boundary no longer treats arbitrary free text as
structured durable content merely because its key is allowed.

- Source facts are minimized to controlled typed values. For example,
  `required_item` persists a controlled item code rather than arbitrary note
  text; source locators carrying copied third-party text are not persisted.
- Pre-review AI `change_candidates` persist controlled review metadata/reason
  markers rather than model-generated `title`/`notes`/`explanation` free text.
- School-context candidate persistence does not copy arbitrary model-generated
  school/class free-text values before review.
- Provider/model/extractor technical metadata is normalized to bounded controlled
  fields/redacted markers rather than preserving caller-supplied third-party
  text. The sanitizer is idempotent.
- Raw private evidence remains the source for a human review; target application
  remains disabled. No OCR/AI/Storage/target adapter is activated by this PR.

### Source to inspect

- `supabase/migrations/20260903030014_source_review_remediation.sql`
- `supabase/migrations/20260903030015_source_review_remediation_validation_fix.sql`
- `supabase/migrations/20260903030020_independent_rereview_remediation.sql`
- `supabase/migrations/20260903030022_dd9_technical_metadata_minimization.sql`
- `supabase/migrations/20260903030023_dd9_metadata_sanitizer_idempotency.sql`
- `tests/sql/47_dd9_nursery_intake_pipeline.sql`
- `tests/sql/52_independent_rereview_high_remediation.sql`

### Adversarial evidence required

The re-review regression submits:

- provider/model metadata containing an unrelated child name and phone number;
- **64** individually valid `required_item` facts, each attempting to hide roster
  name/phone content in `note` and `source_locator`;
- an AI Task candidate attempting to store a third-party name in `title`, contact
  data in `notes`, and a third-party profile in `explanation`;
- school/class candidate free text containing the same third-party data.

The test requires the input to reach the review boundary, but verifies that the
durable structured stores contain controlled values/review markers rather than
those free-text third-party values.

## Prior remediation that must not regress

The independent re-review had already marked these areas PASS before the two HIGH
findings above were remediated. The new exact head must still preserve them:

- DD10 completed archive receipt replay / different-operation active-context
  guard;
- Request terminal-state safety after linked Task completion;
- Handover legacy + canonical acknowledgement compatibility;
- R0 reader fence and explicit Shopping `legacy_r0` compatibility path;
- DD11 Shopping `anyone` reconciliation and final zero gates;
- test-context isolation from production notification/Google/read paths.

The complete SQL suite, not only test 52, is therefore required on the final head.

## Final review gate

Before asking for independent re-review:

1. exact PR #45 head is pinned;
2. Web lint/typecheck/test/build is green;
3. Edge lint/typecheck/unit/auth-matrix is green;
4. DB empty migration chain + complete SQL suite is green, including
   `50`, `51`, `52`, `98`, `99`, and true-parallel concurrency tests;
5. real Supabase CLI stack integration is green;
6. PR remains Draft and no production action has occurred.

Independent verdict rule: **GO only with BLOCKER 0 / HIGH 0**. A green CI is
necessary evidence, not review approval.
