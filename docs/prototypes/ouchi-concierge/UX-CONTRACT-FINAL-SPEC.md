# おうちノート — Final UI / Interaction Contract

This document is the implementation-owner handoff for the final audited interactive UX artifact.

- Final HTML SHA-256: `42b5a0630d699f969edf14b9b53b0b8bc5fc725c28b5af352a1f9adc050666b4`
- Audit: `UX-CONTRACT-FINAL-AUDIT.md`
- Canonical requirements remain `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`; this prototype/spec does not supersede them.

## 1. Product loop

The primary product loop is:

**今日の状況を最初に把握 → 要対応へ直接移動 → 今やる親タスクと小作業を理解 → その場で完了 → 夜は残りだけをまとめて実績化 → 例外だけ深掘り**

The product is not primarily an actual-entry app. It is a household-operations UI that first answers “今、何をすべきか”. Actual entry follows the work instead of replacing it.

## 2. Today — first viewport contract

The first viewport must contain a linked situation summary. The sample contract is:

- `要対応 2` — reply required / owner unresolved / deadline risk
- `残り 2` — own remaining work today
- `待ち 1` — waiting item due for recheck
- `明日影響 1` — preparation / schedule that changes tomorrow’s actions

Each summary item jumps directly to the relevant section or detail screen.

Today’s priority hierarchy is:

1. `🔴 まず確認`
2. `⚠️ いつもと違うこと`
3. `ℹ️ 引き継ぎ・共有`
4. `✅ もう済んでいること`
5. `📝 今日やること`

Morning / day / evening are runtime-composed from current time. Prototype tabs exist only to review all three states; they are not a production user setting.

Evening must collapse completed morning work to `朝 n/n 完了`. Do not re-list completed morning tasks unless a concrete problem remains.

Own work is primary. Partner work is normally summarized; show concrete partner items only when they affect household operation or the current user.

## 3. Parent task / subtask contract

A parent task that needs substeps must expose progress and remaining concrete work, e.g.:

- 洗濯 `2/3`
  - ✓ 洗濯機を回す
  - ✓ 乾燥まで
  - □ 畳む — normal / bulk eligible
  - □ フィルター掃除 — `余力があれば` / bulk ineligible

Users may check subtasks directly. Do not add a generic “一部完了” button to everyday chores.

A parent-level bulk completion may include only the visible eligible required/normal unfinished scope. `余力があれば` is excluded.

## 4. Actual / reconciliation contract

Immediate per-task completion and grouped evening reconciliation coexist.

Before displaying a bulk completion action, show what “全部” means. Do not use a context-free `全部やった` button.

The grouped entry choices are:

- `上の必須・通常を全部やった`
- `大体やった`
- `個別で答える`

`全部やった` immediately records eligible required/normal work, then exposes:

- `例外を修正`
- `元に戻す`

Do not add an extra confirmation dialog to the normal case.

`大体やった` writes group-level “概ね対応 / 詳細未確認” evidence only. Unknown child tasks remain unknown and follow each task’s carryover rule; they are not silently completed or failed.

Actual time is not user-managed. Save original target date/occurrence, actor(s), and result. Registration/correction timestamps are audit metadata. A next-morning entry still belongs to the original task date.

Individual entry keeps `完了` prominent and hides rare results behind `その他の結果`: partner handled / could not do / not needed this occurrence / cancelled / reschedule / multiple actual actors.

## 5. Navigation / return-state contract

The final prototype implements hash history and session restoration. Production must preserve the same semantics:

- route of origin
- scroll position
- draft text / form fields
- expanded details / subtask state
- daypart review state where applicable
- active tab/filter

Browser Back and in-app Back must resolve to the same logical prior state.

One item update must not trigger whole-page reload or scroll-to-top.

Examples:

- Today summary → Request → Back → Today summary position
- Today task → Task detail → Back → same task row / same expansion
- Month → Day agenda → Close → same month / selected day / position
- History → Actual correction → Close → same filter / row / position
- Concierge → Back → input text retained

## 6. Task / rule contract

A ToDo can be created with title only. The following are optional and hidden behind detail disclosure unless needed:

- start-available date
- target/guide time
- deadline
- reminder offset
- standard duration
- importance override
- optional `カレンダーにも表示`

Owner choices include self / partner / unassigned / `誰でもOK`.

Waiting has status memo, optional next-check date, and original deadline. Normal incomplete nag is suppressed while waiting; it returns at next check, but deadline risk can still surface.

Carryover behavior is explicit by task nature: occurrence ends / remains until done / remains through deadline / previous occurrence remains separate from next.

Routine/weekday rules have validity periods. Applying a change exposes `この日だけ / この期間 / 今後ずっと` before confirmation. Recalculate only future occurrences derived from the base rule. Preserve explicit overrides and individual agreements; grouped future conflicts are confirmed with both parties. Disagreement keeps the prior individual agreement while assignment is under negotiation.

## 7. Request / assignment contract

First response tier is exactly:

- `やる`
- `難しい`
- `その他の返答`

`その他の返答` contains `確認してみる` (self-side adjustment) and `相談する` (counterpart condition consultation).

Reply deadline and work deadline are distinct. Expired negotiation attempts close as failed with original assignment preserved; late actions do not revive the attempt and instead offer a new proposal.

Light requests may end after `難しい`; required operational problems such as pickup remain assignment-unresolved in Today.

`コメント付きで難しい` asks for the comment only in that path, may offer an AI-softened family-facing candidate, requires sender review, and sends one final result instead of sending `難しい` first.

