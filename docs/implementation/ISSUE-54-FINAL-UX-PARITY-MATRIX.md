# Issue #54 — Final UX Contract → Production Parity Matrix

Status: **independent review NO-GO remediation complete at source/test level; real-iPhone Gate C remains open**. `MATCH` requires CURRENT source + deterministic regression. Release approval additionally requires real-iPhone Gate C evidence and independent Gate D GO.

## Authority and exact contract

- Working branch: `impl/issue-54-final-ux-parity`
- Product authority: `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md` → Appendix A Q1–Q112 → `docs/design/current/` → Accepted ADRs → CURRENT source/schema.
- UI contract: `family-ops-ux-contract-final-v11-noscript.html`
- SHA-256: `c1afa191a8e02f86683e886e0c59a60019b7388531dde19f96de690e8b9e2007`
- Independently reviewed head: `2f37e257b15f077940de27ef3821d7a4097b2e54`.
- Independent verdict at that head: **NO-GO — BLOCKER 0 / HIGH 3 / MEDIUM 2 / LOW 0**.
- Independent source parity at that head: **MATCH 28 / PARTIAL 6 / MISSING 0**.
- Remediation implementation head: `8b66598cd942cb4cdc5dfcd2eb7624e46b8bf51f`.
- Remediation CI: **#719 / run 34087110663 — Web, Edge, DB, real Supabase CLI all SUCCESS**.
- Gate C evidence artifact: `docs/implementation/ISSUE-54-GATE-C-EVIDENCE.md` — **FAIL / real iPhone pending**.

## Current parity accounting

The five source findings have deterministic remediation and full exact-head CI. Coverage remains PARTIAL because physical Gate C has not been executed.

- Current matrix: **MATCH 33 / PARTIAL 1 / MISSING 0**.
- Unweighted strict progress: **97.1%** (`MATCH / 34`).
- Weighted progress: **98.5%** (`(MATCH + 0.5 × PARTIAL) / 34`).

| # | Contract item | CURRENT deterministic evidence / remediation | Status | Remaining |
|---:|---|---|---|---|
| 1 | `today` | Literal v11 first-viewport copy `最初にここだけ見ればOK` plus `返事・担当未定`, `今日の自分タスク`, `待ち・あとで確認`, `明日の予定・準備`; targeted Web regression GREEN in CI #719. | MATCH | real iPhone Gate C + re-review |
| 2 | `checkin` | Concrete included/excluded item names immediately above `全部やった`; regression locks `洗濯：畳む`, `明日の着替え準備`, excluded `フィルター掃除`; Web regression GREEN in CI #719. | MATCH | real iPhone Gate C + re-review |
| 3 | `individual` | Check-in seven outcomes + LINE/PWA reference regressions | MATCH | Gate C/re-review only |
| 4 | `actual_add` | atomic `record-unplanned-actual`; SQL 79 | MATCH | Gate C/re-review only |
| 5 | `task_form` | three-step modal + session draft regression | MATCH | Gate C/re-review only |
| 6 | `task_detail` | canonical item/detail/edit + return-state regression | MATCH | Gate C/re-review only |
| 7 | `groups` | built-in/custom separation + bulk scope regressions | MATCH | Gate C/re-review only |
| 8 | `requests` | explicit `対応中 / 期限切れ / 履歴` buckets, URL bucket retention, scroll preservation, received/sent separation | MATCH | Gate C/re-review only |
| 9 | `request_form` | distinct reply/work deadlines and canonical `request_attempts.reply_due_at` | MATCH | Gate C/re-review only |
| 10 | `assignment` | explicit request-vs-agreed endpoint mapping | MATCH | Gate C/re-review only |
| 11 | `routine_rules` | period rules/override/conflict tests | MATCH | Gate C/re-review only |
| 12 | `handover` | canonical share/ack/correction/history | MATCH | Gate C/re-review only |
| 13 | `shopping` | state tabs + claim/release/takeover regressions | MATCH | Gate C/re-review only |
| 14 | `anyone_owner` | canonical anyone/unassigned/claim UI + tests | MATCH | Gate C/re-review only |
| 15 | `event` | event project/candidate confirmation flow | MATCH | Gate C/re-review only |
| 16 | `concierge` | PWA proposal endpoint now uses existing Gemini-backed AI-first `extractLineIntent()` with deterministic fallback. Explicit correction clauses update the preceding candidate. Unicode ellipsis boundary regression and exact approved scenario pass in Edge tests. | MATCH | real iPhone correction scenario + re-review |
| 17 | `transcript` | Editable `ja-JP` transcript feeds the same AI-first/correction-aware proposal path; Web/Edge full CI GREEN. | MATCH | real iPhone dictation scenario + re-review |
| 18 | `results` | Per-candidate `編集` supports title/date save before confirmation. Corrected request date is preserved through the CURRENT `send-request` canonical payload; Web tests GREEN. | MATCH | real iPhone edit scenario + re-review |
| 19 | `duplicate_review` | generic duplicate decision gate + dedicated Google/Nursery flows | MATCH | Gate C/re-review only |
| 20 | `nursery` | Q89–Q106 review/diff/provenance/isolation suites | MATCH | Gate C/re-review only |
| 21 | `google` | protected diff/duplicate triage/provider fences | MATCH | Gate C safe evidence/re-review only |
| 22 | `conflict_review` | current value + candidates + explicit resolution | MATCH | Gate C/re-review only |
| 23 | `week` | future assignment/schedule/prep projection | MATCH | Gate C/re-review only |
| 24 | `month` | compact transport + selected-day agenda | MATCH | Gate C/re-review only |
| 25 | `dayagenda` | detail/edit and selected-date preservation | MATCH | Gate C/re-review only |
| 26 | `history` | scheduled-date truth + audit collapse + state retention | MATCH | Gate C/re-review only |
| 27 | `notifications` | cadence/bundle/echo fences | MATCH | Gate C safe evidence/re-review only |
| 28 | `line_reference` | six fixed entries + PWA deep links; no provider mutation | MATCH | Gate C/re-review only |
| 29 | `test_mode` | simulated identity + side-effect fences | MATCH | Gate C/re-review only |
| 30 | `delete_semantics` | cancel/failed/not-needed/reschedule/correction distinctions | MATCH | Gate C/re-review only |
| 31 | `settings` | operational links incl. LINE/outcomes/anyone-owner | MATCH | Gate C/re-review only |
| 32 | `states` | Requests retry/loading/empty/stale/scroll; Concierge input preservation and failed-only retry | MATCH | Gate C/re-review only |
| 33 | `non_ui_contract` | Q1–Q112 regression remained green; CI #719 is FULL GREEN across Web/Edge/DB/real Supabase CLI. | MATCH | re-review only |
| 34 | `coverage` | Exact remediation source/CI is now recorded and stale Gate C claims were withdrawn. Physical real-iPhone observations do not yet exist. | PARTIAL | real iPhone Gate C + exact observation record + re-review |

