# Issue #54 — Final UX Contract → Production Parity Matrix

Status: **independent review NO-GO remediation in progress**. `MATCH` requires CURRENT source + deterministic regression. Release approval additionally requires real-iPhone Gate C evidence and independent Gate D GO.

## Authority and exact contract

- Working branch: `impl/issue-54-final-ux-parity`
- Product authority: `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md` → Appendix A Q1–Q112 → `docs/design/current/` → Accepted ADRs → CURRENT source/schema.
- UI contract: `family-ops-ux-contract-final-v11-noscript.html`
- SHA-256: `c1afa191a8e02f86683e886e0c59a60019b7388531dde19f96de690e8b9e2007`
- Independently reviewed head: `2f37e257b15f077940de27ef3821d7a4097b2e54`.
- Independent verdict at that head: **NO-GO — BLOCKER 0 / HIGH 3 / MEDIUM 2 / LOW 0**.
- Independent source parity at that head: **MATCH 28 / PARTIAL 6 / MISSING 0**.
- Remediation source is now ahead of the reviewed head; targeted CI/re-review is required before upgrading the six PARTIAL rows.
- Gate C evidence artifact: `docs/implementation/ISSUE-54-GATE-C-EVIDENCE.md` — corrected to **FAIL / real iPhone pending**.

## Current parity accounting

Until remediation CI and re-review are complete, the independent verdict remains authoritative:

- Current matrix: **MATCH 28 / PARTIAL 6 / MISSING 0**.
- Unweighted strict progress: **82.4%** (`MATCH / 34`).
- Weighted progress: **91.2%** (`(MATCH + 0.5 × PARTIAL) / 34`).

| # | Contract item | CURRENT deterministic evidence / remediation | Status | Remaining |
|---:|---|---|---|---|
| 1 | `today` | Remediation adds literal v11 first-viewport copy `最初にここだけ見ればOK` plus meaning labels `返事・担当未定`, `今日の自分タスク`, `待ち・あとで確認`, `明日の予定・準備`. | PARTIAL | targeted CI + re-review + real iPhone Gate C |
| 2 | `checkin` | Remediation adds concrete included/excluded item names immediately above `全部やった`; helper/test uses `洗濯：畳む`, `明日の着替え準備`, `フィルター掃除`. | PARTIAL | targeted CI + re-review + real iPhone Gate C |
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
| 16 | `concierge` | Remediation switches PWA proposal endpoint from deterministic-only to shared AI-first `extractLineIntent()` path with deterministic fallback; explicit correction clauses update the preceding candidate. | PARTIAL | targeted Edge CI + re-review + real iPhone correction scenario |
| 17 | `transcript` | Existing editable `ja-JP` transcript now feeds the remediated AI-first/correction-aware proposal path. | PARTIAL | targeted Web/Edge CI + real iPhone dictation scenario + re-review |
| 18 | `results` | Remediation adds candidate `編集` with title/date save before confirmation, while retaining selection/ambiguity flow. | PARTIAL | targeted Web CI + real iPhone edit scenario + re-review |
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
| 33 | `non_ui_contract` | independent review confirmed Q1–Q112 regression PASS at reviewed head; CI #704 FULL GREEN | MATCH | remediation exact-head CI must remain GREEN |
| 34 | `coverage` | Previous artifact incorrectly claimed equivalent Gate C and stale exact heads. Gate C artifact has been corrected; exact remediation head/CI and real-iPhone observations are not yet complete. | PARTIAL | final exact head + full CI + real iPhone Gate C + re-review |

## Gate tracking

- **Gate A — deterministic source/test: PASS at reviewed head; remediation exact-head CI pending.** CI #704 at `2f37e257...` was FULL GREEN. New remediation must repeat full CI.
- **Gate B — literal 34-screen conformance: FAIL under independent review.** Authoritative reviewed accounting remains **28 MATCH / 6 PARTIAL / 0 MISSING** until remediation CI + re-review.
- **Gate C — real iPhone user acceptance: FAIL / NOT EXECUTED.** CSS, jsdom/component tests, and CI are not substitutes. Physical iPhone scenarios are listed in `ISSUE-54-GATE-C-EVIDENCE.md`.
- **Gate D — independent review: NO-GO.** Re-review is limited to the five findings plus exact-head regression once remediation is complete.

## Current remediation commits

The branch now contains remediation for:

1. Today literal/material first-viewport labels.
2. Check-in concrete bulk target/exclusion names immediately before mutation.
3. Concierge AI-first proposal path using the existing Gemini-backed extractor.
4. Explicit correction semantics for `……あ、やっぱ土曜` and separate `牛乳も買って` intent.
5. Results candidate editing before confirmation.
6. Targeted regression tests for named Check-in scope and the approved correction scenario.
7. Corrected Gate C evidence semantics.

## Closeout rules

1. No PARTIAL row may be treated as release-ready.
2. Do not upgrade rows 1/2/16/17/18 until remediation exact-head deterministic CI is GREEN; re-review remains required for Gate D.
3. Row 34 cannot become MATCH until real-iPhone Gate C is actually executed and exact-head evidence is recorded.
4. Production, production Supabase mutation, real LINE send/provider mutation, Google provider mutation, Vercel non-main Preview, and main merge remain prohibited before independent review GO.
