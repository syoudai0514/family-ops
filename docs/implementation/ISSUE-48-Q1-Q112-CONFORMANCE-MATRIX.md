# Issue #48 — Q1–Q112 UX conformance matrix

## Durable handoff state

| Field | Value |
| --- | --- |
| Canonical Issue | [#48](https://github.com/syoudai0514/family-ops/issues/48) |
| CURRENT main read | `f85cbb0574731138db3972ec8ad093d86020fad4` (`2026-09-05`) |
| Working branch | `impl/issue-48-ux-closeout` |
| PR | [#50](https://github.com/syoudai0514/family-ops/pull/50) (Draft) |
| Exact head / CI | Review-remediation commits are `5577b5559a27bafabb4c0d427f06c32d6f660ef1` and `d7c9af2`; remote exact head/CI is recorded only after the PR branch update. |
| Scope boundary | Source implementation and review handoff only. No main merge, production change, real LINE test delivery, or provider mutation. |
| Assessed | **112/112** (no unassessed decisions) |
| Remaining gaps | Independent review H1–H5/M1–M5 are being re-verified on this branch. Physical iPhone capture remains intentionally gated pending a reviewed device/environment; no production mutation is authorized. |

## Status vocabulary

`PASS` = current source meets the decision. `UI_GAP` = command/domain support exists but the wife-facing path is absent or conflicts. `RUNTIME_GAP` = source lacks the required safe command/read behavior. `INTENTIONALLY_GATED` = accepted gate prevents activation and is explicitly fail-closed. `NOT_APPLICABLE` = no product surface is in scope for the current household/configuration.

All canonical anchors below are `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`, Appendix A, unless a more specific design source is named.

## Q1–Q112 assessment

| Q | Settled decision | Canonical source | CURRENT implementation evidence | Status | Remediation / test evidence |
| --- | --- | --- | --- | --- | --- |
| Q1 | Today is actively composed | Appendix A Q1; design/current/04 | `Today.tsx`, `get_my_daily_brief` | PASS | Daypart-priority sections + Today tests |
| Q2 | Request/change/share are separate | Q2; design/current/03 | `Requests`, assignment change, `Handovers` | PASS | Existing command tests |
| Q3 | Share can expire | Q3; design/current/03 | handover validity fields/read model | PASS | Handover tests |
| Q4 | LINE and PWA share business logic | Q4; design/current/04 | shared edge/RPC; legacy response wording | UI_GAP | Align entry/action labels; LINE contract tests |
| Q5 | Immediate and nightly actual input | Q5; design/current/04 | task complete + routine sessions | PASS | Reconciliation first layer |
| Q6 | Usually all self; enter exceptions | Q6; Q64 | routine reconciliation has `全部/大体/個別` | PASS | Group command preserves mostly-done evidence |
| Q7 | Actuals are household work, not micro-research | Q7 | task event model | PASS | Existing domain tests |
| Q8 | Off-plan work: shortcut + free text | Q8; Q74 | `QuickAdd`, task form | PASS | `QuickAdd.test.ts` |
| Q9 | Requests blend into Today; escalate only risk | Q9; Q23 | Today `まず確認` card precedes operational work | PASS | Today test / source evidence |
| Q10 | Role chores allow date/period override | Q10; Q50 | assignment change request commands | PASS | edge/SQL tests |
| Q11 | At home does not imply joint assignment | Q11 | assignee model is singular | PASS | schema/design evidence |
| Q12 | Weekday rules have validity period | Q12 | routine schedule rule support | PASS | `RoutineSchedule.test.ts` |
| Q13 | Show future owner; allow early execution | Q13 | week/month projections, task completion | PASS | planning tests |
| Q14 | No reminder only because early work possible | Q14 | notification policy | PASS | notification tests |
| Q15 | Partner early work shown only if load reduces | Q15 | DailyBrief summary policy | PASS | design/current/04 |
| Q16 | Share confirmation depends on importance | Q16; Q37 | `Handovers.tsx` displays required acknowledgement distinctly | UI_GAP | Creation-time importance selection remains to be verified against canonical create command |
| Q17 | Event template + AI candidate + human confirm | Q17 | candidate pipeline exists | INTENTIONALLY_GATED | adapter/P1 gate; no unsafe activation |
| Q18 | No event-wide coordinator | Q18 | event participant model | PASS | design evidence |
| Q19 | Event LINE only at milestones/risk | Q19 | notification outbox policy | PASS | LINE tests |
| Q20 | Latest state normal, history separate | Q20 | Today vs `HistoryPage` | PASS | history tests |
| Q21 | Start/estimate/due/reminder optional | Q21 | `TaskFormModal` optional fields | PASS | form tests |
| Q22 | Waiting + next check | Q22 | `TaskChecklistItem`, `set-task-waiting`, `shouldShowWaitingTask` | PASS | Optional next check; future wait suppression + overdue visibility regression |
| Q23 | Today hierarchy | Q23; design/current/04 | Today orders confirmation, waiting, exceptions, handover, work | PASS | Daypart ordering source evidence |
| Q24 | Daypart then must/normal/spare | Q24 | task kinds + evening morning-summary collapse | PASS | Today source evidence |
| Q25 | Push morning/night, exceptions anytime | Q25 | dispatch scheduling | PASS | notification fixtures |
| Q26 | Night fixed at 20:30 | Q26 | DailyBrief scheduler | PASS | scheduled tests |
| Q27 | One LINE conversation test mode | Q27; design/current/06 | synthetic LINE source + `test_delivery_outbox`, `TestSimulation.tsx` | PASS | one-user ActorRef isolation; no production notification/outbox/Google writes |
| Q28 | Analysis non-push and deep | Q28 | History is navigation surface | PASS | UI evidence |
| Q29 | Correct actuals, preserve history | Q29 | History reads active `task_actual_participants`, then sends whole selected set | PASS | multi-participant display/preservation regression |
| Q30 | Expired change fails; re-propose | Q30 | assignment request expiry command | PASS | edge/SQL tests |
| Q31 | Incomplete varies by task nature | Q31 | carryover/routine semantics | PASS | reconciliation tests |
| Q32 | Multiple actual people, simple normal UI | Q32 | actual participant data/actor selector | PASS | domain/read-model tests |
| Q33 | Shopping actual is one action, not item count | Q33 | Shopping transitions | PASS | shopping action tests |
| Q34 | Google is schedule-first | Q34 | calendar projection/ownership | PASS | provider tests |
| Q35 | Own work primary, partner summary | Q35 | own next task + partner critical summary | PASS | Today source evidence |
| Q36 | Accepted request becomes linked ToDo | Q36 | accept request command | PASS | request command tests |
| Q37 | Only action-required handover asks confirmation | Q37 | important handover acknowledgement copy/action | UI_GAP | New important-handover authoring contract remains unverified |
| Q38 | Share household default | Q38 | create handover default | PASS | edge tests |
| Q39 | New request/share normally immediate | Q39 | outbox/reply pipeline | PASS | LINE tests |
| Q40 | Partner completion summarized, not every ping | Q40 | DailyBrief policy | PASS | notification tests |
| Q41 | Use `難しい`; commented decline one final notice | Q41 | `negotiate-request` + `CommentedDecline` | PASS | comment is recorded against canonical attempt; stale revision fails closed |
| Q42 | Light request ends difficult; necessary stays unresolved | Q42 | request authority semantics | PASS | request tests |
| Q43 | Checking vs consultation semantics | Q43 | request-attempt reader + negotiate adapter + visible conditions/confirmation state | PASS | one confirmation remains awaiting-confirmation; canonical second confirmation accepts |
| Q44 | First tier: do/difficult/other | Q44 | PWA three choices; LINE Flex deep-links other response | PASS | shared response wording/URI contract |
| Q45 | Change request, not overwrite | Q45 | assignment change request | PASS | mutation tests |
| Q46 | Accepted cancellation needs counterpart confirm | Q46 | accepted request followup UI invokes canonical counterpart-confirm command | PASS | `start-request-followup` UI + edge |
| Q47 | Reply and work deadlines differ | Q47 | request form labels work deadline; followup labels reply deadline | PASS | Requests UI source evidence |
| Q48 | Share expiry separate from related Todo | Q48 | handover validity fields | PASS | schema/read tests |
| Q49 | Corrections retain old information | Q49 | append-only task events | PASS | audit evidence |
| Q50 | Recalculate rules only; preserve individual agreement | Q50 | routine schedule/assignment commands | PASS | rule tests |
| Q51 | Review conflict keeps original agreement | Q51 | assignment negotiation state | PASS | state machine tests |
| Q52 | AI scope inference shown before confirmation | Q52 | pending-action confirmation flow | PASS | pending action tests |
| Q53 | Skip applies only once | Q53 | task skip semantic | PASS | command tests |
| Q54 | Partial progress via status/subitems | Q54 | `TaskChecklistItem` | PASS | component tests |
| Q55 | Only explicit tomorrow wording reschedules | Q55 | task parser/command policy | PASS | parser tests |
| Q56 | Standard duration optional; no real-time entry | Q56 | task form/event model | PASS | form/model evidence |
| Q57 | Importance auto inference, change only if needed | Q57 | priority policy | PASS | design/current/03 |
| Q58 | Complex dependencies deferred | Q58 | no dependency UI/schema | INTENTIONALLY_GATED | accepted deferral |
| Q59 | Bulk complete then correction/undo | Q59 | History correction preserves audit rather than overwriting result | PASS | correction UI / canonical audit command |
| Q60 | Auto + custom groups | Q60 | routine/task grouping foundation | PASS | routine UI/model |
| Q60-1 | Daily group is display box; event is container | Q60-1 | task/routine distinction | PASS | design/current/03 |
| Q60-2 | Bulk only meaningful groups | Q60-2 | routine sessions | PASS | routine command tests |
| Q61 | Bulk excludes spare-capacity items | Q61 | eligible routine set | PASS | reconciliation test |
| Q62 | No user time management for actual | Q62 | completion timestamps audit-only | PASS | command/model |
| Q63 | Late entry keeps original task date | Q63 | task instance scheduled date | PASS | history tests |
| Q64 | All/mostly/individual reconciliation semantics | Q64 | `CheckinPage` + canonical reconcile adapter | PASS | mostly-done never completes children |
| Q65 | Individual via LINE/PWA | Q65 | PWA checkin uses shared canonical item command; LINE links same state | PASS | common mutation contract |
| Q66 | LINE exceptions-first, one-by-one optional | Q66 | routine LINE flow | PASS | `routineItemFlow.test.ts` |
| Q67 | LINE lists all own tasks clearly | Q67 | routine LINE builder | PASS | LINE builder tests |
| Q68 | Partner summarized; only critical detail | Q68 | Today partner critical summary | PASS | Today source evidence |
| Q69 | Unassigned can be registered | Q69 | task form nullable assignee | PASS | form/edge tests |
| Q70 | Multiple message intents, one confirmation | Q70 | parser/pending action pipeline | PASS | parser tests |
| Q71 | Ask only ambiguous parts | Q71 | clarification workflow | PASS | LINE conversation tests |
| Q72 | Learn household terms, never auto-change rule | Q72 | AI boundaries | PASS | accepted design |
| Q73 | Fixed menu items | Q73 | LINE menu builder | PASS | LINE builder tests |
| Q74 | Add is free-text-led + shortcuts | Q74 | `QuickAdd` | PASS | `QuickAdd.test.ts` |
| Q75 | Today recomputes by current time | Q75 | `localDaypart` + evening collapse | PASS | Today source evidence |
| Q76 | Input opens most natural current target | Q76 | Today current input card and LINE deep-link share CheckinPage | PASS | current routine-session read adapter |
| Q77 | Other contains management/list/settings | Q77 | App shell/settings | PASS | routing evidence |
| Q78 | LINE→PWA deep link restores target/state | Q78 | `/checkin/:sessionId` + stale route | PASS | checkin/LINE tests |
| Q79 | PWA done does not self-LINE echo | Q79 | edge notification policy | PASS | outbox tests |
| Q80 | One operation → one consolidated notification | Q80 | operation receipt/outbox | PASS | LINE quota/retry tests |
| Q81 | Detect duplicates, do not auto merge | Q81 | duplicate-aware commands | PASS | DB tests |
| Q82 | Delete only registration error; preserve outcomes | Q82 | terminal states/events | PASS | command tests |
| Q83 | Ask whether assignment was pre-agreed | Q83 | Week assignment form provides `調整済み` choice | PASS | direct canonical assignment adapter |
| Q84 | Externally agreed: audit + neutral correction | Q84 | canonical assignment command emits audit + neutral notification | PASS | `change-task-assignment` edge / Week UI |
| Q85 | Important pre-agreed changes immediate; minor digest | Q85 | `fn_assignment_change_delivery_urgency_v1` before-insert policy | PASS | transport/safety/near-term immediate; ordinary chore digest |
| Q86 | Timing auto by kind/date/impact | Q86 | same canonical outbox policy | PASS | policy preserves notification bridge quota/retry/bundle behavior |
| Q87 | Night collapses morning completed work | Q87 | static long Today sections | UI_GAP | night compact summary |
| Q88 | Morning schedule weekday 06:30/nonwork 09:00 | Q88 | DailyBrief config | PASS | scheduler fixtures |
| Q89 | Nursery image → candidates + confirm | Q89 | external adapter absent | INTENTIONALLY_GATED | DD9/P1 gate |
| Q90 | Infer school/child/class, ask ambiguity only | Q90 | adapter absent | INTENTIONALLY_GATED | DD9/P1 gate |
| Q91 | Learn confirmed school prep rules | Q91 | adapter absent | INTENTIONALLY_GATED | DD9/P1 gate |
| Q92 | Keep source image, later image-only cleanup | Q92 | adapter absent | INTENTIONALLY_GATED | DD9/P1 gate |
| Q93 | Do not ingest other child/class data | Q93 | adapter validation foundation | INTENTIONALLY_GATED | DD9/P1 gate |
| Q94 | Later notice makes update candidates | Q94 | adapter absent | INTENTIONALLY_GATED | DD9/P1 gate |
| Q95 | Human-confirmed conflict shows diff | Q95 | candidate contract | INTENTIONALLY_GATED | DD9/P1 gate |
| Q96 | LINE image quick triage | Q96 | adapter absent | INTENTIONALLY_GATED | DD9/P1 gate |
| Q97 | Separate stated fact from AI inference | Q97 | source-review hardening | PASS | DB validation tests |
| Q98 | Group sequential images as document | Q98 | adapter absent | INTENTIONALLY_GATED | DD9/P1 gate |
| Q99 | One-screen editable candidate review | Q99 | adapter absent | INTENTIONALLY_GATED | DD9/P1 gate |
| Q100 | Both can view source from family detail, no LINE resend | Q100 | storage/read gate | INTENTIONALLY_GATED | DD9/P1 gate |
| Q101 | Monthly recommends high-impact schedules | Q101 | Month/Week projection | PASS | planning tests |
| Q102 | Image recurring rule candidate with duration | Q102 | adapter absent | INTENTIONALLY_GATED | DD9/P1 gate |
| Q103 | One occurrence cancel/change is exception | Q103 | schedule exception semantics | PASS | routine schedule tests |
| Q104 | Submission is due Todo, calendar optional | Q104 | task/calendar separation | PASS | model evidence |
| Q105 | URL/QR/destination link on Todo | Q105 | task URL field | PASS | task form/edge test |
| Q106 | Completion attachment optional; normal 1 tap | Q106 | complete task + optional evidence model | PASS | command tests |
| Q107 | Anyone is formal owner kind | Q107 | shopping `assignment_mode=anyone` | PASS | shopping tests |
| Q108 | Anyone claims before doing; takeover only when needed | Q108 | shopping claim state machine | PASS | `shoppingActions.test.ts` |
| Q109 | Claimant can release; no expiry release | Q109 | claim/release action | PASS | shopping command tests |
| Q110 | Google time change updates event; prep is candidate | Q110 | calendar ingestion/outbox | PASS | provider ownership tests |
| Q111 | Google deletion asks correct outcome | Q111 | conditional delete workflow | PASS | Google delete tests |
| Q112 | Google duplicate asks link vs add | Q112 | duplicate candidate contract | PASS | calendar tests |

## Implementation closeout log

Update this section with each coherent commit and the final exact PR head. A reviewer must be able to resume from this file without chat history.

| Commit | Scope | Verification | Remaining scope |
| --- | --- | --- | --- |
| `abb7067` | Matrix created before behavior changes | 112/112 assessed | UX implementation |
| `6939da1` / PR #50 initial `10cf5b6` | Today/check-in/request/waiting/history canonical adapters and mobile UI | auth-matrix lint + diff check PASS; CI #437 running | Shopping simplification, already-agreed correction surface, production/device evidence |
| `90289b4` | Wife guide, playbook and PDF screenshot checklist | documentation synchronized to source UI | independent review / reviewed production capture |
| `4777619` / remote `5d78fee` | Shopping primary-action simplification; generic tomorrow preparation with added-state/duplicate block | Full CI #440 green | final request/LINE changes |
| `c748e51` / remote `85e897e` | `調整済み` direct assignment path | Full CI #441 green | final request/LINE changes |
| `25c9aba` / remote `c6bfde4` | Accepted request change/cancel proposal UI | Full CI #442 green | LINE other-response final head |
| `c1f4c51` / remote `edf10de` | LINE other-response → restored PWA branch | auth-matrix + diff check local; final CI pending | remaining explicit gaps + device capture |

## Required final evidence

- Q1–Q112 reassessed after implementation; `UI_GAP`/`RUNTIME_GAP` must be resolved or justified as an accepted gate.
- Web lint, typecheck, unit/component tests, production build; affected Edge/DB suites.
- iPhone viewport evidence at 375×667 and 393×852 for Issue #48 flows.
- PR number, exact head, CI run URLs/statuses, user-guide screenshot checklist, and intentionally gated items recorded here and in Issue #48.