## Gate tracking

- **Gate A — PASS.** CI #719 / run `34087110663` at remediation implementation head `8b66598cd942cb4cdc5dfcd2eb7624e46b8bf51f` is FULL GREEN: Web, Edge (including approved correction regression), DB, and real Supabase CLI all SUCCESS.
- **Gate B — source parity remediation complete; release gate remains FAIL while row 34 is PARTIAL.** Current matrix **33 MATCH / 1 PARTIAL / 0 MISSING**.
- **Gate C — FAIL / NOT EXECUTED.** Issue #54 requires real iPhone user acceptance. CSS, jsdom/component tests, and CI are not substitutes. Required physical scenarios are in `ISSUE-54-GATE-C-EVIDENCE.md`.
- **Gate D — independent review remains NO-GO pending Gate C and targeted re-review.**

## Remediation completed

1. Today literal/material first-viewport labels restored.
2. Check-in concrete bulk target/exclusion names shown immediately before mutation.
3. Concierge PWA proposal switched to the existing Gemini-backed AI-first extractor with deterministic fallback.
4. `……あ、やっぱ土曜` correction semantics implemented, including Unicode normalization boundary handling; `牛乳も買って` remains a separate shopping intent.
5. Results candidate editing added before confirmation.
6. Corrected request date/assignee now reaches the CURRENT `send-request` canonical payload; stale legacy payload names removed.
7. Targeted regressions added for named Check-in scope, Today labels, approved Concierge correction, and canonical request commit.
8. Durable Gate C evidence corrected so it no longer overclaims equivalent-device PASS.

## Closeout rules

1. Row 34 cannot become MATCH until real-iPhone Gate C is physically executed and recorded against an exact PR head.
2. PR remains Draft while Gate C is FAIL and Gate D is NO-GO.
3. After physical Gate C, update the evidence/matrix to its exact tested head, run final CI, then request targeted independent re-review of the five findings plus exact-head regression.
4. Production, production Supabase mutation, real LINE send/provider mutation, Google provider mutation, Vercel non-main Preview, and main merge remain prohibited before independent review GO.
