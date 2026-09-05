# おうちノート UX Contract — FINAL 100-point audit

## Status

- Audit date: 2026-09-05
- Artifact purpose: implementation-facing UI / interaction contract
- Canonical requirements: `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`
- Fresh-read canonical blob: `17cbcd1e03ea8c9ee45277778b4590cd6d1d9b2d`
- CURRENT implementation reference at final UX-audit start: PR #50 head `2e51e9d9febc76bddfa7ac953d8acdf6a08f1207` (Draft / open / unmerged)
- Exact final HTML SHA-256: `42b5a0630d699f969edf14b9b53b0b8bc5fc725c28b5af352a1f9adc050666b4`

## Verdict

**100 / 100 for UI / interaction-contract completeness against the canonical requirements.**

This verdict is deliberately narrower than implementation conformance. It does **not** claim PR #50 or the production system is 100% conformant. UI cannot prove webhook idempotency, stale/CAS safety, household/actor/conversation isolation, provider mutation ownership, notification deduplication, test-mode side-effect fences, RLS/privacy enforcement, or other source/runtime properties. Those remain source/test responsibilities and are explicitly separated instead of being represented by fake UI.

## Canonical traceability

Appendix A was fresh-read literally, not from the historical PR #50 matrix summary.

- decision rows: **114 / 114 mapped** (`Q1`–`Q112` plus `Q60-1` / `Q60-2`)
- UI-visible decisions: mapped to concrete screens / states / transitions
- cross-surface decisions: mapped to both PWA / LINE reference where applicable
- non-UI decisions: mapped to source/test responsibility
- no decision row is left unmapped

The final HTML contains an embedded `Q対応表` with the literal decision text and target surface for every decision row.

## Audit method — repeated generation / review

### Pass 1 — traceability

All 114 decision rows were mapped. Mapping-only success was rejected as insufficient.

### Pass 2 — screen evidence

Each mapped UI requirement was checked for a concrete screen action/state rather than merely appearing in the trace table. This drove additions/fixes for:

- Today first-view summary and direct jumps
- morning/day/evening Today composition
- parent-task + subtask progress
- exact bulk-completion scope
- `余力があれば` exclusion
- waiting / next-check
- actual-input three-way reconciliation
- post-bulk correction / undo
- request negotiation states and deadlines
- handover acknowledgement semantics
- anyone-owner claim / release / takeover
- event template + AI candidate + human confirmation
- multi-intent / ambiguity-only AI confirmation
- LINE fixed menu / Today / input / image triage reference
- nursery provenance / privacy / recurrence / exception / URL / evidence flows
- Google change / delete / duplicate decisions
- history correction and audit display

### Pass 3 — semantic edge review

A second manual requirements read found subtler gaps after the first full-screen pass. These were fixed before the final score:

- per-request reminder override
- LINE read != explicit handover acknowledgement
- `相談する` = counterpart condition consultation
- bulk future-rule conflicts confirmed with both parties while preserving individual agreements
- Today daypart is runtime-auto-selected; prototype tabs are review controls only
- early work distinguishes `前倒し推奨` vs `事前完了必須`
- nursery `その他の予定` is actually inspectable, not just counted
- LINE morning composition includes own morning + night + spare-capacity work
- LINE evening composition collapses completed morning work
- `コメント付きで難しい` shows the softened final candidate before a single final send
- generic Authority review compares protected human value, Google candidate, nursery source fact, and AI inference with provenance

### Pass 4 — final mechanical / interaction audit

**100 / 100 checks PASS.** The checks cover these groups:

1. canonical traceability / literal Q evidence
2. Today hierarchy / summary / daypart / partner summary / future work
3. task / subtask / waiting / carryover / optional time fields / owner semantics
4. reconciliation / individual actual / original-date attribution / no user-managed actual time
5. request / negotiation / expiry / change / cancellation / linked-ToDo truth
6. share / handover / validity / acknowledgement
7. shopping / anyone-owner claim/release/takeover
8. event / AI candidate / no event coordinator
9. PWA concierge / voice transcription / multi-intent / ambiguity-only clarification / terminology / duplicates
10. LINE fixed menu / Today / Input / Add / Other / image triage / deep link / no self-echo
11. nursery Q89–Q106 surfaces
12. Google Q110–Q112 surfaces and shared Authority review
13. test mode / history / delete semantics
14. loading / empty / error / stale UI states
15. browser-back / scroll / form / details / daypart / tab state restoration
16. mobile viewport / no-JS Today fallback / route integrity / JS syntax

Mechanical results:

- UI route screens: **34**
- normal user-flow routes reachable from Today/global navigation: **31**
- developer-only routes: `coverage`, `non_ui_contract`, `states`
- unresolved route references: **0**
- duplicate HTML IDs: **0**
- JavaScript syntax: `node --check` **PASS**

## Core product-direction contract

The implementation must preserve this primary loop:

**今日の状況を最初に把握 → 要対応へ直接移動 → 今やる親タスクと小作業を理解 → その場で完了 → 夜は残りだけをまとめて実績化 → 例外だけ深掘り**

The Today first view must surface actionable summary counts/links, not hide critical information below the fold.

For bulk actual input, `全部やった` must never be context-free. The exact eligible parent/subtask scope must be visible before execution; required/normal work is eligible, `余力があれば` is not.

## Navigation / return-state contract

Implementation must preserve:

- source route
- scroll position
- draft text / form values
- expanded subtask/details state
- selected daypart review state where applicable
- selected tab/filter state

Browser Back and in-app Back must resolve to the same logical prior state. A single item update must not force full page reload or scroll-to-top.

## Implementation-owner rule

Treat the final interactive HTML as a **UI / interaction contract**, not as production business logic.

Reproduce its information hierarchy, wording, scope visibility, normal-vs-exception disclosure, state transitions, and return-state behavior while reusing CURRENT canonical domain/API/state logic. Do not port the prototype demo JavaScript into production as a second business-logic implementation.
