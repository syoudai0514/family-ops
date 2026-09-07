# Issue #54 — Final UX Contract → Production Parity Matrix

Status: **independent NO-GO remediation complete at source/test level; targeted independent source re-review is READY now. Real-iPhone Gate C remains a release-acceptance gate and is not a blocker to source re-review.** `MATCH` requires CURRENT source + deterministic regression. Release approval additionally requires real-iPhone Gate C evidence and independent Gate D GO.

## Authority and exact contract

- Working branch: `impl/issue-54-final-ux-parity`
- Product authority: `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md` → Appendix A Q1–Q112 → `docs/design/current/` → Accepted ADRs → CURRENT source/schema.
- UI contract: `family-ops-ux-contract-final-v11-noscript.html`
- SHA-256: `c1afa191a8e02f86683e886e0c59a60019b7388531dde19f96de690e8b9e2007`
- Independently reviewed head: `2f37e257b15f077940de27ef3821d7a4097b2e54`.
- Independent verdict at that head: **NO-GO — BLOCKER 0 / HIGH 3 / MEDIUM 2 / LOW 0**.
- Independent source parity at that head: **MATCH 28 / PARTIAL 6 / MISSING 0**.
- Remediation implementation head: `8b66598cd942cb4cdc5dfcd2eb7624e46b8bf51f`.
- Remediation implementation CI: **#719 / run 34087110663 — Web, Edge, DB, real Supabase CLI all SUCCESS**.
- Remediation source/docs verification head before this matrix-only update: `2e2782a27e6bf448b5d3c167a00754927e0ab008`.
- Verification CI: **#720 / run 34087306529 — Web, Edge, DB, real Supabase CLI all SUCCESS**.
- Gate C evidence artifact: `docs/implementation/ISSUE-54-GATE-C-EVIDENCE.md` — **real iPhone pending for release acceptance**.

## Current parity accounting

The five independent source findings have deterministic remediation and full exact-head CI. Coverage remains PARTIAL only because physical Gate C has not yet been executed.

- Current implementation-owner matrix: **MATCH 33 / PARTIAL 1 / MISSING 0**.
- Unweighted strict progress: **97.1%** (`MATCH / 34`).
- Weighted progress: **98.5%** (`(MATCH + 0.5 × PARTIAL) / 34`).
- Independent targeted source re-review may now evaluate whether rows 1/2/16/17/18 are correctly upgraded to MATCH. Gate C is intentionally deferred to release acceptance.

