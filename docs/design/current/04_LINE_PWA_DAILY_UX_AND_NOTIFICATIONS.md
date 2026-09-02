# 04. LINE / PWA Daily UX and Notification Design

## 1. Goal

日常運用の主役はLINE、詳細・一括・設定・履歴はPWA。ただし両者を別productとして設計しない。

**同じDaily Brief / same command contracts**を使い、channelごとにrendering densityだけを変える。

通常日は:

- 朝: 今日の確認 + 必要なら`まとめて完了`
- 日中: 例外時だけ操作
- 夜: 残件確認 + `全部やった / 大体やった / 個別で答える`

で終われること。

## 2. Shared Daily Brief

Server-side `DailyBrief`がLINE `今日`、morning digest、evening digest、PWA Todayの共通read model。

Minimum sections:

1. `urgent_actions`
   - request/assignment response needed
   - unassigned deadline risk
   - stale/conflict requiring human resolution
   - waiting task hard-deadline risk
2. `exceptions`
   - today-specific assignment change
   - unusual school/event requirement
   - schedule changes
3. `active_infos`
   - still-valid share/handover
4. `already_handled`
   - only items whose completion materially reduces current user's expected work
5. `own_task_groups`
   - morning/evening/other; normal active tasks only
6. `partner_summary`
   - count + household-critical explicit items
7. `carryovers`
   - separate, with result certainty
8. `waiting_checks`
   - waiting tasks whose next-check is due/past or hard deadline risk is meaningful
9. `reconciliation`
   - relevant group input status
10. `schedule`
   - Family Ops event + Google occurrence status

Every item includes stable `action_target` for LINE postback/PWA deep link.

### 2.1 Waiting visibility rule

`attention_state=waiting`のtaskは通常の`own_task_groups`や「未完了」nagへ出さない。

- next_check_atが未来 -> 原則非表示、詳細では`待ち`として閲覧可能
- next_check_atが到来/超過 -> `waiting_checks`へ `確認日です` として再浮上
- due_atがrisk window -> `urgent_actions`へ `待ち中ですが期限が近い` として表示可能
- next-check到来だけでtaskをactiveへ自動復帰させない
- `[待ちを続ける] [再開する] [確認日を変更]` から明示操作

`待ち`は未達・失敗・完了のいずれにも集計しない。

## 3. Daypart ordering

### Morning

1. 🔴 まず確認
2. ⏳ 待ちの確認日（該当時のみ）
3. ⚠️ いつもと違うこと
4. ℹ️ 引き継ぎ・共有
5. ✅ もう済んでいること（burden reducing only）
6. 🌅 朝にやること
7. 🌙 夜にやること
8. 💡 余力があれば
9. partner summary

### Daytime `今日`

- urgent/current schedule first
- due waiting check when applicable
- current-time tasks
- upcoming today tasks
- active info
- partner critical state

### Evening

- unresolved risk
- waiting deadline risk / next-check unresolved if relevant
- remaining tonight tasks
- tomorrow-impacting prep
- morning summary (`朝 n/n完了`) rather than replay
- reconciliation input

## 4. Own tasks are visible, not count-only

Requirements requires own daily tasks in LINE body.

Readability controls:

- group by time band
- short titles
- assignment label only when useful
- completed normal morning details collapse in evening
- optional tasks separated under `余力があれば`
- carried tasks have a separate weak heading
- waiting tasks are not mixed with ordinary incomplete tasks

Do not solve noise by hiding all own tasks behind PWA.

## 5. Partner visibility

Default partner display:

- summary counts
- transport
- medical/critical household responsibilities
- today-only changed assignment
- tasks that alter user's behavior

`[相手の分も見る]` expands.

The fact that partner completed normal own work is accessible in detail/history but not pushed as scorekeeping.

## 6. Morning schedule

Default:

- weekday 06:30 JST
- weekend/holiday 09:00 JST

Scheduled worker does not enqueue a fully rendered message hours earlier. It creates/claims a dispatch receipt and renders from latest DailyBrief near send time.

Benefits:

- task completed just before 06:30 disappears/reflects done
- late assignment change is current
- stale request button not emitted
- waiting task only appears when next-check/deadline semantics require it

If calendar cache is stale, send household state and clearly mark calendar section stale; do not suppress entire morning brief.

## 7. Evening schedule

Default 20:30 JST.

Evening should answer:

- what still matters now?
- what affects tomorrow?
- is actual input still needed?

It should not become daily audit report.

Normal completed morning work -> compact `朝 4/4 完了`.

If no meaningful remaining work and reconciliation already settled, message can be shortened substantially; do not send empty nag sections.

Waiting items do not create a routine evening nag unless their check/deadline is relevant now.

## 8. Reconciliation UX

### 8.1 Top level

- `[全部やった]`
- `[大体やった]`
- `[個別で答える]`

Waiting tasks are excluded from the default reconciliation eligible set.

### 8.2 `全部やった`

