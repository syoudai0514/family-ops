# Architecture Decision Records

Lightweight ADRs for decisions made during implementation that aren't
themselves part of the vendored v6 design package (`docs/design/v6/`, which
remains normative and is never edited by an ADR). An ADR here records a
decision this repository's implementation committed to, and why.

## Index

- [0001](0001-v6-baseline-commitment.md) — Commit to the v6 design package as
  the sole normative source; no v7
- [0002](0002-dropoff-pickup-setup-endpoint.md) — A new `configure-dropoff-pickup`
  endpoint fills a real v6 gap (WP2 names the capability, no endpoint is
  named for it)
- [0003](0003-ai-draft-propose-endpoint.md) — `propose-ai-draft`/
  `confirm-request-draft`/`confirm-handover-draft` fill a real v6 gap (the
  AI-draft propose/confirm flow is described in prose, no endpoint names
  are given)
- [0004](0004-google-oauth-state-not-mutation-receipt.md) — Google Calendar
  OAuth start/callback use the design's own single-use state-hash replay
  guard, not the standard `operation_id`/`mutation_receipts` pattern (no
  JWT/body exists on Google's own redirect)
- [0005](0005-google-calendar-new-error-codes.md) — WP7's new error codes
  temporarily lived in a local `googleCalendar.ts` map during parallel-agent
  development, then folded into the shared `_shared/errors.ts` catalogue in
  a follow-up consolidation pass
- [0006](0006-notification-outbox-delivery-bridge-and-conflict-deferral.md) —
  A new trigger bridges WP2's in-app notifications into the LINE delivery
  outbox with bundling; a standalone calendar-conflict notification was
  deliberately deferred to WP8 rather than guessed at
- [0007](0007-wp8-routine-session-scope-decisions.md) — WP8 routine-session
  scope decisions: RPC-layer LINE-postback readiness vs. actual webhook
  wiring, reused error codes, in-place amendments to two pre-existing
  functions, and the scope boundary of the reassignment session-supersede

## Format

Each ADR is a short Markdown file: title, status, context, decision,
consequences. Number sequentially (`0001-`, `0002-`, ...). Superseding an
earlier decision adds a new ADR and marks the old one's status
`Superseded by NNNN`, rather than editing history away.