| # | Contract item | CURRENT deterministic evidence / remediation | Status | Remaining |
|---:|---|---|---|---|
| 1 | `today` | Literal v11 first-viewport copy `最初にここだけ見ればOK` plus `返事・担当未定`, `今日の自分タスク`, `待ち・あとで確認`, `明日の予定・準備`; targeted Web regression GREEN. | MATCH | targeted re-review; physical Gate C before release |
| 2 | `checkin` | Concrete included/excluded item names immediately above `全部やった`; regression locks `洗濯：畳む`, `明日の着替え準備`, excluded `フィルター掃除`; Web regression GREEN. | MATCH | targeted re-review; physical Gate C before release |
| 3 | `individual` | Check-in seven outcomes + LINE/PWA reference regressions | MATCH | release Gate C + re-review only |
| 4 | `actual_add` | atomic `record-unplanned-actual`; SQL 79 | MATCH | release Gate C + re-review only |
| 5 | `task_form` | three-step modal + session draft regression | MATCH | release Gate C + re-review only |
| 6 | `task_detail` | canonical item/detail/edit + return-state regression | MATCH | release Gate C + re-review only |
| 7 | `groups` | built-in/custom separation + bulk scope regressions | MATCH | release Gate C + re-review only |
| 8 | `requests` | explicit `対応中 / 期限切れ / 履歴` buckets, URL bucket retention, scroll preservation, received/sent separation | MATCH | release Gate C + re-review only |
| 9 | `request_form` | distinct reply/work deadlines and canonical `request_attempts.reply_due_at` | MATCH | release Gate C + re-review only |
| 10 | `assignment` | explicit request-vs-agreed endpoint mapping | MATCH | release Gate C + re-review only |
| 11 | `routine_rules` | period rules/override/conflict tests | MATCH | release Gate C + re-review only |
| 12 | `handover` | canonical share/ack/correction/history | MATCH | release Gate C + re-review only |
| 13 | `shopping` | state tabs + claim/release/takeover regressions | MATCH | release Gate C + re-review only |
| 14 | `anyone_owner` | canonical anyone/unassigned/claim UI + tests | MATCH | release Gate C + re-review only |
| 15 | `event` | event project/candidate confirmation flow | MATCH | release Gate C + re-review only |
| 16 | `concierge` | PWA proposal endpoint now uses existing Gemini-backed AI-first `extractLineIntent()` with deterministic fallback. Explicit correction clauses update the preceding candidate. Unicode ellipsis boundary regression and exact approved scenario pass in Edge tests. | MATCH | targeted re-review; physical Gate C before release |
| 17 | `transcript` | Editable `ja-JP` transcript feeds the same AI-first/correction-aware proposal path; Web/Edge full CI GREEN. | MATCH | targeted re-review; physical Gate C before release |
| 18 | `results` | Per-candidate `編集` supports title/date save before confirmation. Corrected request date is preserved through the CURRENT `send-request` canonical payload; Web tests GREEN. | MATCH | targeted re-review; physical Gate C before release |
| 19 | `duplicate_review` | generic duplicate decision gate + dedicated Google/Nursery flows | MATCH | release Gate C/re-review only |
| 20 | `nursery` | Q89–Q106 review/diff/provenance/isolation suites | MATCH | release Gate C/re-review only |
| 21 | `google` | protected diff/duplicate triage/provider fences | MATCH | safe release Gate C/re-review only |
| 22 | `conflict_review` | current value + candidates + explicit resolution | MATCH | release Gate C/re-review only |
| 23 | `week` | future assignment/schedule/prep projection | MATCH | release Gate C/re-review only |
| 24 | `month` | compact transport + selected-day agenda | MATCH | release Gate C/re-review only |
| 25 | `dayagenda` | detail/edit and selected-date preservation | MATCH | release Gate C/re-review only |
| 26 | `history` | scheduled-date truth + audit collapse + state retention | MATCH | release Gate C/re-review only |
| 27 | `notifications` | cadence/bundle/echo fences | MATCH | safe release Gate C/re-review only |
| 28 | `line_reference` | six fixed entries + PWA deep links; no provider mutation | MATCH | release Gate C/re-review only |
| 29 | `test_mode` | simulated identity + side-effect fences | MATCH | release Gate C/re-review only |
| 30 | `delete_semantics` | cancel/failed/not-needed/reschedule/correction distinctions | MATCH | release Gate C/re-review only |
| 31 | `settings` | operational links incl. LINE/outcomes/anyone-owner | MATCH | release Gate C/re-review only |
| 32 | `states` | Requests retry/loading/empty/stale/scroll; Concierge input preservation and failed-only retry | MATCH | release Gate C/re-review only |
| 33 | `non_ui_contract` | Q1–Q112 regression remained green; CI #719 and #720 are FULL GREEN across Web/Edge/DB/real Supabase CLI. | MATCH | targeted re-review only |
| 34 | `coverage` | Exact remediation source/CI is recorded and stale Gate C claims were withdrawn. Physical real-iPhone observations do not yet exist. | PARTIAL | real iPhone Gate C + exact observation record before release |

## Gate tracking

- **Gate A — PASS.** CI #719 at remediation implementation head and CI #720 at the remediation verification head are FULL GREEN: Web, Edge, DB, and real Supabase CLI all SUCCESS.
- **Gate B — implementation-owner source parity remediation complete; targeted independent source re-review READY.** Current owner accounting is **33 MATCH / 1 PARTIAL / 0 MISSING**; the single PARTIAL is release coverage only.
- **Gate C — PENDING FOR RELEASE / NOT EXECUTED.** Issue #54 requires real iPhone user acceptance. CSS, jsdom/component tests, and CI are not substitutes. This does **not** block targeted independent source re-review; it blocks release/merge approval.
- **Gate D — previous verdict NO-GO; targeted independent source re-review READY NOW.** Reviewer should re-check the five findings plus exact-head regression. A final release GO still requires physical Gate C.

## Remediation completed

1. Today literal/material first-viewport labels restored.
2. Check-in concrete bulk target/exclusion names shown immediately before mutation.
3. Concierge PWA proposal switched to the existing Gemini-backed AI-first extractor with deterministic fallback.
4. `……あ、やっぱ土曜` correction semantics implemented, including Unicode normalization boundary handling; `牛乳も買って` remains a separate shopping intent.
5. Results candidate editing added before confirmation.
6. Corrected request date/assignee now reaches the CURRENT `send-request` canonical payload; stale legacy payload names removed.
7. Targeted regressions added for named Check-in scope, Today labels, approved Concierge correction, and canonical request commit.
8. Durable Gate C evidence corrected so it no longer overclaims equivalent-device PASS.

## Review sequencing

1. **Now:** targeted independent source re-review of the five findings + exact-head regression may proceed.
2. If source re-review is GO, keep release blocked and perform physical real-iPhone Gate C at release acceptance.
3. After physical Gate C, update evidence/matrix to the exact tested head and obtain final release GO before merge/deploy.
4. Production, production Supabase mutation, real LINE send/provider mutation, Google provider mutation, Vercel non-main Preview, and main merge remain prohibited before final release GO.
