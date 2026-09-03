# WP-DD4–DD11 Downstream Integration — Independent Source Review

## Review contract

Review the **current exact PR #45 head shown by GitHub at review start**. Do not
infer that a later head is reviewed and do not reuse a historic CI run as
current evidence. PR #45 is pre-production and pre-P1.

The prior independent review baseline was PR #45 head
`26704f2682ebe3362b4e389e192c8cadbdd5b8f8`; it returned **NO-GO** for the DD8
provider-ownership race plus DD10 archive replay and DD9 privacy-hardening
follow-ups. That SHA is historical evidence only, not the remediation review
head.

Canonical foundation PR #44 remains
`6125af780358cd7f8155cc67f8cfe7a4046d0571`; this remediation does not alter its
canonical DD1/DD2/DD3A/DD3 semantics.

No production Supabase apply, production data change, production Edge deploy,
real LINE delivery, Google provider mutation, P1 activation, or main merge is
authorized by this review.

## Scope

PR #45 builds on PR #44's canonical DD1/DD2/DD3A/DD3 foundation and covers:

- DD4 Request/assignment canonical adapter, post-agreement follow-up Attempts,
  linked Task execution separation, idempotency and legacy RPC compatibility.
- DD5 Task actual/reconciliation/history read semantics.
- DD5B Shopping ActorRef assignment/claim/action/reopen commands and neutral
  duplicate-sensitive intent.
- DD6 shared DailyBrief/Today read semantics, official schedules and all-day
  date-only preservation.
- DD7 semantic notification bridge using the existing quota/lease/retry outbox.
- DD8 Family Event/Google ownership transfer source: exact provider identity,
  target-deletion ownership, orphan revalidation, overlap audit, and a fresh
  provider pre-mutation authorization fence for ordinary Task mirrors.
- DD9 review-only nursery/Codmon evidence pipeline: private source document,
  child/school-scoped explicit facts, AI proposals, explicit preparation-rule
  confirmation, and typed/minimized durable structured-persistence boundaries.
- DD10 operator-owned one-user simulation context/workspace, immutable simulated
  ActorRef identity, archive semantics, and completed-receipt replay after
  archival for the same canonical operation.
- DD11 R0/P1 readiness audit/runbook.

## Source-review remediation to inspect

### H-1 — DD8 provider pre-mutation fencing

`public.server_tx_authorize_family_ops_calendar_mirror(...)` now re-checks and
row-locks the durable Task mirror immediately before **each** Google mutation.
Authorization requires the current lease token, a live processing lease,
non-transferred ownership, the same calendar connection/provider event
identity, the current active family write target, no validated/active Family
Event owner, no live target-deletion owner, and no unresolved/blocked orphan
identity. Failure is fail-closed.

The Edge worker wraps ordinary Task mirror DELETE/INSERT/PATCH calls in
`withProviderMutationFence(...)`. A Google 412 causes re-GET and then a **new**
authorization before the retry PATCH/DELETE. Target-deletion DELETE uses the
same per-attempt rule. `ProviderMutationFencedError` is treated as superseded
concurrency; the stale worker does not call the provider and does not fail/requeue
the newer durable owner.

The successful authorization refreshes the processing lease for the short
provider-call window. Ownership transfer takes the same durable mirror row lock
and rejects an active processing lease, so transfer cannot interleave between
the successful fence and the normal immediate provider call.

Review together:

- `supabase/migrations/20260903030014_source_review_remediation.sql`
- `supabase/functions/process-family-ops-calendar-outbox/index.ts`
- `supabase/functions/process-family-ops-calendar-outbox/providerMutationFence.ts`
- `supabase/functions/process-family-ops-calendar-outbox/providerMutationFence.test.ts`
- `tests/sql/50_source_review_remediation.sql`

### H-1 adversarial evidence

`tests/sql/50_source_review_remediation.sql` exercises both UPSERT and DELETE
Task-mirror races:

1. claim Task mirror;
2. prove transfer fails while the processing lease is active;
3. expire the lease;
4. transfer the exact provider identity to a Family Event;
5. prove the old lease cannot authorize provider mutation;
6. prove the transferred Task mirror cannot be re-enqueued;
7. prove target deletion does not retain overlapping ownership;
8. require provider-owner audit `active_owner_count <= 1`.

`providerMutationFence.test.ts` separately proves that a rejected stale/Family
Event authorization leaves the provider mutation callback invocation count at
zero, and that a retry performs a second authorization rather than reusing the
first one.

### M-1 — DD10 archive idempotent retry

Archive now separates completed-receipt replay scope from new-mutation active
context scope. `private.fn_replay_completed_test_archive_v1(...)` may read an
archived operator-owned context only to verify/replay a completed exact
`test_simulation.archive` receipt. It still verifies the real operator ActorRef,
household, context ownership, operation ID, action, and canonical request hash.

If no completed exact receipt exists, the normal canonical operation claim path
still requires an active context. Therefore:

- first archive: active -> archived -> completed receipt;
- same operation ID + same canonical request hash: prior result replayed;
- different operation ID after archive: `TEST_CONTEXT_NOT_ACTIVE`.

