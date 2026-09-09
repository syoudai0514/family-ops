# 10. LINE / PWA Scenario Responsibility Matrix

- **Status:** PROPOSED / REVIEW-READY — product-owner final approval required before treating this matrix as an accepted product-governance decision
- **Scope:** CF-09 only; channel responsibility, not application implementation
- **Requirements authority:** `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`
- **Governance:** ADR 0012; this document is subordinate to the Requirements Baseline
- **UX realization reference:** `11_APPROVED_FINAL_UX_CANONICALIZATION.md`
- **Shared detailed design:** `04_LINE_PWA_DAILY_UX_AND_NOTIFICATIONS.md`

## 1. Purpose

The Requirements Baseline already fixes the product direction:

- LINE is the daily operational primary surface.
- PWA is the richer surface for detail, bulk work, settings, history, and event/calendar management.
- LINE and PWA are not separate products.
- A channel must not create a second parser, command model, state machine, completion truth, assignment truth, or provider-write truth.

This matrix makes that existing direction explicit at **material user-scenario level**. It does not invent a new flow and it does not authorize channel-specific business semantics.

The proposed Baseline v1.2 §2.1 product-outcome rule applies across this matrix: channel classification exists to improve actual family operation, not to make implementation easier. A technically convenient hand-off that makes a normal family flow slower, harder to understand, or dependent on PWA contrary to approved UX is a regression, not a valid implementation of this matrix.

## 2. Responsibility labels

### `LINE MUST complete`

The normal material scenario must be completable in LINE without forcing the user to open PWA. PWA may also expose the same underlying command/state, but PWA cannot be required to finish the normal LINE flow.

### `PWA MAY hand off`

LINE may surface, initiate, or collect state for the scenario, but may deep-link to the **concrete PWA target** when richer review/editing is appropriate. The hand-off must preserve the exact household/entity/attempt/candidate/context and must reuse the same canonical command semantics. It must not dump the user at a generic PWA home screen.

`MAY hand off` does not mean “LINE implementation may be omitted.” Where the row or its authority preserves a valid LINE path, that path remains required. PWA is used because richer review genuinely helps the user, not because the LINE implementation is unfinished or technically inconvenient.

### `PWA ONLY`

The material management/detail scenario belongs to PWA. LINE may show a summary, warning, notification, or deep link, but does not need a duplicate full editing UI. `PWA ONLY` is a **surface responsibility**, never permission for PWA-only business truth.

A scenario must not drift into `PWA ONLY` merely because a current implementation does not yet support its approved LINE responsibility. Reclassification is a product-governance change and requires explicit review against the Requirements Baseline and approved UX.

## 3. Cross-channel invariant — applies to every row

1. Canonical business state is shared across LINE and PWA.
2. The same operation is idempotent across duplicate LINE delivery, stale postback, PWA retry, and LINE/PWA concurrent use.
3. Request is agreement truth until acceptance; linked ToDo owns execution after acceptance.
4. Assignment, anyone-claim, actual performer, recorder, share acknowledgement, and source authority remain distinct dimensions regardless of channel.
5. LINE-to-PWA hand-off uses a concrete deep link and preserves entered state.
6. PWA save success stays in PWA; it does not self-echo a generic success message to the same user's LINE.
7. Current protected human values are not silently replaced by Google/image/AI candidates on either channel.
8. Channel implementation must preserve the approved normal-case UX. A finding fix, technical limitation, or architecture preference must not increase routine steps, notification noise, cognitive load, or PWA dependence unless the canonical product requirements are explicitly changed first.

Authority: Requirements Baseline §§2.1, 3, 7.6, 15, 23 and Appendix A Q4, Q36, Q78-Q79; `04_LINE_PWA_DAILY_UX_AND_NOTIFICATIONS.md`; approved final UX contract §§1-5, 7, 11, 13-16.

### 3.1 Real-use acceptance guard

Before any row is considered implemented, verify the relevant family flow end-to-end:

`Family Ops purpose → Requirement/Q → approved UX/current design → current implementation → test/evidence → real LINE/PWA use`

The result is **NO-GO** if the technical implementation matches a command/schema/test contract but the family experience regresses. In particular:

- a `LINE MUST complete` row cannot silently become “LINE starts, PWA finishes”;
- a `PWA MAY hand off` row cannot use PWA as a fallback for missing required LINE behavior;
- a `PWA ONLY` row cannot absorb an ordinary daily operation that the Baseline or approved UX keeps on LINE;
- a deep link cannot replace required LINE information by hiding it behind a count or generic destination;
- a channel split cannot create two business truths, two parsers, or inconsistent correction/history semantics.

