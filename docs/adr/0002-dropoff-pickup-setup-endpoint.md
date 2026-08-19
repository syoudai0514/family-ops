# 0002. A new `configure-dropoff-pickup` endpoint fills a real v6 gap

## Status

Accepted

## Context

`docs/design/v6/10_WORK_PACKAGES.md`'s WP2 line item explicitly requires
"initial dropoff/pickup times and weekly assignee setup." Exhaustive review
of the vendored v6 design package — every prose doc, the full 52-function
`EDGE_FUNCTION_AUTH_MATRIX.md` / `docs/design/v6/supabase/config.toml`
snapshot, and the review-history documents — found no named endpoint for
this. The only generic contract that could plausibly cover it,
`change-recurrence`, is explicitly WP3 (Recurrence engine) scope and is not
implemented as of this ADR. `configure-evening-routines` (WP1, already
implemented and reviewed) is hard-locked to accept exactly the 7 canonical
evening-task codes and rejects anything else with `INVALID_INPUT` — it
cannot be repurposed for dropoff/pickup without breaking its own reviewed
contract.

Per ADR 0001, this repository does not draft a new design (no v7) and does
not treat the implementation as free to invent scope. This is the one
specific case where the vendored design names a required capability without
naming the endpoint that delivers it.

## Decision

Add one new Edge Function/RPC pair, `configure-dropoff-pickup` /
`server_tx_configure_dropoff_pickup`
(`supabase/migrations/20260819000018_dropoff_pickup_setup.sql`), built by
mirroring `configure-evening-routines`'s already-implemented, already
SOL-reviewed batch shape as closely as possible — same claim-then-fill
idempotency, same "no partial save" validate-before-mutate pattern, same
version-bump-on-change / future-todo-only reconciliation / 14-day
materialize-window mechanics, same `households.<step>_setup_completed_at`
completion-flag convention. It differs only where the domain requires it:
dropoff/pickup task definitions cannot use role-based `assignee_strategy`
(would be circular — a dropoff/pickup rule assigning "whoever does
dropoff/pickup" per `08_RECURRING_TASKS_AND_RULES.md` #4), so this endpoint
only ever writes `'fixed'` strategy rows, and the batch may cover any
subset of the 14 `(dropoff|pickup) x (weekday 1-7)` combinations rather than
requiring a complete batch.

`scripts/check-edge-auth-matrix.mjs` explicitly allowlists this one
function name as a documented exception to "every deployed function must be
in the normative 52-function matrix," rather than weakening that check for
everything. `supabase/config.toml` cross-references this ADR at the
function's declaration.

## Consequences

- If a future WP3 `change-recurrence` implementation supersedes this
  endpoint, retiring `configure-dropoff-pickup` is a deliberate follow-up
  decision (its own ADR entry, per the format in `docs/adr/README.md`), not
  a silent removal — the household setup wizard's dropoff/pickup step
  depends on it existing.
- Any reviewer auditing "does every deployed function match the v6 design
  matrix" will find this one intentional, documented exception rather than
  an unexplained drift.
- No other WP2 endpoint follows this pattern — every other new function in
  this round (`create-task`, `send-request`, `add-shopping-item`, etc.) is
  a named, normative-matrix member.
