# WP-DD4–DD11 Downstream Integration — Independent Source Review

## Review contract

Review the **current exact PR #45 head shown by GitHub at review start**. Do not
infer that a later head is reviewed and do not reuse a historic CI run as
current evidence. PR #45 is pre-production and pre-P1.

The prior independent review baseline was PR #45 head
`26704f2682ebe3362b4e389e192c8cadbdd5b8f8`; it returned **NO-GO**. That SHA and
its CI are historical evidence only.

Canonical foundation PR #44 is now pinned at
`e2b45cba84bf1e18e92607325823e483ddca8722` with CI run 364 green. Its source
review remediation is forward-only and includes the corrected canonical RLS,
assignment/reconciliation coexistence, system ActorRef test scope, actual
performer-kind enforcement, and linked Task -> Request completion behavior.
PR #45 must be reviewed against that current foundation, not the older
`6125af...` or `a77e315...` snapshots.

No production Supabase apply, production data change, production Edge deploy,
real LINE delivery, Google provider mutation, P1 activation, or main merge is
authorized by this review.

## Scope

PR #45 builds on PR #44's canonical DD1/DD2/DD3A/DD3 foundation and covers:

- DD4 Request/assignment canonical adapters, post-agreement follow-up Attempts,
  linked Task execution, compatibility projection, and terminal-state safety.
- DD5 Task actual/reconciliation/history semantics.
- DD5B Shopping ActorRef assignment/claim/action/reopen commands and R0 legacy
  reader fallback.
- DD6 shared DailyBrief/Today semantics, official schedules and all-day
  date-only preservation, with canonical reader activation blocked at R0.
- DD7 semantic notification bridge using the existing quota/lease/retry outbox.
- DD8 Family Event/Google ownership transfer source: exact provider identity,
  target-deletion ownership, orphan revalidation, overlap audit, and fresh
  provider pre-mutation authorization for ordinary Task mirrors.
- DD9 review-only nursery/Codmon evidence pipeline with typed/minimized durable
  structured-persistence boundaries.
- DD10 operator-owned one-user simulation context/workspace, immutable simulated
  ActorRef identity, archive semantics, and completed-receipt replay.
- DD11 R0/P1 readiness audit/runbook and final all-blockers-zero suite gates.

## Remediation to inspect

### Foundation carry-forward from PR #44

PR #45 inherits the current PR #44 remediation rather than reimplementing it.
Review the resulting merge/base relationship together with:

- `supabase/migrations/20260903000018_source_review_foundation_remediation.sql`
- `tests/sql/44_foundation_source_review_remediation.sql`

Required invariants include household RLS correctness, reconciliation that does
not overwrite valid canonical assignment state, test-only system ActorRef
containment, valid actual performer kinds, and Task completion synchronizing the
linked Request compatibility tuple without erasing Attempt history.

### DD8 — provider pre-mutation fencing

`public.server_tx_authorize_family_ops_calendar_mirror(...)` re-checks and
row-locks the durable Task mirror immediately before **each** Google mutation.
Authorization requires the current lease token, a live processing lease,
non-transferred ownership, the exact calendar connection/provider event
identity, the current active family write target, no active Family Event owner,
no live target-deletion owner, and no unresolved/blocked orphan identity.
Failure is fail-closed.

The Edge worker wraps ordinary Task mirror DELETE/INSERT/PATCH calls in
`withProviderMutationFence(...)`. A Google 412 re-GET is followed by a **fresh**
authorization before retry PATCH/DELETE. Target-deletion DELETE uses the same
per-attempt rule. A rejected authorization must not invoke the provider callback.

Review together:

- `supabase/migrations/20260903030014_source_review_remediation.sql`
- `supabase/functions/process-family-ops-calendar-outbox/index.ts`
- `supabase/functions/process-family-ops-calendar-outbox/providerMutationFence.ts`
- `supabase/functions/process-family-ops-calendar-outbox/providerMutationFence.test.ts`
- `tests/sql/46_dd8_google_provider_ownership_transfer.sql`
- `tests/sql/50_source_review_remediation.sql`

