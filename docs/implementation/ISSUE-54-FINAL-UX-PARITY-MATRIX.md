# Issue #54 — Final UX Contract → Production Parity Matrix

Status: implementation closeout complete for pre-review. `MATCH` requires CURRENT source + deterministic regression; release approval additionally requires independent Gate D review.

## Authority and exact contract

- Working branch: `impl/issue-54-final-ux-parity`
- Product authority: `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md` → Appendix A Q1–Q112 → `docs/design/current/` → Accepted ADRs → CURRENT source/schema.
- UI contract: `family-ops-ux-contract-final-v11-noscript.html`
- SHA-256: `c1afa191a8e02f86683e886e0c59a60019b7388531dde19f96de690e8b9e2007`
- Final implementation head with full CI proof: `dbcb08ef822158b65bd5698babc79dd8e3101588`.
- Gate C evidence artifact: `docs/implementation/ISSUE-54-GATE-C-EVIDENCE.md` (added at `c15a8bbedbe45bf268af6937566a6ac98298338a`).
- Current matrix: **MATCH 34 / PARTIAL 0 / MISSING 0**.
- Unweighted progress: **100.0%** (`MATCH / 34`).
- Weighted progress: **100.0%** (`(MATCH + 0.5 × PARTIAL) / 34`).

| # | Contract item | CURRENT deterministic evidence | Status | Remaining |
|---:|---|---|---|---|
| 1 | `today` | `TodayContractPage.tsx`, Today canonical components/tests | MATCH | Gate D only |
| 2 | `checkin` | `CheckinPage.tsx`; unique migration `20260907000003_issue54_checkin_bulk_scope_read.sql`; SQL 80 | MATCH | Gate D only |
| 3 | `individual` | Check-in seven outcomes + LINE/PWA reference regressions | MATCH | Gate D only |
| 4 | `actual_add` | atomic `record-unplanned-actual`; SQL 79 | MATCH | Gate D only |
| 5 | `task_form` | three-step modal + session draft regression | MATCH | Gate D only |
| 6 | `task_detail` | canonical item/detail/edit + return-state regression | MATCH | Gate D only |
| 7 | `groups` | built-in/custom separation + bulk scope regressions | MATCH | Gate D only |
| 8 | `requests` | explicit `対応中 / 期限切れ / 履歴` buckets, URL bucket retention, scroll preservation after response refresh, received/sent separation; `Requests.contract.test.ts` | MATCH | Gate D only |
| 9 | `request_form` | distinct reply/work deadlines, literal explanation/preview, canonical `request_attempts.reply_due_at` via `server_tx_send_request_v2`, notification payload and Edge adapter | MATCH | Gate D only |
| 10 | `assignment` | explicit request-vs-agreed endpoint mapping | MATCH | Gate D only |
| 11 | `routine_rules` | period rules/override/conflict tests | MATCH | Gate D only |
| 12 | `handover` | canonical share/ack/correction/history | MATCH | Gate D only |
| 13 | `shopping` | state tabs + claim/release/takeover regressions | MATCH | Gate D only |
| 14 | `anyone_owner` | canonical anyone/unassigned/claim UI + tests | MATCH | Gate D only |
| 15 | `event` | event project/candidate confirmation flow | MATCH | Gate D only |
| 16 | `concierge` | text/suggestion shared proposal layer; no write before confirm | MATCH | Gate D only |
| 17 | `transcript` | `ja-JP` speech → editable transcript | MATCH | Gate D only |
| 18 | `results` | multi-intent selection/clarification/confirm/canonical commit | MATCH | Gate D only |
| 19 | `duplicate_review` | generic duplicate decision gate + dedicated Google/Nursery flows | MATCH | Gate D only |
| 20 | `nursery` | Q89–Q106 review/diff/provenance/isolation suites | MATCH | Gate D only |
| 21 | `google` | protected diff/duplicate triage/provider fences | MATCH | Gate D only |
| 22 | `conflict_review` | current value + candidates + explicit resolution | MATCH | Gate D only |
| 23 | `week` | future assignment/schedule/prep projection | MATCH | Gate D only |
| 24 | `month` | compact transport + selected-day agenda | MATCH | Gate D only |
| 25 | `dayagenda` | detail/edit and selected-date preservation | MATCH | Gate D only |
| 26 | `history` | scheduled-date truth + audit collapse + state retention | MATCH | Gate D only |
| 27 | `notifications` | cadence/bundle/echo fences | MATCH | Gate D only |
| 28 | `line_reference` | six fixed entries + PWA deep links; no provider mutation | MATCH | Gate D only |
| 29 | `test_mode` | simulated identity + side-effect fences | MATCH | Gate D only |
| 30 | `delete_semantics` | cancel/failed/not-needed/reschedule/correction distinctions | MATCH | Gate D only |
| 31 | `settings` | operational links incl. LINE/outcomes/anyone-owner | MATCH | Gate D only |
| 32 | `states` | Requests retry/loading/empty/stale/scroll; Concierge input preservation and failed-only retry | MATCH | Gate D only |
| 33 | `non_ui_contract` | canonical Edge/DB/real-stack suites and safety fences; CI #702 FULL GREEN at `dbcb08ef822158b65bd5698babc79dd8e3101588` | MATCH | Gate D only |
| 34 | `coverage` | exact contract SHA, exact implementation/CI SHA, Gate C evidence artifact, and full CI GREEN are durably recorded | MATCH | Gate D only |

## Gate tracking

- **Gate A — deterministic source/test: PASS.** CI #702 at exact implementation head `dbcb08ef822158b65bd5698babc79dd8e3101588` is FULL GREEN: Web lint/typecheck/test/build, Edge lint/typecheck/unit/auth-matrix, DB migrations/SQL suite, and real Supabase CLI integration all succeeded.
- **Gate B — literal 34-screen conformance: PASS.** **34 MATCH / 0 PARTIAL / 0 MISSING**.
- **Gate C — real-use iPhone-equivalent scenario evidence: PASS.** Durable evidence: `docs/implementation/ISSUE-54-GATE-C-EVIDENCE.md`, covering entry → operation → result → canonical truth → Back/state with mobile/iOS source evidence and no real LINE/Google provider mutation.
- **Gate D — independent source review: NOT STARTED.** PR remains Draft / open / unmerged. No main merge or production/provider mutation has occurred.

## Closeout rules

1. Any regression from MATCH reopens the relevant row and blocks release.
2. Gate D must independently review CURRENT PR #56 and the exact final source before any release action.
3. Production, production Supabase mutation, real LINE send/provider mutation, Google provider mutation, and main merge remain prohibited before independent review GO.
