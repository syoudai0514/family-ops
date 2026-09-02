# 0001. Commit to the v6 design package as the sole normative source

## Status

Accepted — **superseded in part by ADR 0012** for requirements / UX scope.

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
follow, **subject to the scope limitation introduced by ADR 0012**.
Concretely:

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
- No v7 design is created merely through implementation drift. A genuine,
  deliberate change to product scope or architecture gets its own ADR and
  canonical requirements/design update rather than a silent fork.
- CI (`scripts/check-edge-auth-matrix.mjs`) enforces one concrete instance
  of this: every Edge Function actually deployed under `supabase/functions/`
  must match its `verify_jwt` classification from the v6-vendored
  `docs/design/v6/EDGE_FUNCTION_AUTH_MATRIX.md` /
  `docs/design/v6/supabase/config.toml` snapshot exactly.
- After ADR 0012 is Accepted, product requirements and UX behavior are
  governed by `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`.
  v6 remains normative for non-conflicting architecture and implementation
  design. Any cross-boundary conflict must be resolved explicitly by ADR
  before implementation.

## Consequences

- Reviewers can resolve requirements/UX questions against the canonical
  Requirements & UX Baseline once ADR 0012 is Accepted.
- Reviewers can continue to rely on `docs/design/v6/` for non-conflicting
  architecture/implementation decisions.
- A work package that appears to need behavior neither the Baseline nor v6
  describes is a signal to clarify requirements/design explicitly, not to
  invent new scope in implementation.
- A future product-direction or architecture change is recorded explicitly
  through the Baseline and, where necessary, a new ADR.
