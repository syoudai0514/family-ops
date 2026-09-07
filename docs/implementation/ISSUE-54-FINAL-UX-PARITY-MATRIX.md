# Issue #54 — Final UX Contract → Production Parity Matrix

Status: implementation closeout in progress. This is the durable 34-screen matrix for the user-approved final-v11 contract. `MATCH` means CURRENT source + deterministic regression materially implement the screen contract; it is not release approval until Gate C evidence and Gate D independent review are complete. `PARTIAL` and `MISSING` remain release failures.

## Authority and exact contract

- Working branch: `impl/issue-54-final-ux-parity`
- Product authority: `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md` → Appendix A Q1–Q112 → `docs/design/current/` → Accepted ADRs → CURRENT source/schema.
- UI/interaction concretization: `family-ops-ux-contract-final-v11-noscript.html`
- SHA-256: `c1afa191a8e02f86683e886e0c59a60019b7388531dde19f96de690e8b9e2007`
- Fixture chores/dates/owners are presentation fixtures only; none are production defaults/seeds.
- Current matrix after Issue #54 remediation in PR #56: **MATCH 21 / PARTIAL 12 / MISSING 1**.
- Unweighted progress: **61.8%** (`MATCH / 34`).
- Weighted progress: **79.4%** (`(MATCH + 0.5 × PARTIAL) / 34`; MISSING = 0 weight).