## 4. Scenario matrix

| ID | Material user scenario | Responsibility | Channel contract | Existing authority |
|---|---|---|---|---|
| M01 | Open `今日` and understand what matters now: urgent actions, exceptions, active shares/handover, own work, partner summary, carryover/waiting, tomorrow impact | **LINE MUST complete** | LINE renders the latest shared Daily Brief at the time of access. Own same-day work is not hidden behind a PWA count. Morning/day/evening ordering follows current state/time. | Baseline §§3, 13.3-13.4, 14.3-14.4; Q1, Q23-Q25, Q35, Q67-Q68, Q75, Q87-Q88; final UX §§1-2, 11; design 04 §§2-7 |
| M02 | Free-text universal input / `追加`: add or describe schedule, ToDo, shopping, share, request, actual; one message may contain several intents | **LINE MUST complete** | Free text is primary. Known parts are kept, multiple intents are decomposed, and only ambiguous fields are asked. A normal supported input can be confirmed/registered from LINE. | Baseline §§13.1-13.2, 16.1-16.3; Q4, Q8, Q70-Q74; final UX §§10-11 |
| M03 | Create a simple ToDo / ad-hoc household work with only the information needed now | **LINE MUST complete** | Title-only ToDo remains valid. Optional detailed scheduling/importance/duration fields must not make routine creation leave LINE. | Baseline §§9.1, 16.4-16.5; Q8, Q21, Q56-Q57, Q74; final UX §6 |
| M04 | Ask someone / request assignment change; respond `やる / 難しい / その他の返答`; checking, consultation, comment-softening, expiry, re-proposal, agreed-outside-app correction | **LINE MUST complete** | The request/assignment negotiation lifecycle must be operable in LINE, including stale/expired actions. Work deadline and reply deadline remain distinct; acceptance converges onto linked ToDo execution truth. | Baseline §§7, 13.1, 14.2; Q2, Q9, Q30, Q36, Q41-Q47, Q69, Q83-Q86; final UX §§7, 11; design 04 §§13-14 |
| M05 | Share / hand over household information, choose meaningful acknowledgement when needed, and keep share validity separate from ToDo completion | **LINE MUST complete** | Household share is the default; self-only is exceptional. Important/action-required handover may require explicit `確認した`; LINE read is never that acknowledgement. | Baseline §8; Q3, Q16, Q37-Q40, Q48-Q49; final UX §8 |
| M06 | Complete an individual current task / occurrence with the normal one-tap outcome | **LINE MUST complete** | Normal completion is available in the daily LINE flow. Planned owner and actual performer remain separate; completion does not create a second request completion truth. | Baseline §§11, 23; Q5-Q7, Q29, Q36, Q53, Q62-Q63; final UX §§4, 7, 15 |
| M07 | Group reconciliation: `全部やった / 大体やった / 個別で答える`, including exact eligible scope, `余力があれば` exclusion, post-write correction/undo | **LINE MUST complete** | The normal grouped result can be finished in LINE. `大体やった` is group evidence only; unknown children stay unknown and follow carryover semantics. | Baseline §§10-11; Q5-Q6, Q31, Q59-Q66, Q87; Q60-1/Q60-2; final UX §§3-4, 11; design 04 §8 |
| M08 | Correct a recent/yesterday actual, record `今回は不要`, explicit reschedule, or other ordinary occurrence-level result | **LINE MUST complete** | `入力` can switch to missed morning/yesterday correction/off-plan actual. Ordinary correction/result selection does not require History navigation. | Baseline §§9.4-9.6, 11.2-11.6, 13.5; Q29, Q31, Q53, Q55, Q62-Q66, Q76, Q82; final UX §§4, 11, 15 |
| M09 | Put a task in `待ち`, continue waiting, resume, or change next-check date when it becomes operationally relevant | **LINE MUST complete** | Waiting is not ordinary incomplete. Due next-check/risk resurfaces in the shared Daily Brief; basic state actions stay available in the daily channel. | Baseline §9.2; Q22-Q25, Q31; final UX §6; design 04 §§2.1, 9 |
| M10 | `誰でもOK` claim for execution and release when no longer taking it | **LINE MUST complete** | Daily execution cannot require PWA just to claim/release. Claim is not assignment rewrite and does not auto-expire. | Baseline §6.5; Q107-Q109; final UX §9; design 04 §15 |
| M11 | Receive morning/evening operational brief and action-changing immediate notifications | **LINE MUST complete** | Scheduled and immediate delivery are LINE responsibilities. Normal completion is not scorekeeping push; requests, important changes, and material risks surface according to policy/bundling. | Baseline §§14, 17; Q14-Q15, Q19, Q25-Q26, Q39-Q40, Q80, Q85-Q88; final UX §§2, 11; design 04 §§6-7, 16-19 |
| M12 | One-user synthetic spouse test conversation before real two-user onboarding | **LINE MUST complete** | The operator can exercise both sides in one LINE talk while domain validation is shared and production side effects/real consent remain fenced. | Baseline §20; Q27; final UX §15 |
| M13 | Open richer task/detail UI for subtask progress, waiting memo, rare result, multiple actual actors, optional dates/duration/importance | **PWA MAY hand off** | LINE keeps the normal task action. Richer/rare fields may open the concrete task/occurrence in PWA with context preserved. | Baseline §§9-11, 15; Q21-Q22, Q32, Q54, Q56-Q57, Q78; final UX §§3, 5-6 |
| M14 | Resolve duplicate/stale/concurrent/Authority conflicts that need side-by-side evidence or richer diff | **PWA MAY hand off** | LINE must never silently merge/overwrite and may show a compact conflict with a deep link. Rich comparison can continue in PWA against the same candidate/revision. | Baseline §§5.5, 16.6, 23; Q49, Q81, Q95; final UX §§10, 13-14; design 04 §§10-11 |
| M15 | Send nursery/notice images, receive light triage, then review/edit extracted schedule/share/preparation candidates | **PWA MAY hand off** | Image intake/light classification is available from LINE. Structured multi-item review may deep-link to the concrete extraction review in PWA; registration remains human-confirmed and source facts stay separate from AI inference. | Baseline §§19.1-19.8; Q89-Q90, Q93, Q96-Q99; final UX §§11-12 |
| M16 | Choose `個別で答える` and move from LINE to richer batch/one-by-one entry | **PWA MAY hand off** | LINE remains a valid answer mode. Choosing PWA opens the exact current reconciliation/group with existing entered state. | Baseline §§11.1, 15; Q64-Q66, Q78-Q79; final UX §§4, 11; design 04 §8.4 |
| M17 | Enter a management destination from LINE `その他` or a warning/summary and continue in the exact PWA target | **PWA MAY hand off** | `その他` can expose calendar, events/prep, shopping, base rules, history, settings, PWA. Hand-off is target-specific, not a generic home redirect. | Baseline §§13.6, 15; Q77-Q79; final UX §§5, 11; design 04 §§11-12 |
| M18 | Take over another person's current `誰でもOK` claim when operationally necessary | **PWA MAY hand off** | Takeover is a secondary exceptional action, not routine first-level UI. LINE may surface it contextually or deep-link to detail; confirmation must show current claimant. | Baseline §6.5; Q107-Q109; final UX §9; design 04 §15 |
| M19 | Review history/analytics/audit trail and perform deep historical correction | **PWA ONLY** | History/analysis is non-push and deeper navigation. Planned owner and actual actor remain separate; corrections retain prior history. Recent/yesterday correction remains covered by M08 and is not forced here. | Baseline §§21, 11.6; Q20, Q28-Q29, Q62; final UX §15 |
| M20 | Household/settings administration, notification preferences/schedules, family terminology management, detailed optional defaults | **PWA ONLY** | Detailed settings live in PWA. LINE uses the resulting semantics but does not need a parallel settings editor. | Baseline §§14.1-14.2, 16.3-16.5, 25; Q25-Q26, Q56-Q57, Q72, Q77, Q88; final UX §§10-11 |
| M21 | Base assignment rules, validity-period weekly/transport templates, future rule recalculation/conflict review, custom grouping | **PWA ONLY** | Stable rule/template administration is PWA responsibility. It must preserve explicit occurrence overrides and individual agreements and use the shared canonical commands. | Baseline §§6.1-6.2, 10.1; Q10-Q12, Q50-Q52, Q58, Q60/Q60-1; final UX §6; design `09_TRANSPORT_PERIOD_TEMPLATE_AND_MONTH_UX.md` |
| M22 | Month/day/calendar planning, inline day summary, Google-linked schedule detail, Google delete/duplicate/change resolution | **PWA ONLY** | LINE Today may show integrated schedule and warn on relevant change, but calendar browsing/editing and provider-resolution detail live in PWA. Google is schedule-first and never a second household truth. | Baseline §§18, 15; Q34, Q77-Q79, Q110-Q112; final UX §§5, 13; design 09 §§4-6 |
| M23 | Event project management and preparation review/editing | **PWA ONLY** | Event milestones may notify via LINE, but event/template preparation management is the richer PWA surface; event itself has no whole-event coordinator. | Baseline §17; Q17-Q19, Q58; final UX §10 |
| M24 | Nursery source detail/privacy management, original-image viewing/deletion, monthly notice review, confirmed preparation rules, recurring candidates/exceptions, URL/QR detail, optional completion evidence | **PWA ONLY** | LINE may alert or deep-link, but these detail/bulk/privacy surfaces live in PWA. Ordinary ToDo completion created from nursery intake still follows M06. | Baseline §§19.6, 19.9-19.17; Q91-Q95, Q100-Q106; final UX §12 |
| M25 | Registration-error deletion and other destructive/admin correction that is distinct from ordinary occurrence outcomes | **PWA ONLY** | `今回は不要 / 中止 / 不要になった / 再予定` remain ordinary states/results and are not collapsed into delete. True deletion is a deeper registration-error action with history protection. | Baseline §22; Q29, Q82; final UX §15 |
| M26 | Browse/manage the shopping list and its richer status lifecycle while preserving action-level household actual semantics | **PWA ONLY** | LINE remains able to add shopping needs and handle daily claim/completion, while full list/status browsing belongs to PWA detail. Product checks prevent forgetting items; household actual is the shopping trip/action, not one actual per product. | Baseline §§12, 13.6, 15; Q33, Q77-Q79, Q107-Q109; final UX §9 |