The regression is in `tests/sql/50_source_review_remediation.sql`.

### M-2 — DD9 privacy / structured persistence hardening

The DB boundary no longer relies only on suspicious-keyword checks. The
remediation adds structural allowlists and bounds for:

- provider metadata: fixed metadata key set, scalar strings, per-value and JSON
  size bounds;
- school context candidate: only context ID/display/effective-date fields with
  UUID/date/length validation;
- source facts: bounded count/bytes, fixed top-level fields, enumerated fact
  kinds, fact-kind-specific normalized-value keys, scalar-only values;
- URLs: `http://` or `https://` only with length bound;
- AI candidates: fixed top-level shape, target-specific patch-key allowlists,
  scalar/bounded patch values, explanation length bound;
- generic human-confirmed preparation values: small flat object only; nested
  transcript/roster/profile/contact structures are not durable structured
  facts.

`20260903030015_source_review_remediation_validation_fix.sql` is the PostgreSQL
16 compatibility override for object-cardinality validation; it does not widen
those boundaries.

OCR/AI/Storage adapters remain disabled and this source unit does not invent or
activate an external provider contract.

## Required reviewer focus

### BLOCKER/HIGH gate

Return **NO-GO** for any BLOCKER or HIGH finding in these areas:

1. Test context can reach production LINE/outbox, Google mutation, analytics,
   real consent, or a production reader.
2. Simulated actor is represented by a fake auth/member or the operator UUID.
3. Task mirror, target DELETE, and Family Event writer can concurrently mutate
   one exact `(calendar_connection_id, provider_event_id)` identity.
4. A stale ordinary mirror or deletion job can reach a provider mutation after
   lease expiry/transfer, including a 412 retry path.
5. Image explicit fact or AI inference silently applies a Task/Event/Google
   change, crosses child/school scope, or persists arbitrary third-party OCR
   transcript/profile data as a durable structured fact.
6. Canonical command retry/revision paths create duplicate actuals/attempts or
   bypass ActorRef scope.
7. Same-operation DD10 archive retry fails to replay solely because the context
   was archived, or a different operation mutates an archived context.
8. P1/production activation is reachable through a default path.

### Specific review questions

1. Does every legacy public Request RPC preserve only its historic adapter
   contract while post-agreement change/cancel uses the dedicated canonical
   follow-up command?
2. Are DailyBrief/Today/LINE consuming a single read truth and preserving
   all-day values without fake midnight timestamps?
3. Is every Task-mirror and target-deletion provider mutation attempt fenced at
   the last DB boundary, with a fresh fence after a 412 re-GET?
4. Does DD9 keep raw content private, facts explicit/minimized, AI content
   candidate-only, and preparation-rule learning human-confirmed?
5. Does DD10 exact completed archive receipt replay survive context archival
   while new archive operations remain inactive-context failures?
6. Are DD11 audits correctly separated from test fixtures yet strict for a real
   production P1 scope?

## Evidence to inspect

- `tests/sql/39_dd3a_mandatory_actorref_e2e.sql`
- `tests/sql/41_google_projection_test_scope_isolation.sql`
- `tests/sql/44_dd4_request_canonical_cutover.sql`
- `tests/sql/45_dd5b_shopping_canonical_e2e.sql`
- `tests/sql/46_dd8_google_provider_ownership_transfer.sql`
- `tests/sql/47_dd9_nursery_intake_pipeline.sql`
- `tests/sql/48_dd10_one_user_simulation_workspace.sql`
- `tests/sql/49_dd11_cutover_readiness_audits.sql`
- `tests/sql/50_source_review_remediation.sql`
- `supabase/functions/process-family-ops-calendar-outbox/providerMutationFence.test.ts`
- `docs/implementation/FAMILY-OPS-WORK-INTEGRATION-STATUS.md`
- `docs/implementation/FAMILY-OPS-CUTOVER-READINESS-RUNBOOK.md`

For CI, inspect the checks attached to the **exact current PR #45 head**. Required
coverage is Web lint/typecheck/test/build; Edge lint/typecheck/unit/auth matrix;
DB empty migration chain plus full SQL suite; and real Supabase CLI stack
integration. A historic green run is not evidence for a later head.

## Explicit, fail-closed scope limits

- DD8 Family Event Google writer remains disabled; transfer does not create,
  update, or delete a provider event. No real Google mutation is authorized by
  this review package.
- DD9 does not enable a Storage deletion worker, OCR/AI provider call, or target
  Task/Event adapter. These remain unavailable until separately reviewed.
- DD10 exposes owned context lifecycle/read workspace; it reuses the existing
  mandatory core ActorRef E2E. Browser/LINE command adapters are not activated
  by this source unit and simulation never converts to production identity.
- All capability gates remain R0 with mutation paused.

## Required verdict format

State one of `GO`, `GO WITH MEDIUM/LOW FOLLOW-UP`, or `NO-GO`. List findings by
severity with file/function, exploit or correctness path, expected invariant,
and the smallest safe remedy. A green CI alone is not a GO.