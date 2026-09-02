# Family Ops — WP-DD1B / DD2 remainder / DD3A / DD3 Parallel Implementation

## Status

**IMPLEMENTATION IN PROGRESS / STACKED ON PR #43 FIXED HEAD / DO NOT REVIEW OR MERGE YET**

This branch is intentionally stacked on the fixed PR #43 source-review head:

`0061928ca55d5e5a0cb9492e8bf87820d9dd7a83`

PR #43 remains frozen while independent source re-review runs. This branch may advance in parallel, but it must not be merged to `main` until its dependency is resolved and the branch is rebased/retargeted onto the accepted main lineage.

## Consolidated scope goal

To reduce repeated review overhead, the next review unit aims to finish as much as can safely be reviewed together from:

- remainder of WP-DD1 schema foundation;
- remainder of WP-DD2 compatibility/reconciliation prerequisites needed by the command layer;
- WP-DD3A test identity + side-effect sandbox foundation;
- WP-DD3 canonical transaction / concurrency foundation.

It remains before user-facing aggregate cutover. No P1, production migration apply, Google Authority activation, or normal LINE/PWA canonical reader cutover is authorized by this branch.

## Implemented so far on this parallel branch

### Test execution / side-effect sandbox foundation

- `private.fn_validate_execution_context_v1` validates server-supplied operator/household/ActorRef/test-context combination;
- production execution rejects simulated ActorRef;
- test execution requires active context owned by the authenticated real operator identity supplied by the server;
- dedicated `private.test_delivery_outbox` physically separates synthetic operator delivery from production `notification_outbox`;
- synthetic delivery stores operator provenance and semantic ActorRef separately;
- archived test context cannot authorize a new synthetic delivery;
- `private.canonical_operation_receipts` gives operation idempotency a canonical identity of semantic actor + execution scope rather than overloading legacy operator `actor_id`;
- `private.pending_actions` test ActorRef/test-context is now DB-validated while legacy `actor_id` remains operator provenance;
- `private.mutation_receipts.actor_id` remains operator provenance while its optional canonical ActorRef/test-context is independently DB-validated.

### SQL coverage

`tests/sql/38_test_execution_sandbox_foundation.sql` covers:

- simulated actor resolves only in test mode;
- operator mismatch is rejected;
- production execution with simulated actor is rejected;
- dedicated synthetic delivery is test-only and preserves operator vs semantic actor separation;
- same operation ID can exist for production papa and simulated mama without receipt collision;
- pending action / legacy mutation receipt preserve operator provenance and simulated domain actor separately;
- archived test context rejects new delivery.

## Still to implement before this branch becomes a source-review candidate

- remaining direct test-scope/read leakage guards identified by canonical design;
- fail-closed adapter boundary proving test execution cannot enqueue production LINE/Google/real-consent effects;
- canonical command receipt helper/replay semantics;
- optimistic revision guard shared by mutable aggregate commands;
- Task waiting/resume, assignment/claim/takeover, completion/correction command contracts;
- group reconciliation command contract;
- Request Attempt transition command contract;
- canonical notification intent transaction hook foundation;
- tests for stale revision, replay/conflict, terminal-attempt no-reopen, performer preservation, and transaction atomicity.

## Dependency rule

If PR #43 receives another required fix, apply the same fix to this stacked branch before any review request. If PR #43 is accepted and merged, retarget/rebase this branch onto the resulting `main` before final source review.
