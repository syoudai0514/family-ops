# Family Ops Cutover Readiness Runbook

This runbook is source/readiness only. It does **not** authorize production
apply, production deployment, real provider mutation, or P1.

## Source-review baseline discipline

- Canonical foundation PR #44 is currently pinned at
  `6125af780358cd7f8155cc67f8cfe7a4046d0571`.
- PR #45 must always be reviewed and CI-checked using the exact current GitHub
  head at the time of review. Historic review head
  `26704f2682ebe3362b4e389e192c8cadbdd5b8f8` and its CI are historical evidence
  only.
- Do not promote a green CI result from an earlier head to a later head.

## Capability stages

| Stage | Allowed state | Rollback behaviour |
| --- | --- | --- |
| R0 | schema, adapters, audits only; reader/writer disabled; mutation paused | revert deployment or stop using the source; no data rewrite. |
| R1 | reviewed compatibility readers/writers only, with reconciliation clean | disable the capability and use compatible/degraded reads. |
| P1 | first new-only canonical truth, recorded by gate metadata | never restore legacy current-truth reader/writer; mutation pause + canonical/degraded read + forward-fix. |

## PR #45 source-review remediation checks

Before an independent reviewer can assess the remediation submission, require:

1. **DD8 provider mutation fence**
   - ordinary Task mirror DELETE/INSERT/PATCH calls pass through
     `server_tx_authorize_family_ops_calendar_mirror(...)` immediately before
     the provider call;
   - authorization verifies live processing lease/token, non-transferred
     ownership, unchanged provider identity/current target, no Family Event or
     target-deletion owner conflict, and orphan revalidation where applicable;
   - Google 412 re-GET is followed by a fresh authorization before retry
     PATCH/DELETE;
   - target-deletion retry DELETE is also freshly authorized.
2. **DD8 adversarial concurrency evidence**
   - active processing lease blocks Family Event transfer;
   - expired lease permits transfer;
   - old lease authorization then fails;
   - transferred Task mirror is not re-enqueued;
   - no target-deletion overlap remains and provider owner audit remains
     `active_owner_count <= 1`;
   - unit-level provider-mutation callback count remains zero when the fresh
     authorization rejects stale work.
3. **DD10 archive idempotency**
   - initial archive completes and persists the canonical receipt;
   - same operation ID + same canonical request hash replays the same result
     after context status becomes archived;
   - different operation ID remains a new mutation and fails
     `TEST_CONTEXT_NOT_ACTIVE`.
4. **DD9 structured persistence privacy**
   - provider metadata and school-context candidate use strict field allowlists;
   - source facts use bounded count/bytes plus fixed top-level and fact-kind
     value shapes;
   - AI candidate patches are target-specific and bounded;
   - URL fields accept only bounded HTTP(S) values;
   - arbitrary transcript/roster/profile/contact-shaped structured data is not
     accepted as a durable fact;
   - OCR/AI/Storage/provider adapters remain disabled.
5. **Exact-head full CI**
   - Web lint/typecheck/test/build;
   - Edge lint/typecheck/unit/auth matrix;
   - DB empty migration chain plus full SQL suite including remediation tests;
   - real Supabase CLI stack integration.

These checks establish source evidence only. They do not constitute an
implementer GO verdict.

## Pre-P1 checklist

1. Obtain independent source-review approval on the exact release candidate;
   do not substitute implementation ownership or CI success for review.
2. Run `private.canonical_cutover_readiness_audit_v1()` and require every
   blocking count to be zero for the affected scope.
3. Confirm all capability gates are still R0 until the separately approved
   release operation.
4. Re-run Request/Task/participant reconciliation after the latest legacy
   writer activity.
5. Require zero production notification/outbox/Google test leakage.
6. Require zero provider mutation owner overlap. For every Family Event P1
   scope, require no unresolved orphan/lifecycle anomaly and verify the exact
   pre-mutation fencing code from the reviewed source is the deployed source.
7. For any future DD9 activation, separately review the concrete OCR/AI/Storage
   adapter and retention/deletion implementation; the current source package
   deliberately does not activate one.
8. For any future DD10 interactive activation, separately verify browser/LINE
   adapters cannot convert simulation identity or archived-context state into a
   production action.
9. Capture current migration history, physical schema, queue lease state,
   provider inventory, and gate rows in the release record.
10. Require explicit production authorization. Nothing in PR #45 remediation
    implicitly advances R0 to R1/P1.

## Incident procedure after P1

1. Set the affected capability to mutation pause through an approved, audited
   operation.
2. Continue canonical or explicitly degraded read; do not route current truth
   to the legacy semantic writer.
3. Preserve operation receipts, provider identities, audit history, and
   raw-source provenance.
4. Apply a forward-fix migration/deployment after independent review. Do not
   perform destructive schema/data rollback.