## 5. Q1-Q112 coverage guard

This guard is not a replacement for Appendix A. It verifies that the scenario matrix did not silently omit a decision family. Where one Q affects both a daily flow and a richer management flow, it intentionally appears in more than one matrix row.

| Appendix decisions | Matrix coverage |
|---|---|
| Q1-Q4 | M01, M02, M04, M05 + cross-channel invariant |
| Q5-Q8 | M02, M03, M06, M07 |
| Q9-Q16 | M01, M04, M05, M11, M21 |
| Q17-Q20 | M11, M19, M23 |
| Q21-Q24 | M01, M03, M09, M13 |
| Q25-Q32 | M01, M04, M07-M13, M19 |
| Q33-Q40 | M01, M02, M04-M06, M11, M22, M26 |
| Q41-Q49 | M04-M05, M14 |
| Q50-Q58 | M03, M07-M08, M13, M20-M23 |
| Q59-Q64 | M07-M08, M16, M21 |
| Q60-1 / Q60-2 | M07, M21 |
| Q65-Q72 | M01-M02, M04, M16, M20 |
| Q73-Q80 | M01-M02, M08, M11, M16-M17, M26 |
| Q81-Q88 | M04, M08, M11, M14, M25 |
| Q89-Q96 | M14-M15, M24 |
| Q97-Q106 | M15, M24 |
| Q107-Q109 | M10, M18, M26 |
| Q110-Q112 | M22 |

