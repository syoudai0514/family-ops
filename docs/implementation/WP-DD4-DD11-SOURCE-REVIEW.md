# WP-DD4–DD11 Downstream Integration — Independent Source Review

## Review contract

Review the exact PR #45 head named in the review request. Do not infer that a
later head is reviewed. This unit is pre-production and pre-P1.

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
  stale target DELETE authorization, orphan revalidation and overlap audit.
- DD9 review-only nursery/Codmon evidence pipeline: private source document,
  child/school-scoped explicit facts, AI proposals, and explicit preparation
  rule confirmation.
- DD10 operator-owned one-user simulation context and workspace, with immutable
  simulated ActorRef identity and archive semantics.
- DD11 R0/P1 readiness audit/runbook.

## Required reviewer focus

### BLOCKER/HIGH gate

Return **NO-GO** for any BLOCKER or HIGH finding in these areas:

1. Test context can reach production LINE/outbox, Google mutation, analytics,
   real consent, or a production reader.
2. Simulated actor is represented by a fake auth/member or the operator UUID.
3. Task mirror, target DELETE, and Family Event writer can concurrently mutate
   one exact `(calendar_connection_id, provider_event_id)` identity.
4. A stale deletion job can mutate a provider event after transfer/adoption.
5. Image explicit fact or AI inference silently applies a Task/Event/Google
   change, crosses child/school scope, or persists third-party OCR data.
6. Canonical command retry/revision paths create duplicate actuals/attempts or
   bypass ActorRef scope.
7. P1/production activation is reachable through a default path.

### Specific review questions

1. Does every legacy public Request RPC preserve only its historic adapter
   contract while post-agreement change/cancel uses the dedicated canonical
   follow-up command?
2. Are DailyBrief/Today/LINE consuming a single read truth and preserving
   all-day values without fake midnight timestamps?
3. Is DD8's provider-less hostile-mirror test exclusion limited to audit
   precision, while any test Task mirror with an actual provider ID remains a
   blocker?
4. Does DD9 keep raw content private, facts explicit, AI content candidate-only,
   and preparation-rule learning human-confirmed?
5. Does DD10 archive only stop future simulated commands and preserve audit
   history without converting any simulated agreement to a real-spouse action?
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
- `docs/implementation/FAMILY-OPS-WORK-INTEGRATION-STATUS.md`
- `docs/implementation/FAMILY-OPS-CUTOVER-READINESS-RUNBOOK.md`

## Explicit, fail-closed scope limits

- DD8 Family Event Google writer remains disabled; transfer does not create,
  update, or delete a provider event.
- DD9 does not enable a Storage deletion worker, OCR/AI provider call, or target
  Task/Event adapter. These must remain unavailable until separately reviewed.
- DD10 exposes owned context lifecycle/read workspace; it reuses the existing
  mandatory core ActorRef E2E. Browser/LINE command adapters are not activated
  by this source unit.
- All capability gates remain R0 with mutation paused.

## Required verdict format

State one of `GO`, `GO WITH MEDIUM/LOW FOLLOW-UP`, or `NO-GO`. List findings by
severity with file/function, exploit or correctness path, expected invariant,
and the smallest safe remedy. A green CI alone is not a GO.