Server determines eligible own required/normal active tasks.

Response:

`夜の家事 3件を完了にしました [例外を修正] [元に戻す]`

No pre-confirm every day.

### 8.3 `大体やった`

Response does not claim child completion.

Default:

`夜の家事は「概ね対応・詳細未確認」として記録しました。細かい入力はもう求めません。`

If carryover-sensitive subset exists, at most one compact follow-up:

`明日に残る可能性があるもの: 洗濯物 / 食器 [どちらも済み] [結果未確認のまま] [個別]`

This is Final GO MEDIUM-1 acceptance behavior.

Next day unresolved carryover is labelled:

`前回結果未確認`

not:

`未完了` / `できなかった`.

### 8.4 `個別で答える`

First choose:

- `[LINEで答える]`
- `[PWAでまとめて入力]`

LINE default is exception-first.

Example:

`例外だけ教えてください。「洗濯はできなかった、着替えはママ」など。残りを自分完了にする前に確認します。`

Parser result preview:

- 洗濯: できなかった (`outcome_reason=could_not_do`)
- 着替え: ママ実施
- 食器: 自分完了（残りとして推定）

`今回は不要`は`できなかった`と別で表示/保存し、両方を同じskipped reasonへ潰さない。

`[この内容で登録] [直す]`

## 9. Waiting task UX

Task detail / contextual menuで通常操作を汚さないsecondary actionとして:

- `[待ちにする]`
- waiting中は `[再開する] [確認日を変更]`

`待ちにする` mini form:

- 状況メモ optional
- 次に確認する日 optional
- 本来の期限は既存due_atを表示するが上書き必須ではない

Example:

`写真館へ問い合わせ済み。返答待ち`
`次に確認: 9/10`
`期限: 9/15`

Next-check day LINE/PWA:

`⏳ 写真館の返答を確認する日です [待ちを続ける] [再開する]`

Hard deadline risk:

`🔴 写真館の件は待ち中ですが、期限が9/15です [確認する]`

Normal waiting dayにはpush/nagしない。

## 10. PWA Today

PWA Today uses same section ordering but can provide richer interactions.

Rules:

- checkbox/update does not full-page reload
- no scroll-to-top after mutation
- optimistic UI only where server conflict semantics are safe
- mutation response reconciles item in place
- conflict returns current state card inline
- waiting state updates inline without moving scroll unexpectedly
- URL supports `date`, `group`, `task`, `request`, `event`, `candidate` context

## 11. Deep links

Examples:

- `/today?date=YYYY-MM-DD&group=evening`
- `/tasks/{task_id}`
- `/requests/{request_id}?attempt={attempt_id}`
- `/events/{event_id}`
- `/intake/{extraction_id}`
- `/changes/{candidate_id}`

URLs contain opaque IDs only. Raw text, access token, provider secrets are forbidden.

After auth redirect, original app-relative path is restored.

Stale deep link opens latest state rather than reenacting old operation.

## 12. Fixed LINE menu

Target IA:

`今日 | 入力`
`追加 | お願い`
`共有 | その他`

### 今日

render current DailyBrief.

### 入力

open most relevant reconciliation/group based on local time, with quick switch to other unentered groups/corrections.

### 追加

free text first. Shortcuts below:

- 予定
- タスク
- 買い物
- 画像から取り込む

### お願い

request composer shortcut; same underlying natural-input/command model.

### 共有

share/handover shortcut.

### その他

- calendar
- events/prep
- shopping
- base rules
- history
- settings
- PWA

## 13. Request LINE UX

Incoming request first layer:

`[やる] [難しい] [その他の返答]`

Other:

- 確認してみる
- コメント付きで難しい
- 相談する

### checking display

Requester sees once:

`明日のお迎えは確認中です。相手が自分の予定を調整して確認しています。`

No repeated progress push.

### consulting display

Conversation can be natural text. Once AI recognizes a concrete agreement candidate:

`合意候補: 18:30にママがお迎え [この内容で確定] [直す]`

One side confirmation shows:

`相手の確認待ち。現在の担当はまだパパです。`

### expired action

Old button:

`この依頼は期限切れです。現在の担当はパパのままです。 [再提案] [今日を見る]`

No hidden acceptance.

## 14. Assignment change already agreed

When user says oral agreement done:

- apply change
- audit `external_agreement_claim`

For critical changes partner receives neutral correction affordance:

`明日のお迎えはママ担当に変更されました（調整済みとして登録） [違う]`

This is not an approval request.

Minor chore assignment changes can be in next morning/evening brief lower section.

## 15. Anyone claim UX

Task display:

`牛乳を買う  誰でもOK [自分がやる]`

After claim:

`牛乳を買う  パパ対応中 [完了]`

claimant secondary menu:

- 手放す

other adult secondary detail only:

- 引き継ぐ

Takeover confirmation must show current claimant to avoid accidental steal.

No push “パパが担当しました” for normal claim; state is visible on Today/shopping.