The canonical full decision text remains in `FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md` Appendix A. The approved final UX audit independently mapped all 114 decision rows (Q1-Q112 plus Q60-1/Q60-2); see `11_APPROVED_FINAL_UX_CANONICALIZATION.md`.

## 6. Boundary examples

These examples prevent category misreading; they do not add product behavior.

- **Normal task completion:** LINE MUST complete (M06). Opening the same task in PWA is optional and uses the same command.
- **`個別で答える`:** LINE MUST offer a LINE path; user may choose the PWA hand-off (M16).
- **History:** PWA ONLY for deep history/analytics (M19), while yesterday/recent correction remains LINE-completable (M08).
- **Nursery image:** LINE handles upload/light triage; rich multi-item/source review may hand off; source/privacy/monthly/rule management is PWA-only detail (M15/M24).
- **Google conflict:** LINE may tell the user action is needed, while side-by-side provider conflict resolution is PWA detail (M22). Protected household values remain effective until resolution on either channel.
- **Base rule vs one-off assignment:** stable base/period-rule administration is PWA-only (M21); a daily request/assignment negotiation remains LINE-completable (M04).
- **Shopping:** adding a need and daily execution stay on the LINE operational path; rich list/status browsing is PWA detail (M02/M10/M26).

## 7. USER DECISION REQUIRED

**One genuine unresolved product-governance decision remains:** product-owner final approval of this responsibility matrix.

Until approved, this document is a complete derived proposal and review artifact, not authority to change any existing application behavior. Approval should confirm the scenario classifications as a faithful explicitization of the already-approved Requirements/UX; it must not be used to smuggle unrelated product changes into this lane.

No other product decision was required to derive the matrix from CURRENT authorities.