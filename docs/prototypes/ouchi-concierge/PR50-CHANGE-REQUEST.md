# PR #50 — Approved UX change request before final independent review

Target implementation branch: `impl/issue-48-ux-closeout`

This is a user-approved change request. Apply it **before** requesting final independent review. Do not treat this as a reviewer suggestion to be evaluated after the review; it is part of the intended UX contract.

## Required changes

### A. Compact transport calendar title

Narrow calendar surfaces, especially Google Calendar month view, must use compact transport tokens with no whitespace or separator:

- both: `送P迎M`
- dropoff only: `送P`
- pickup only: `迎M`

Do not emit `送 P | 迎 M`, `送P | 迎M`, `送P｜迎M`, or similar wider variants.

Keep canonical transport data structured; this is presentation/title formatting only. Detailed PWA views may expand full actor names.

Add regression tests for exact rendered/exported title strings so spaces/full-width separators cannot regress.

### B. Month day selection

Month page: tapping/selecting a date must keep the calendar visible and render a concise summary directly below it with that day's:

- schedules/events
- transport assignment
- relevant ToDos/preparation

From the inline summary, offer detail/edit/add. Do not force every tap directly into a full-screen day-detail route.

### C. Period-scoped weekly transport templates

User-facing routine model:

- one weekly dropoff/pickup template per validity period;
- end date defaults to indefinite;
- adding a later template automatically closes the immediately preceding open-ended template on the prior day;
- periods do not overlap;
- historical periods remain inspectable;
- explicit occurrence/day overrides and individual agreements are preserved and are not silently rewritten;
- same-series future agreement conflicts are grouped for review rather than occurrence-by-occurrence.

Example:

- before: `2026/9/1 – indefinite`
- add new template from `2026/10/1`
- after: old = `2026/9/1 – 2026/9/30`; new = `2026/10/1 – indefinite`

### D. Day-level occurrence override

A one-day change is an occurrence override, not a period-template edit. Removing the override restores that date to the applicable period template.

### E. Canonical docs

Update `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md` and affected `docs/design/current/` documents in the same PR so the user-approved behavior is not left only in prototype/chat artifacts.

The changes should concretize, not contradict, existing requirements around validity-period weekday rules, day/period overrides, protected individual agreements, Month/Day UX, and compact transport display.

### F. Fixture warning

Prototype/sample chore names are not defaults. Do not seed or require chores/subtasks solely because they appear in the UX sample.

## Review sequencing

1. incorporate this change request on PR #50;
2. update canonical docs/design and tests;
3. run affected Web/Edge/DB/real integration suites;
4. freeze an exact PR head;
5. only then request final independent requirements-conformance review.

Do not ask the independent reviewer to review an old head and simultaneously absorb these new user-approved changes. The reviewer should evaluate one stable, final candidate.