`tests/sql/50_source_review_remediation.sql` constructs an exact provider
identity `(calendar_connection_id, provider_event_id, provider_etag)` and covers
UPSERT and DELETE races: claim, active-lease transfer denial, lease expiry,
transfer, stale-lease authorization denial, transferred-mirror re-enqueue denial,
target-deletion overlap removal, and `active_owner_count <= 1`.

### DD9 — privacy / structured persistence hardening

The DB boundary uses structural allowlists and bounds, not only suspicious-key
checks. It constrains provider metadata, school-context candidates, source fact
kinds and value shapes, URL schemes/lengths, AI candidate patch keys/values,
and generic human-confirmed preparation values. Nested transcript/roster/profile
/contact-shaped objects are not accepted as durable structured facts.

Relevant source:

- `supabase/migrations/20260903030009_dd9_nursery_intake_canonical_pipeline.sql`
- `supabase/migrations/20260903030010_dd9_nursery_validator_privilege_hardening.sql`
- `supabase/migrations/20260903030014_source_review_remediation.sql`
- `supabase/migrations/20260903030015_source_review_remediation_validation_fix.sql`
- `tests/sql/47_dd9_nursery_intake_pipeline.sql`
- `tests/sql/50_source_review_remediation.sql`

OCR/AI/Storage/provider adapters and target-application adapters remain disabled.

### DD10 — archive idempotent retry

Archive separates completed-receipt replay from new-mutation active-context
scope. The same operation ID + same canonical request hash may replay the
completed archive receipt after context archival. A different operation ID
still enters the active-context guard and fails `TEST_CONTEXT_NOT_ACTIVE`.

Review:

- `supabase/migrations/20260903030011_dd10_one_user_simulation_workspace.sql`
- `supabase/migrations/20260903030014_source_review_remediation.sql`
- `tests/sql/48_dd10_one_user_simulation_workspace.sql`
- `tests/sql/50_source_review_remediation.sql`

### Request terminal-state preservation

A follow-up Attempt may have been opened before its linked Task completes. If a
delayed decline/cancel response arrives after Task completion, it must update the
Attempt history without rolling the Request compatibility tuple backward from
`completed` or erasing `completed_at`.

`tests/sql/51_claude_source_review_remediation.sql` reproduces:

1. create Request;
2. accept -> linked Task;
3. start change follow-up;
4. complete linked Task;
5. decline the older follow-up;
6. require Request and Task remain completed while the follow-up Attempt records
   the decline.

### Handover acknowledgement compatibility

The existing `server_tx_mark_handover_read(...)` path writes the legacy
`handover_reads` row and canonical ActorRef `info_acknowledgements` in the same
DB transaction. The regression then verifies canonical DailyBrief no longer
returns that handover as unread.

Review the implementation plus `tests/sql/51_claude_source_review_remediation.sql`.

### R0 reader activation fence

R0 must not accidentally activate canonical production readers. Authenticated
entrypoints for DailyBrief, Request workspace, and Task result history must fail
closed with the capability-specific reader-disabled error while the gates remain
R0. Shopping is an explicit compatibility exception: the public wrapper returns
a `legacy_r0` shaped workspace without invoking the canonical Shopping reader.

Review:

- `supabase/migrations/20260903030016_r0_reader_request_handover_remediation.sql`
- `supabase/migrations/20260903030017_r0_shopping_reader_fallback.sql`
- PWA Today/Shopping adapters changed in PR #45
- `tests/sql/51_claude_source_review_remediation.sql`

### DD11 reconciliation and final zero gates

The reconciliation/readiness logic must understand valid canonical terminal
states rather than flagging them as legacy anomalies, but it must not suppress
real P1 blockers.

Review:

- `supabase/migrations/20260903030018_dd11_reconciliation_semantics_remediation.sql`
- `tests/sql/49_dd11_cutover_readiness_audits.sql`
- `tests/sql/98_dd11_full_readiness_zero.sql`
- `tests/sql/99_canonical_reconciliation_zero.sql`