After acceptance, linked ToDo is the execution truth. Request retains agreement/provenance history only. Accepted request modifications/cancellations are proposals and update linked ToDo only after counterpart confirmation.

When directly changing the partner’s owner, first ask whether it was already agreed outside the app. A declared pre-agreed important change is recorded with audit history and a non-blocking counterpart correction action `[違う]`. This question is not shown for actual-entry-only changes.

## 8. Share / handover contract

Share scope, ToDo creation, and ToDo owner are independent decisions. Household is the default share scope; self-only is an exception.

Share validity (`today / tomorrow / until date / until cleared`) is independent from related ToDo completion.

Only important/action-required handovers show explicit `確認した`; ordinary shares use read acknowledgement. LINE read receipt is never treated as explicit acknowledgement. `確認した` is not ToDo completion.

## 9. Shopping / anyone-owner contract

Shopping statuses remain browseable: wanted / owner decided / ordered / purchased / arrived / cancelled.

`誰でもOK` is a formal owner kind, not unassigned. Before execution, a person claims with `[自分がやる]`. The claimant can release manually; expiry does not auto-release. Takeover is shown only when needed, not as a routine first-level action.

Product checks prevent forgetting items; household actual is the shopping trip/action, not one actual per product.

## 10. Event / AI / Concierge contract

Event creation uses event template + AI candidate additions + human review. Event itself has no whole-event coordinator; preparation ToDos each have their own owner.

Concierge is an additional universal input, not the Today primary surface. It supports text and transcription-first voice:

**話す → 文字起こし → transcript edit → semantic decomposition → candidates → ambiguity-only clarification → registration**

One input can decompose to share / ToDo / shopping / request / actual and be confirmed in one screen. Ask only ambiguous fields; do not re-ask understood fields. Household terminology is view/edit/delete-able and learns meaning only, never silently changes assignment rules.

Duplicate candidates are never auto-merged; user chooses existing / update / separate.

## 11. LINE reference contract

Fixed menu is exactly:

`今日 / 入力 / 追加 / お願い / 共有 / その他`

LINE Today lists all own same-day tasks clearly, morning and night as relevant, with spare-capacity work separated. Partner is normally summarized.

`入力` opens the most natural current target and allows switching to missed morning input / yesterday correction / off-plan actual. Individual LINE input is exception-first with optional one-by-one mode or PWA deep link.

`追加` is free-text-first with shortcuts. Image upload lightly triages nursery/notice-like images; normal family photos do not trigger household-operations extraction proposals.

PWA deep links open the concrete target and retain entered state. PWA success stays in PWA; do not self-echo a generic `保存しました` LINE message.

## 12. Nursery image contract (Q89–Q106)

Final UI includes concrete surfaces for:

- sequential-image grouping / split
- nursery / child / class inference with ambiguity-only correction
- no ingestion of unrelated children/classes
- one-screen editable schedule / share / preparation candidates
- stated source facts separated from AI inference
- confirmed nursery-specific preparation rules
- later-notice update diff including related preparations
- protected human-value conflict review
- original image view, private handling, raw-image-only deletion, and source-unavailable correction state
- monthly recommended high-impact schedules plus inspectable remainder
- bounded recurring-rule candidate
- one-occurrence exception without destroying series
- submission as due ToDo
- high-confidence URL/QR action and low-confidence non-link state
- optional completion evidence while normal completion remains one tap

Spouse can view original source from household detail; do not resend raw image in ordinary LINE messages.

## 13. Google / shared Authority contract

Google is schedule-first. ToDos are shown in Calendar only when individually requested.

Google time changes may update linked schedule when not conflicting with protected human values; related preparation changes are candidates. Deletion asks `中止 / 日程変更待ち / Googleだけ非表示`. Duplicate asks existing-link vs separate-add.

Human-confirmed values, Google candidates, nursery source facts, and AI inference use one Authority review model: no newest-wins. Show current protected value plus each candidate and provenance. Keep protected current effective until human resolution, then record the resolution history.

## 14. Operational UI states

Implementation must include Loading / Empty / Error / Stale states. Error preserves user input. Stale/concurrent updates do not overwrite silently; show latest-vs-user diff and resolve safely.

## 15. Test / history / deletion

One-user LINE test mode uses simulated actor but the same core state-validation model. It must not cause real LINE/Google/production-notification side effects, must be excluded from production analysis by default, and simulated agreements never become the real spouse’s consent. Unresolved simulated negotiations are not auto-migrated when the real user joins.

History is non-push and deeper navigation. Planned owner and actual actor(s) remain distinct. Actual correction preserves prior history. Audit registration timestamps are hidden by default. Avoid competitive ranking / “who won” presentation.

Deletion is only for registration errors. `今回は不要 / 中止 / 不要になった` remain distinct outcomes. Existing actual history is not erased by deletion.

## 16. Non-UI requirements

The final HTML intentionally does not pretend to prove runtime guarantees. The implementation owner must separately prove source/test requirements including:

- shared LINE/PWA canonical commands/business logic
- webhook idempotency / retry safety
- stale/CAS protection
- household / actor / conversation isolation
- notification deduplication / bundling
- provider mutation ownership
- Google idempotency / duplicate / conflict safety
- nursery storage privacy / access control
- URL/QR safety validation
- test-mode external-side-effect fences

See `UX-CONTRACT-FINAL-AUDIT.md` for final audit scope and result.
