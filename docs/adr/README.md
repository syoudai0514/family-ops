# Architecture Decision Records

Lightweight ADRs for explicit implementation and architecture decisions.

Historically, ADR 0001 committed the repository to the vendored
`docs/design/v6/` package as the sole normative source. ADR 0012 deliberately
scope-limits that decision: the current canonical Requirements & UX Baseline
governs product requirements/UX, while v6 remains normative for non-conflicting
architecture and implementation design.

ADR 0013 is **Accepted** after the entire `docs/design/current/` package passed
independent Round 5 verification with `GO` and PR #41 merged the exact reviewed
head `5c85bd1468a624b831493e198b0f88b4ef7c574e`.

ADR 0014 is **Product Owner approved / pending canonical merge** for CF-11. It
right-sizes the legacy v6 R2/age backup mechanics to the current two-person
household by using the existing separate `app-save-hub` Supabase project and
existing GitHub/Supabase credentials. Under ADR 0012 it is not Accepted/canonical
until the reviewed proposal reaches protected `main`.

## Index

- [0001](0001-v6-baseline-commitment.md) — Original v6 normative-source
  commitment; **superseded in part by 0012 for requirements/UX scope**
- [0002](0002-dropoff-pickup-setup-endpoint.md) — A new `configure-dropoff-pickup`
  endpoint fills a real v6 gap (WP2 names the capability, no endpoint is named)
- [0003](0003-ai-draft-propose-endpoint.md) — AI draft endpoints fill a real v6 gap
- [0004](0004-google-oauth-state-not-mutation-receipt.md) — Google OAuth state replay guard
- [0005](0005-google-calendar-new-error-codes.md) — shared Google Calendar error catalogue
- [0006](0006-notification-outbox-delivery-bridge-and-conflict-deferral.md) — notification delivery bridge
- [0007](0007-wp8-routine-session-scope-decisions.md) — WP8 routine-session scope decisions
- [0008](0008-routine-digest-calendar-merge-and-conflict-warning.md) — routine digest/calendar merge
- [0009](0009-line-quick-reply-and-reply-first-delivery.md) — LINE quick-reply/reply-first delivery
- [0010](0010-line-item-by-item-flow-and-skip-confirmation.md) — LINE item flow/skip confirmation
- [0011](0011-pending-action-review-and-today-schedule.md) — pending review/Today schedule
- [0012](0012-requirements-ux-canonical-governance.md) — canonical Requirements & UX governance
- [0013](0013-current-detailed-design-architecture-evolution.md) — **Accepted:** canonical current detailed design
- [0014](0014-right-sized-household-backup-recovery.md) — **Product Owner approved / pending canonical merge:** reserved `app-save-hub` namespace, actual backup/read-back/freshness, disposable restore, Auth rebind and authenticated household-access proof; R2/age is superseded only after protected merge

## Format

Each ADR is a short Markdown file: title, status, context, decision,
consequences. Number sequentially (`0001-`, `0002-`, ...). Superseding an
earlier decision adds a new ADR and marks the old decision's status with the
superseding ADR rather than editing history away.