`98` runs after feature/adversarial fixtures and requires the sum of **every**
`blocks_p1` audit row to be zero. `99` is lexically last and requires all
canonical foundation reconciliation issue counts to be zero, preventing a later
test fixture from hiding a blocker after an earlier green audit.

## BLOCKER/HIGH gate

Return **NO-GO** for any BLOCKER or HIGH finding in these areas:

1. Test context can reach production LINE/outbox, Google mutation, analytics,
   real consent, or a production reader.
2. Simulated actor is represented by a fake auth/member or the operator UUID.
3. Task mirror, target DELETE, and Family Event writer can concurrently mutate
   one exact `(calendar_connection_id, provider_event_id)` identity.
4. A stale ordinary mirror or deletion job can reach a provider mutation after
   lease expiry/transfer, including a 412 retry path.
5. DD9 explicit fact or AI inference silently applies a Task/Event/Google change,
   crosses child/school scope, or durably stores arbitrary third-party transcript
   /profile/contact data.
6. Canonical command retry/revision paths create duplicate actuals/attempts,
   bypass ActorRef scope, or reconciliation overwrites valid canonical state.
7. A delayed Request follow-up transition can roll a completed Request backward.
8. Same-operation DD10 archive retry fails solely because the context was
   archived, or a different operation mutates an archived context.
9. R0 authenticated product entrypoints can reach canonical production readers
   before explicit reader enablement.
10. DD11 can report green while any `blocks_p1` audit or canonical reconciliation
    issue remains non-zero.
11. P1/production activation is reachable through a default path.

## Evidence to inspect

At minimum:

- `tests/sql/39_dd3a_mandatory_actorref_e2e.sql`
- `tests/sql/41_dd4_dd5_request_task_result_e2e.sql`
- `tests/sql/41_google_projection_test_scope_isolation.sql`
- `tests/sql/44_foundation_source_review_remediation.sql`
- `tests/sql/44_dd4_request_canonical_cutover.sql`
- `tests/sql/45_dd5b_shopping_canonical_e2e.sql`
- `tests/sql/46_dd8_google_provider_ownership_transfer.sql`
- `tests/sql/47_dd9_nursery_intake_pipeline.sql`
- `tests/sql/48_dd10_one_user_simulation_workspace.sql`
- `tests/sql/49_dd11_cutover_readiness_audits.sql`
- `tests/sql/50_source_review_remediation.sql`
- `tests/sql/51_claude_source_review_remediation.sql`
- `tests/sql/98_dd11_full_readiness_zero.sql`
- `tests/sql/99_canonical_reconciliation_zero.sql`
- `supabase/functions/process-family-ops-calendar-outbox/providerMutationFence.test.ts`
- `docs/implementation/FAMILY-OPS-WORK-INTEGRATION-STATUS.md`
- `docs/implementation/FAMILY-OPS-CUTOVER-READINESS-RUNBOOK.md`

For CI, inspect checks attached to the **exact current PR #45 head**. Required
coverage is Web lint/typecheck/test/build; Edge lint/typecheck/unit/auth matrix;
DB empty migration chain plus the complete SQL suite; and real Supabase CLI
stack integration. Historic green runs are not evidence for a later head.

## Explicit fail-closed scope limits

- DD8 Family Event Google writer remains disabled. No real Google mutation is
  authorized by this review package.
- DD9 does not enable Storage deletion, OCR/AI provider calls, or target Task /
  Event adapters.
- DD10 browser/LINE command adapters are not activated and simulation never
  converts to production identity.
- All capability gates remain R0 with mutation paused.
- No production migration/deploy/cron/main merge is part of source review.

## Required verdict format

State one of `GO`, `GO WITH MEDIUM/LOW FOLLOW-UP`, or `NO-GO`. List findings by
severity with file/function, exploit or correctness path, expected invariant,
and the smallest safe remedy. A green CI alone is not a GO.
