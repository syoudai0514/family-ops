# 0001. Commit to the v6 design package as the sole normative source

## Status

Accepted

## Context

The repository vendors a full design package at `docs/design/v6/`
(`family-ops-sonnet-plan-v6`) — product scope, UX/screens, domain and data
model, security/RLS/privacy policy, LINE integration, routine/LINE
automation, API and Edge Function contracts, DDL contract, test and
acceptance criteria, work packages, and fixtures. Earlier design iterations
(v1–v5) exist in the project's history but are explicitly out of scope for
implementation decisions.

Through several rounds of implementation and review-driven fixes (schema,
RLS, the `server_tx_*` mutation boundary, Edge Functions, the canonical
task-definition bootstrap, evening-routine setup, LINE quota reservation,
the Supabase CLI integration CI job, Google Sign-In wiring), every fix has
been made by correcting the *implementation* against v6's stated intent —
never by revising, replacing, or forking the vendored v6 documents
themselves, and never by drafting a v7.

## Decision

`docs/design/v6/` is the single normative design source for this
implementation, for the entirety of WP0/WP1 and all work packages that
follow. Concretely:

- Files under `docs/design/v6/` are treated as read-only reference material
  from the implementation's side. When implementation code, migrations,
  Edge Functions, or tests are found to diverge from v6's intent, the fix
  changes the implementation — never the vendored v6 document.
- Where a past round's implementation was itself found to encode a mistake
  from an earlier v6 reading (e.g. `weekly_digest`/Sunday-12:00 as a
  `schedule_kind`, later retired in favor of the 9-kind model; the
  `current_date` vs. Asia/Tokyo timezone bug in
  `configure-evening-routines`), the fix corrects the implementation to
  match v6's actual, more carefully-read intent — this is implementation
  bug-fixing, not a design revision, and does not touch `docs/design/v6/`.
- No v7 design is created. A genuine, deliberate change to product scope or
  architecture — should one ever be needed — gets its own ADR proposing
  that change explicitly, not a silent drift into a new vendored design
  package.
- CI (`scripts/check-edge-auth-matrix.mjs`) enforces one concrete instance
  of this: every Edge Function actually deployed under `supabase/functions/`
  must match its `verify_jwt` classification from the v6-vendored
  `docs/design/v6/EDGE_FUNCTION_AUTH_MATRIX.md` /
  `docs/design/v6/supabase/config.toml` snapshot exactly.

## Consequences

- Reviewers can always resolve an implementation-vs-design disagreement by
  reading `docs/design/v6/` directly; there is never a second, competing
  "current" design to reconcile against it.
- A work package that appears to need behavior v6 doesn't describe is a
  signal to re-read v6 more carefully or ask, not to invent new scope near
  it.
- Should a real product-direction change become necessary later, it is
  recorded as a new, explicit ADR (and, if it changes the normative design
  itself, as a genuinely new versioned design package with its own
  vendoring step) — not as an implicit v7 assembled from scattered
  implementation deviations.
