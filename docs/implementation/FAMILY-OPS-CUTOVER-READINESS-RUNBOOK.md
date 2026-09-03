# Family Ops Cutover Readiness Runbook

This runbook is source/readiness only. It does not authorize production apply or P1.

## Capability stages

| Stage | Allowed state | Rollback behaviour |
| --- | --- | --- |
| R0 | schema, adapters, audits only; reader/writer disabled; mutation paused | revert deployment or stop using the source; no data rewrite. |
| R1 | reviewed compatibility readers/writers only, with reconciliation clean | disable the capability and use compatible/degraded reads. |
| P1 | first new-only canonical truth, recorded by gate metadata | never restore legacy current-truth reader/writer; mutation pause + canonical/degraded read + forward-fix. |

## Pre-P1 checklist

1. Run `private.canonical_cutover_readiness_audit_v1()` and require every blocking count to be zero for the affected scope.
2. Confirm all capability gates are still R0 until the separately approved release operation.
3. Re-run Request/Task/participant reconciliation after the latest legacy writer activity.
4. Require zero production notification/outbox/Google test leakage.
5. Require zero provider mutation owner overlap. For each Family Event P1 scope, require no unresolved orphan or lifecycle anomaly.
6. Capture current migration history, physical schema, queue lease state, provider inventory, and gate rows in the release record.

## Incident procedure after P1

1. Set the affected capability to mutation pause through an approved, audited operation.
2. Continue canonical or explicitly degraded read; do not route current truth to the legacy semantic writer.
3. Preserve operation receipts, provider identities, audit history, and raw-source provenance.
4. Apply a forward-fix migration/deployment after independent review. Do not perform destructive schema/data rollback.
