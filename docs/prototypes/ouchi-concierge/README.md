# おうちコンシェルジュ / おうちノート UX prototype

Design-only interactive prototype / UI contract for Family Ops / おうちノート.

## Final audited contract

The final UX review has moved beyond the original concierge-only prototype.

Use these files as the implementation handoff:

- `UX-CONTRACT-FINAL-SPEC.md` — final screen / state / transition contract
- `UX-CONTRACT-FINAL-AUDIT.md` — canonical traceability and 100-point audit result

The exact final interactive HTML delivered with the review has SHA-256:

`42b5a0630d699f969edf14b9b53b0b8bc5fc725c28b5af352a1f9adc050666b4`

The older `index.html`, `prototype.css`, `prototype.js`, and versioned V3/V4/V5 documents are historical design iterations and must **not** override the final spec/audit or the canonical requirements.

## Canonical authority

Requirements / UX authority remains:

`docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`

The final audit fresh-read Appendix A literally and maps all 114 decision rows (`Q1`–`Q112` plus `Q60-1` / `Q60-2`). The prototype/spec is an implementation aid, not a new requirements authority.

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
- literal LINE reference contract
- nursery Q89–Q106 review surfaces
- Google Q110–Q112 decisions + shared Authority conflict review
- real back/scroll/form/details/daypart/tab restoration contract
- Loading / Empty / Error / Stale states

## Implementation rule

Reproduce the final contract's information hierarchy, wording, scope visibility, normal-vs-exception disclosure, state transitions, and return-state behavior while reusing CURRENT canonical domain/API/state logic.

Do **not** copy prototype demo JavaScript as production business logic or introduce a second parser/state machine.

This remains a design artifact only. It does not call production APIs, send LINE messages, mutate Google Calendar, apply migrations, merge main, or change production data.
