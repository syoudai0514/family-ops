# Issue #54 — Final UX Contract → Production Parity Matrix

Status: implementation closeout in progress. `MATCH` requires CURRENT source + deterministic regression; release approval additionally requires Gate C evidence and independent Gate D review.

## Authority and exact contract

- Working branch: `impl/issue-54-final-ux-parity`
- Product authority: `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md` → Appendix A Q1–Q112 → `docs/design/current/` → Accepted ADRs → CURRENT source/schema.
- UI contract: `family-ops-ux-contract-final-v11-noscript.html`
- SHA-256: `c1afa191a8e02f86683e886e0c59a60019b7388531dde19f96de690e8b9e2007`
- Current implementation head before this matrix-only commit: `464157ff086c73268df7ff04c10b8c966d48559e`.
- Current matrix: **MATCH 30 / PARTIAL 3 / MISSING 1**.
- Unweighted progress: **88.2%** (`MATCH / 34`).
- Weighted progress: **92.6%** (`(MATCH + 0.5 × PARTIAL) / 34`).

| # | Contract item | CURRENT deterministic evidence | Status | Remaining |
|---:|---|---|---|---|
| 1 | `today` | `TodayContractPage.tsx`, Today canonical components/tests | MATCH | Gate C |
| 2 | `checkin` | `CheckinPage.tsx`; unique migration `20260907000003_issue54_checkin_bulk_scope_read.sql`; SQL 80 | MATCH | Gate C |
| 3 | `individual` | Check-in seven outcomes + LINE/PWA reference regressions | MATCH | Gate C |
| 4 | `actual_add` | atomic `record-unplanned-actual`; SQL 79 | MATCH | Gate C |
| 5 | `task_form` | three-step modal + session draft regression | MATCH | Gate C |
| 6 | `task_detail` | canonical item/detail/edit + return-state regression | MATCH | Gate C |
| 7 | `groups` | built-in/custom separation + bulk scope regressions | MATCH | Gate C |
| 8 | `requests` | canonical state machine; active/expired/history bucket semantics regression exists | PARTIAL | Wire visual buckets + response return-state/scroll test |
| 9 | `request_form` | raw/private vs shared text, work deadline, preview-before-send | PARTIAL | Distinct initial response deadline + literal semantic explanation + regression |
| 10 | `assignment` | explicit request-vs-agreed endpoint mapping | MATCH | Gate C |
| 11 | `routine_rules` | period rules/override/conflict tests | MATCH | Gate C |
| 12 | `handover` | canonical share/ack/correction/history | MATCH | Gate C |
| 13 | `shopping` | state tabs + claim/release/takeover regressions | MATCH | Gate C |
| 14 | `anyone_owner` | canonical anyone/unassigned/claim UI + tests | MATCH | Gate C |
| 15 | `event` | event project/candidate confirmation flow | MATCH | Gate C |
| 16 | `concierge` | text/suggestion shared proposal layer; no write before confirm | MATCH | Gate C |
| 17 | `transcript` | `ja-JP` speech → editable transcript | MATCH | Gate C/WebKit |
| 18 | `results` | multi-intent selection/clarification/confirm/canonical commit | MATCH | Gate C |
| 19 | `duplicate_review` | generic duplicate decision gate + dedicated Google/Nursery flows | MATCH | Gate C |
| 20 | `nursery` | Q89–Q106 review/diff/provenance/isolation suites | MATCH | Gate C |
| 21 | `google` | protected diff/duplicate triage/provider fences | MATCH | Gate C safe evidence |
| 22 | `conflict_review` | current value + candidates + explicit resolution | MATCH | Gate C |
| 23 | `week` | future assignment/schedule/prep projection | MATCH | Gate C |
| 24 | `month` | compact transport + selected-day agenda | MATCH | Gate C |
| 25 | `dayagenda` | detail/edit and selected-date preservation | MATCH | Gate C |
| 26 | `history` | scheduled-date truth + audit collapse + state retention | MATCH | Gate C |
| 27 | `notifications` | cadence/bundle/echo fences | MATCH | Gate C safe evidence |
| 28 | `line_reference` | six fixed entries + PWA deep links | MATCH | Gate C; no provider mutation |
| 29 | `test_mode` | simulated identity + side-effect fences | MATCH | Gate C |
| 30 | `delete_semantics` | cancel/failed/not-needed/reschedule/correction distinctions | MATCH | Gate C |
| 31 | `settings` | operational links incl. LINE/outcomes/anyone-owner | MATCH | Gate C |
| 32 | `states` | input preservation already exists on Concierge entry; `ConciergeConfirmPage` now preserves successful results and retries failed candidates only (`failedCandidateIds` regression). Remaining Request surface still needs consistent load retry/return-state treatment. | PARTIAL | Requests retry + stale/return-state closeout |
| 33 | `non_ui_contract` | canonical Edge/DB/real-stack suites and safety fences | MATCH | Must remain full green |
| 34 | `coverage` | durable 34-row matrix maintained here | MISSING | exact final SHA, Gate C artifact/evidence, full CI GREEN, zero partial/missing |

## Gate tracking

- **Gate A — deterministic source/test:** in progress. CI #694 had Web/DB/Edge GREEN and real Supabase CLI RED solely because `20260907000002` was duplicated. The Issue #54 migration has now been renumbered to unique `20260907000003`; next CI must prove the full real-stack path.
- **Gate B — literal 34-screen conformance:** **30 MATCH / 3 PARTIAL / 1 MISSING**.
- **Gate C — real-use iPhone-equivalent scenario evidence:** pending final safe scenario harness/evidence. Route existence alone is not accepted.
- **Gate D — independent source review:** not started; PR remains Draft.

## Closeout rules

1. Every PARTIAL/MISSING row is a release failure and must be remediated in PR #56.
2. Changed deterministic behavior receives regression evidence.
3. Gate C exercises entry → operation → result → canonical truth → Back/state at iPhone-equivalent viewport without real LINE/Google provider mutation.
4. Final closeout records exact remediation SHA(s), exact tests, Gate C evidence, full CI GREEN and **MATCH 34 / PARTIAL 0 / MISSING 0**.
5. No main merge, production deployment, production Supabase mutation, real LINE send/provider mutation, Google provider mutation, or non-main Vercel Preview before independent Gate D GO.