| # | Contract item | CURRENT source / deterministic evidence | Status | Remaining before release closeout |
|---:|---|---|---|---|
| 1 | `today` | `/today` now routes through `TodayContractPage.tsx`: first-viewport `要対応 / 残り / 待ち / 明日影響`, direct-jump/fallback behavior, light Concierge entry; canonical detailed truth remains `Today.tsx`/`TodayTaskItem`; parent/subtask progress and direct completion remain canonical. `TodayContractPage.test.tsx` + existing `Today*.test.tsx`. | MATCH | Gate C iPhone-equivalent evidence. |
| 2 | `checkin` | `CheckinPage.tsx`: exact target switcher (`今夜 / 朝の未入力 / 昨日分修正 / 予定外実績`), all/mostly/individual, immediate receipt-scoped correction/undo, direct subtask completion, and literal pre-mutation `必須/通常 N件 / 余力 M件は対象外`. `20260907000002_issue54_checkin_bulk_scope_read.sql` exposes canonical `task_instances.expectation`; canonical group reconciliation already excludes `optional`; `80_issue54_checkin_bulk_scope.sql` proves exact read/mutation parity and non-destructive `mostly_done`; `CheckinPage.test.ts` proves count/fallback semantics. | MATCH | Gate C iPhone-equivalent Check-in → canonical truth → Back/state evidence. |
| 3 | `individual` | `CheckinPage.tsx`: complete/partner/failed/not-needed/cancel/reschedule/unknown, direct subtask completion, `その他の結果`; SQL `76_issue48_q59_q64_literal_regression.sql` preserves seven distinct canonical outcomes across PWA/LINE sources. | PARTIAL | Add literal `回答する場所: PWA / LINE` reference/deep-link surface and Gate C. |
| 4 | `actual_add` | `/actuals/new` uses Concierge actual-only entry; `record-unplanned-actual` + `20260907000001_issue54_unplanned_actual_atomic.sql` creates canonical task/actual atomically with original `scheduled_date`, idempotent operation receipt and participant truth; SQL regression `79_issue54_unplanned_actual_atomic.sql`. | MATCH | Gate C actual-entry → canonical History truth. |
| 5 | `task_form` | `QuickAdd` → `TaskFormModal.tsx`; title-first canonical create/edit, assignment/date/detail/subtasks/calendar controls exist. | PARTIAL | Literal hierarchy + draft/back-state closeout evidence. |
| 6 | `task_detail` | `TodayTaskItem` / `TaskChecklistItem`: subtask progress/direct completion, waiting/result/assignment operations; edit uses canonical modal. | PARTIAL | Contract-equivalent origin return/state proof. |
| 7 | `groups` | Routine/category/custom routine settings and routine-session backend implement grouping semantics. | PARTIAL | Literal auto/custom group management + meaningful-scope bulk UI closeout. |
| 8 | `requests` | `/requests`, Today quick responses and canonical request state machine support received/sent actions, accept/decline/checking/consult. | PARTIAL | Expired/new-proposal/history layout + return-state audit. |
| 9 | `request_form` | `/requests` composer reuses canonical request commands and separates request semantics from task mutation. | PARTIAL | Response/work deadline and pre-send semantic explanation literal closeout. |
| 10 | `assignment` | Canonical task/request assignment commands cover self/request/anyone and reassignment semantics. | PARTIAL | Single contract-equivalent assignment decision surface/correction affordance. |
| 11 | `routine_rules` | `/settings/routines`, `TransportTemplateEditor`, `RoutineSchedule`, occurrence override; non-overlap period templates + future conflict behavior covered by tests. | MATCH | Gate C only. |
| 12 | `handover` | `/handovers`; share scope/expiry/related ToDo, acknowledge independent from completion, correction/history semantics. | MATCH | Gate C only. |
| 13 | `shopping` | `/shopping`; state tabs, anyone claim/release/takeover and shopping actual semantics; `shoppingActions.test.ts`. | MATCH | Gate C only. |
| 14 | `anyone_owner` | Canonical `anyone` state distinct from unassigned; claim/release/takeover implemented. | PARTIAL | Literal current-claimant/disclosure UI confirmation. |
| 15 | `event` | `/events/new` → `EventPlanPage`; project container/candidate confirmation flow + backend tests. | MATCH | Gate C only. |
| 16 | `concierge` | Quick Add first item `✨ おうちコンシェルジュ`, Today light entry, `/concierge`, free text + suggestions + shared semantic proposal layer; proposal is read-only until human confirmation. | MATCH | Gate C only. |
| 17 | `transcript` | `/concierge/transcript`; browser speech recognition `ja-JP`, editable transcript, same proposal layer as text. | MATCH | Gate C/WebKit evidence. |
| 18 | `results` | `/concierge/results` + `/concierge/confirm`: multi-intent candidates, selected confirmation, `ここだけ確認`, zero-write read-only path, explicit human confirm, per-candidate success/error/retry; canonical command mapping in `conciergeCommit.ts`. | MATCH | Gate C multi-intent confirmation evidence. |
| 19 | `duplicate_review` | Google/Nursery explicit duplicate decisions exist. | PARTIAL | Generic Concierge duplicate decision (`use existing / update / separate`) before generic candidate commit. |
| 20 | `nursery` | `/nursery/reviews[/:intakeId]`; Q89–Q106 review/diff/provenance/inference/isolation behavior with Web/Edge/DB tests. | MATCH | Gate C only. |
| 21 | `google` | `/planning/google-review`; event-centered diff/protected conflict/delete triage/duplicate link-add; provider-fence tests. | MATCH | Gate C safe evidence; real provider mutation prohibited. |
| 22 | `conflict_review` | Protected current value vs candidates/source, explicit human resolution and authority audit across Google/Nursery. | MATCH | Gate C only. |
| 23 | `week` | `/week`; future assignment/schedule/prep/advance projection. | MATCH | Gate C only. |
| 24 | `month` | `/month`; compact transport token and inline selected-date agenda; `MonthView.test.tsx`. | MATCH | Gate C only. |
| 25 | `dayagenda` | `DayAgendaSheet`; detail/edit from Month and retained selected-date flow. | MATCH | Gate C same-date/scroll evidence. |
| 26 | `history` | `/history`: visible actual truth is original `scheduled_date`; performer correction; `completed_at` only inside collapsed `監査情報`; filter/selected-row/scroll/back state retained. `HistoryPage.test.tsx`. | MATCH | Gate C correction → return-state evidence. |
| 27 | `notifications` | Notification policy/settings + outbox: weekday/weekend/night cadence, meaningful exceptions, bundle/echo fences. | MATCH | No real LINE send; Gate C safe UI evidence only. |
| 28 | `line_reference` | LINE webhook/interactive adapters reuse canonical commands/read models and side-effect fences. | PARTIAL | Literal fixed menu/deep-link/state cross-surface closeout. |
| 29 | `test_mode` | `/settings/test-simulation`; explicit simulated identity and provider/outbox side-effect fences; Web/Edge/DB tests. | MATCH | Gate C only. |
| 30 | `delete_semantics` | Canonical task/request/event commands preserve not-needed/cancelled/history semantics. | PARTIAL | Literal unified mistaken-existence vs outcome explanation/choice UI. |
| 31 | `settings` | `/settings`, terminology/routine/categories/notifications/test/calendar links; terminology independent from assignment rules. | MATCH | Gate C only. |
| 32 | `states` | Cross-cutting loading/error/empty/realtime/stale handling exists. | PARTIAL | Consistent retry + input-preservation + stale-diff behavior across remaining edited surfaces. |
| 33 | `non_ui_contract` | Q4/Q14/Q19/Q25/26/39/79/80/81/85/86/88/93/100 plus idempotency/CAS/isolation/provider/test fences are covered by canonical Edge/DB/real-stack suites. | MATCH | Must remain full green. |
| 34 | `coverage` | This durable 34-row matrix tracks CURRENT implementation and weighted/unweighted progress; exact remediation/evidence is appended as rows move to MATCH. | MISSING | Final exact remediation SHAs, Gate C artifact/evidence, full-CI run and zero PARTIAL/MISSING closeout. |

## Gate tracking

- **Gate A — deterministic source/test:** in progress. Pre-remediation head `bcf9d41c` is full green on CI #664; the new Check-in remediation head must also finish full green before Gate A is closed.
- **Gate B — literal 34-screen conformance:** 21 MATCH / 12 PARTIAL / 1 MISSING.
- **Gate C — real-use iPhone-equivalent scenario evidence:** pending final scenario harness/evidence. Route/component existence is not accepted as Gate C.
- **Gate D — independent source review:** not started; PR remains Draft until A–C satisfy the closeout condition.

## Closeout rules

1. Every `PARTIAL` / `MISSING` row must be remediated in this same PR; partial is never release PASS.
2. Deterministic behavior added/changed gets Web/Edge/DB regression evidence as appropriate.
3. Gate C must exercise actual entry → screen → operation → result → canonical truth → Back/state at iPhone viewport/equivalent.
4. Final closeout records exact remediation commit(s), exact tests, Gate C evidence, and **MATCH 34 / PARTIAL 0 / MISSING 0**.
5. No main merge, production deployment, production Supabase mutation, real LINE send/provider mutation, Google provider mutation, or non-main Vercel Preview occurs before independent Gate D GO.