## 16. Completion notification policy

### 16.1 Normal chore

Partner completion updates shared state; no immediate push.

### 16.2 Burden-reducing next-view

If partner completed a task that would otherwise appear in user's next morning/current workflow, DailyBrief may show neutral:

`水着セットは準備済み`

not:

`ママがやってくれました`.

### 16.3 Duplicate-sensitive task — Final GO MEDIUM-2

For `duplicate_sensitivity=avoid_duplicate|safety_critical`, completion can create immediate neutral state message when another adult may act before next refresh.

Examples:

- `朝の薬は対応済みです`
- `お迎えは対応済みです`
- `牛乳の買い物は対応済みです`

Actor may be available in detail but not headline.

`safety_critical` delivery priority can use critical LINE reserve if immediate behavior change is needed.

## 17. Notification policy engine

Each intent resolves to:

- `immediate`
- `next_digest`
- `in_app_only`
- `suppressed`

Policy inputs:

- semantic event type
- reply/action required
- deadline proximity
- task duplicate sensitivity
- waiting next-check/deadline risk
- whether state changes behavior now
- recipient preferences
- line quota state
- test context

Hard rules:

- new request requiring response -> immediate
- assignment negotiation response/finalization -> immediate
- important schedule/transport/medical change -> immediate
- waiting next-check -> digest/current brief by default; hard-deadline risk may escalate
- new light household share -> normally immediate once, but may be in-app/digest if explicitly low-impact/non-action and notification preference says so
- normal task completion -> suppress immediate
- duplicate-sensitive completion -> immediate neutral when needed
- minor assignment change -> next digest
- analysis/history -> never proactive push by default

## 18. Bundling

Same user action producing multiple partner-visible outcomes should create one semantic bundle.

Order within bundle:

1. response/action required
2. schedule/assignment change
3. share/handover
4. related prep/tasks summary

Do not delay an urgent request waiting for unrelated future bundle.

Scheduled morning/evening uses one message per recipient where quota/layout allows.

## 19. LINE quota compatibility

Existing hard cap/reply-first/retry-key rules remain.

New policy must not bypass current quota system.

Priority mapping suggestion:

- critical: duplicate-sensitive safety / same-day transport unresolved / waiting hard-deadline risk
- normal: requests, important change
- reminder: routine scheduled digest/noncritical next-check reminder

If push unavailable due quota:

- state remains correct
- in-app notification remains
- current interactive reply token may be used when applicable
- do not fake “sent” status

## 20. Stale message safety

Every postback payload carries opaque resource + revision/attempt reference.

Before action server checks latest.

Examples:

- stale `やる` -> request expired/current attempt message
- stale `完了` after partner completed -> already completed state, no performer replacement
- stale claim -> current claimant shown
- stale waiting reminder after next_check changed/resumed -> latest waiting/current state
- stale event candidate -> refreshed diff

## 21. Natural-language multi-intent UX

One message:

`明日水遊び。水着は自分で準備。牛乳買う。金曜迎えお願い。今日は掃除機やった。`

Preview groups:

- 共有: 明日水遊び
- 自分ToDo: 水着準備
- 買い物: 牛乳
- お願い: 金曜迎え
- 実績: 掃除機

Partner notifications are sent only after user confirms the relevant partner-visible items.

No five separate self-confirmation messages.

## 22. Image intake entry UX

User sends nursery/Codmon image directly or `追加 -> 画像から取り込む`.

System reply:

`園のお知らせとして解析しますか？ [解析する] [写真として扱う]`

When classifier confidence is high and explicit intake route used, skip redundant question and show processing/review link.

Normal family photo should not trigger task suggestions.

## 23. PWA intake review

Single page sections:

- 対象: child/school/class
- `お知らせに記載`
- `AIの準備提案`
- existing conflicts/duplicates
- generated event/task/share/rule candidates
- source image preview

Item-level enable/edit, then one `登録`.

Ambiguous child/school blocks only affected candidate, not unrelated high-confidence items.

## 24. Accessibility and mobile interaction

- minimum touch target appropriate for mobile
- primary action labels explicit Japanese
- state not conveyed by color only
- critical/exception section readable without horizontal scroll
- bottom-sheet/modal must preserve underlying Today position
- after returning from deep detail, restore list filters/date/scroll where feasible

## 25. Acceptance checks for daily UX

At detailed design review, walkthrough at least:

1. normal Monday: morning summary -> bulk complete -> evening all done
2. evening `大体やった` with until_done tasks
3. task `待ち` -> next-check date -> Today reappearance -> continue waiting/resume -> hard deadline risk
4. request checking past deadline + stale accept
5. consultation one-side confirmation
6. partner completes medication before user acts
7. anyone claim + takeover
8. oral pickup change + `[違う]`
9. LINE/PWA same task concurrent completion
10. `今回は不要` vs `できなかった` display/history separation
11. weekend/holiday 09:00
12. quota fallback while critical state remains visible