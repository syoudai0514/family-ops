# 0013. Adopt the current detailed design and evolve conflicting v6 domain architecture

## Status

Proposed — becomes Accepted only if the detailed-design PR passes independent review with `GO` and is merged.

## Context

ADR 0012 established:

- `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md` as the normative requirements/UX source;
- `docs/design/v6/` as still normative for non-conflicting architecture/implementation decisions;
- architecture/API/schema/security conflicts must be explicitly resolved by ADR before implementation.

The accepted Requirements Baseline deliberately changes several product semantics that cannot be implemented safely by only changing UI labels over the v6 data model.

Important examples:

1. Request is canonical only through agreement; after acceptance the linked ToDo owns execution state. v6 currently gives `requests.status` its own `completed` lifecycle.
2. One task may have multiple actual performers. v6/current schema has one `actual_completed_by_id`.
3. `誰でもOK` has an independent claim lifecycle that must not become a permanent assignment.
4. `大体やった` is group-level reconciliation evidence and must not be a child-task status.
5. Human-confirmed event values must be protected from silent Google/image/AI overwrite. v6 states the shared Google secondary calendar is the family schedule source of truth.
6. The new product notification model uses morning/evening anchors plus meaningful exceptions rather than preserving every v6 routine push time as normative product behavior.
7. One-user simulation must reuse domain state machines while blocking production recipient/Google/outbox side effects.

The repository should not fork `docs/design/v6/` into an implicit v7 or rewrite vendored v6 files in place. The architecture evolution needs an explicit canonical reviewed location.

## Decision

If this ADR and the detailed-design PR are accepted:

1. `docs/design/current/` becomes the **canonical detailed design for behavior governed by the current Requirements Baseline**.
2. `docs/design/v6/` remains authoritative for architecture/security/provider mechanics that do not conflict with the Requirements Baseline, this ADR, or `docs/design/current/`.
3. The following v6/current architecture semantics are explicitly superseded for the next implementation:

   ### Requests
   - v6 `requests.status=completed` is no longer an independent execution truth.
   - logical Request + negotiation Attempt owns agreement lifecycle.
   - accepted execution is owned by linked Task.
   - legacy request status columns may remain during compatibility migration but are not the new canonical runtime truth.

   ### Task actual performer
   - single `task_instances.actual_completed_by_id` is superseded as the canonical performer model.
   - actual participants are modeled separately and may contain multiple performers.
   - the legacy column may be mirrored temporarily for compatibility but cannot be used as the long-term truth.

   ### Assignment / anyone claim
   - assignment mode (`person`, `unassigned`, `anyone`) and active anyone claim are independent dimensions.
   - claim does not rewrite assignment mode to person.

   ### Group reconciliation
   - `大体やった` is stored as group reconciliation evidence.
   - it cannot mutate unknown child tasks to completed/failed merely to close the input session.

   ### Family Event / Google authority
   - a Family Ops family-event aggregate owns current household event semantics where the app needs event preparation/history/protected values.
   - Google cache remains the canonical observation of Google provider state, not the unconditional household-domain event truth.
   - linked Google changes auto-apply only when permitted by Authority/follow rules; otherwise they become candidates/diffs.
   - existing Google OAuth, watch, sync-token, occurrence projection, write-idempotency, ETag, credential-binding, and provider-security mechanics remain valid unless a later ADR explicitly changes them.

   ### Notification product behavior
   - Requirements Baseline morning/evening anchors and immediate meaningful exceptions supersede conflicting v6 user-facing routine-push cadence.
   - existing durable inbox/outbox, retry, quota, dedup, reply-first, and worker security mechanics remain valid and should be reused.

   ### Test simulation
   - production state machines may be reused under a server-validated test execution context.
   - simulated actors may not create production recipient delivery, production notification outbox, Google writes, or real-user consent effects.

4. Public user mutations continue through JWT-authenticated Edge Functions and server-only transactional RPCs. `private.mutation_receipts`/equivalent operation idempotency remains the default mutation pattern.
5. Migration is additive and compatibility-first. Existing migrations are never rewritten, production reset is not used, and destructive cleanup of legacy columns is deferred to a separately reviewed later migration after cutover.
6. The canonical current/read truth for each concern is explicitly documented in `01_ARCHITECTURE_AND_DOMAIN_BOUNDARIES.md`; implementation must not choose an alternate truth ad hoc.
7. If implementation discovers a required product-behavior change, the Requirements Baseline must be updated/reviewed before or with that implementation. If architecture scope changes beyond this ADR, add/amend an ADR rather than silently drifting.

## Relationship to ADR 0001 and ADR 0012

- ADR 0001 remains partially superseded by ADR 0012 for requirements/UX scope.
- ADR 0012 remains the governance authority separating requirements/UX from non-conflicting legacy architecture.
- ADR 0013, if accepted, explicitly authorizes the architecture/schema/API evolution needed to implement the accepted Requirements Baseline while retaining useful v6 mechanics.

Resulting practical hierarchy:

1. accepted ADR governing the exact architecture decision;
2. canonical Requirements Baseline for product behavior;
3. `docs/design/current/` for reviewed current detailed design;
4. `docs/design/v6/` for non-conflicting legacy design constraints;
5. code/tests.

No implementer may resolve a conflict by selecting whichever document is easier to code.

## Consequences

### Positive

- Request/task/actual/assignment/source truth is explicitly separated.
- Existing production architecture is reused rather than fully rewritten.
- Google security/sync correctness remains protected while product-level Authority semantics evolve.
- migrations can be staged additively.
- detailed design has a stable canonical path without `V7`/`FINAL` copies.

### Cost / complexity

- schema additions and compatibility backfill are required.
- Requests and actual completion require deliberate cutover rather than cosmetic frontend changes.
- Family Event/candidate layer is new architecture.
- test simulation requires a hard side-effect adapter boundary.

These costs are accepted because continuing the old single-state assumptions would create multiple competing truths and unsafe silent updates.

## Review gate

This ADR must not become Accepted merely because it exists on a branch. Independent review must evaluate the entire `docs/design/current/` package and return `GO`. `BLOCKER` or `HIGH` findings must be resolved before merge/implementation.
