# Lane A — Request canonicalization

Status: implementation in progress; **not review-ready / no merge / no production apply**.

Baseline fresh-read main: `6d93ba0d5b6ed1d6dbc3bbf8ec0a973f898d30ff`; CI #743 (`34183823528`) successful. Open PR on initial inspection: draft documentation PR #46 only. No AGENTS.md found in checkout. Authority: user-provided Requirements → Appendix A → accepted final UX → ADR 0013 → current design → implementation. Historical release/implementation matrices are not evidence of current conformance.

Scope: CF-01 and CF-12; Q2/Q4/Q30/Q36/Q43/Q45/Q47/Q78/Q83 plus baseline §7 lifecycle and stale-action guarantees.

## Active path inventory

| Surface | Baseline decision/write path | Candidate disposition |
|---|---|---|
| PWA Requests accept | assignment Edge → legacy accept RPC | common snapshot-bearing transition adapter |
| PWA negotiation | negotiate RPC, default-to-current revisions | explicit attempt/revision/terms command |
| LINE assignment postback | ID-only accept/decline RPC | same transition adapter; old buttons fail closed |
| LINE / PWA sender pending draft | process-pending-actions → assignment create RPC | canonical attempt and task revision snapshot |
| Legacy assignment accept RPC | pending status + direct assignment writes | stale-only compatibility endpoint |
| Legacy generic accept/decline/cancel | automatically selects latest attempt | assignment requests fail closed |
| Canonical acceptance | rejects assignment kind | atomic application helper within shared command |
| Notifications / outbox | legacy direct insert and enrichment | canonical notification intent with immutable attempt snapshot |
| Expiry | no active RequestAttempt expiry writer found | shared helper called by command and worker |
| Scope mapping | assignment_change_request_tasks | historical only, no new-runtime dependency |
| AI draft confirmation | omitted reply deadline | v2 confirmation preserves explicit deadline |
| Older light request creators | v1 uses work deadline as reply deadline | v1 delegates to common v2 proposal rule |
| PWA request buckets | legacy status + work due | attempt state + reply deadline |

## Verification still required

- Run complete SQL suite and failure-injection fixtures on PostgreSQL.
- Finish reply proposal preview across channels and remove daily read-model work-deadline fallbacks.
- Validate pending-action snapshot binding and expired-result UX through actual LINE/PWA integration.
- Resolve concrete consulting terms and reproposal UX against the approved contract; text-only candidate confirmation is insufficient for changed assignment dates/scope.
- Verify multi-task followup semantics, historical pending assignment migration and full repository remaining-write audit.
- Run CI on exact candidate HEAD; report gaps honestly rather than treating successful unit tests as conformance.
