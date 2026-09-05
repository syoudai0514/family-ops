# おうちコンシェルジュ / おうちノート UX prototype

Design-only interactive prototype / UI contract for Family Ops / おうちノート.

## Current implementation handoff

Use these files together:

- `UX-CONTRACT-FINAL-SPEC.md` — final screen / state / transition contract
- `UX-CONTRACT-FINAL-AUDIT.md` — canonical traceability / audit scope
- `UX-CONTRACT-APPROVED-DELTAS.md` — user-approved refinements after the first final audit

The latest no-script iPhone-safe HTML delivered to the user has SHA-256:

`c1afa191a8e02f86683e886e0c59a60019b7388531dde19f96de690e8b9e2007`

It includes the approved period-template routine model, inline Month day summary, compact transport token contract, and fixture warning.

The older `index.html`, `prototype.css`, `prototype.js`, and versioned V3/V4/V5 documents are historical design iterations and must **not** override the final spec/audit, approved deltas, or canonical requirements.

## Canonical authority

Requirements / UX authority remains:

`docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`

The final audit fresh-read Appendix A literally and maps all 114 decision rows (`Q1`–`Q112` plus `Q60-1` / `Q60-2`). The prototype/spec/delta documents are implementation aids, not a second requirements authority.

User-approved refinements that make an existing canonical rule more concrete must be incorporated into the canonical requirements/design on PR #50 before final independent re-review. See `UX-CONTRACT-APPROVED-DELTAS.md`.

## Final product loop

The primary loop is:

**今日の状況を最初に把握 → 要対応へ直接移動 → 今やる親タスクと小作業を理解 → その場で完了 → 夜は残りだけをまとめて実績化 → 例外だけ深掘り**

Key final decisions include:

- Today first-view linked situation summary
- morning/day/evening runtime composition
- parent-task + subtask progress
- exact bulk actual scope with `余力があれば` excluded
- immediate completion + evening reconciliation
- post-bulk correction / undo
- request / share / owner / anyone / waiting / carryover state coverage
- text + transcription-first `おうちコンシェルジュ`
- nursery Q89–Q106 review surfaces
- Google Q110–Q112 decisions + shared Authority conflict review
- Month date tap → inline day summary → detail/edit only when needed
- transport compact token on narrow calendar surfaces: `送P迎M` / `送P` / `迎M`
- weekly transport template per validity period, default end = indefinite; future template auto-closes the previous open-ended period
- occurrence/day override remains independent from the period template
- real back/scroll/form/details/daypart/tab restoration contract
- Loading / Empty / Error / Stale states

## Prototype fixture rule

Chore names, event names, dates, assignees, subtasks and counts shown in prototype HTML are UX fixtures only. They are **not** product defaults or mandatory household data. Production must render CURRENT household data and configured rules.

## Implementation rule

Reproduce the final contract's information hierarchy, wording, scope visibility, normal-vs-exception disclosure, state transitions, and return-state behavior while reusing CURRENT canonical domain/API/state logic.

Do **not** copy prototype demo JavaScript as production business logic or introduce a second parser/state machine.

This remains a design artifact only. It does not call production APIs, send LINE messages, mutate Google Calendar, apply migrations, merge main, or change production data.
