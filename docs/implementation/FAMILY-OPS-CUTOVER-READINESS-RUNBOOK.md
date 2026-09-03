# Family Ops Cutover Readiness Runbook

This runbook is source/readiness only. It does **not** authorize production
apply, production deployment, real provider mutation, or P1.

## Source-review baseline discipline

- Canonical foundation PR #44 is pinned at
  `e2b45cba84bf1e18e92607325823e483ddca8722`; CI run 364 is green.
- PR #45 must always be reviewed and CI-checked using the exact current GitHub
  head at review start. Historic PR #45 head
  `26704f2682ebe3362b4e389e192c8cadbdd5b8f8` and its CI are historical only.
- Do not promote a green CI result from an earlier head to a later head.
- PR metadata/document edits made after a source change do not substitute for
  exact-head CI; the final review-submission head itself must be green.

## Capability stages

| Stage | Allowed state | Rollback behaviour |
| --- | --- | --- |
| R0 | schema/adapters/audits only; canonical production reader/writer disabled; mutation paused | revert deployment or stop using the source; no data rewrite. |
| R1 | separately reviewed compatibility readers/writers only, with reconciliation clean | disable capability and use reviewed compatible/degraded reads. |
| P1 | first new-only canonical truth, recorded by gate metadata | never restore legacy current-truth writer; mutation pause + canonical/degraded read + forward-fix. |

## PR #45 remediation checks

Before independent source review, require all of the following on the exact
submission head.

1. **PR #44 foundation inheritance**
   - current PR #44 forward-only remediation is present in the PR #45 merge/base
     result;
   - household RLS, canonical assignment/reconciliation coexistence, test system
     ActorRef scope, actual performer-kind rules and linked Task -> Request
     completion regressions remain green.
2. **DD8 provider mutation fence**
   - ordinary Task mirror DELETE/INSERT/PATCH calls authorize immediately before
     each provider call;
   - authorization verifies live lease/token, non-transferred ownership, exact
     provider identity/current target and absence of competing Family Event /
     target-deletion ownership;
   - Google 412 re-GET is followed by a fresh authorization before retry;
   - target-deletion DELETE is also freshly authorized.
3. **DD8 adversarial concurrency evidence**
   - race fixtures carry exact `(calendar_connection_id, provider_event_id,
     provider_etag)` identity;
   - active processing lease blocks transfer;
   - expired lease permits transfer;
   - old lease authorization then fails;
   - transferred Task mirror is not re-enqueued;
   - no target-deletion overlap remains and owner audit has
     `active_owner_count <= 1`;
   - rejected provider authorization leaves provider callback count at zero.
4. **DD9 structured persistence privacy**
   - provider metadata and school-context candidate use strict field allowlists;
   - source facts use bounded count/bytes and typed fact-value shapes;
   - AI candidate patches are target-specific and bounded;
   - URL fields accept only bounded HTTP(S) values;
   - transcript/roster/profile/contact-shaped nested data is not accepted as a
     durable structured fact;
   - OCR/AI/Storage/provider/target adapters remain disabled.
5. **DD10 archive idempotency**
   - initial archive completes and persists the canonical receipt;
   - same operation ID + same canonical request hash replays after archival;
   - different operation ID remains a new mutation and fails
     `TEST_CONTEXT_NOT_ACTIVE`.
6. **Request terminal-state safety**
   - linked Task completion synchronizes the Request compatibility tuple;
   - a later response to an older follow-up Attempt may update Attempt history
     but must not clear/replace Request `completed` or `completed_at`.
7. **Handover read compatibility**
   - CURRENT mark-read writes legacy `handover_reads` and canonical ActorRef
     `info_acknowledgements` atomically;
   - canonical DailyBrief agrees that the handover is read.
8. **R0 reader fence**
   - authenticated DailyBrief/Request/Task-history canonical entrypoints fail
     closed while reader gates are R0;
   - Shopping returns only the explicit `legacy_r0` compatibility workspace and
     does not invoke the canonical reader.
9. **DD11 final zero gates**
   - after all feature/adversarial fixtures, every `blocks_p1` audit row sums to
     zero (`98_dd11_full_readiness_zero.sql`);
   - lexically last reconciliation gate reports total zero
     (`99_canonical_reconciliation_zero.sql`).
10. **Exact-head full CI**
    - Web lint/typecheck/test/build;
    - Edge lint/typecheck/unit/auth matrix;
    - DB empty migration chain + complete SQL suite;
    - real Supabase CLI stack integration.

These checks establish source evidence only. They do not constitute an
implementer GO verdict.

## Pre-P1 checklist

1. Obtain independent source-review approval on the exact release candidate.
2. Re-run `private.canonical_cutover_readiness_audit_v1()` against the actual
   production scope and require every blocking count zero.
3. Confirm all capability gates remain R0 until a separately approved release
   operation explicitly changes them.
4. Re-run canonical foundation reconciliation after the latest legacy writer
   activity and require zero relevant issues.
5. Require zero production notification/outbox/Google test leakage.
6. Require zero provider mutation owner overlap; for every future Family Event
   writer scope verify the reviewed exact pre-provider-mutation fence is the
   deployed source.
7. For future DD9 activation, separately review concrete OCR/AI/Storage/provider
   and retention/deletion implementations.
8. For future DD10 interactive activation, separately verify browser/LINE
   adapters cannot convert simulation identity or archived context into a
   production action.
9. Capture current migration history, physical schema, queue lease state,
   provider inventory and capability-gate rows in the release record.
10. Require explicit production authorization. Nothing in PR #45 source review
    implicitly advances R0 to R1/P1.

## Incident procedure after P1

1. Pause affected canonical mutation through an approved, audited operation.
2. Continue canonical or explicitly degraded read; do not restore a legacy
   current-truth semantic writer.
3. Preserve operation receipts, provider identities, audit history and raw-source
   provenance.
4. Apply a forward-fix migration/deployment after independent review. Do not
   perform destructive schema/data rollback.
