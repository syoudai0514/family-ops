# 17. Routine LINE Automation — v6 normative

この文書は定時LINE運用の正本。時間は初期値であり、household設定から変更可能にする。

## 1. 目的

Family Opsは「記録したい時にアプリを開く」だけに依存しない。
家庭運営に必要なタイミングでLINEが能動的に:

1. 今日/今週の予定を思い出させる
2. 誰の担当かを明示する
3. その担当者が今やるべき項目を提示する
4. 後で実績入力を促す
5. LINEまたはPWAのどちらからでも同じtask/sessionを更新できる

というループを作る。

## 2. 初期schedule

MVP timezone=`Asia/Tokyo`.

### Weekday schedule — Mon-Fri excluding Japanese holidays
| schedule_kind | default | recipient |
|---|---|---|
| daily_assignment | 07:00 | all adults |
| dropoff_checklist | 07:00 | dropoff assignee |
| dropoff_checkin | 08:30 | dropoff assignee |
| pickup_checklist | 16:00 | pickup assignee |
| nonpickup_evening_checklist | 20:00 | other adult |
| pickup_checkin | 20:30 | pickup assignee |
| nonpickup_evening_checkin | 22:00 | other adult |

### Non-workday schedule — Sat/Sun/Japanese public holiday/holiday-law day
| schedule_kind | default | recipient |
|---|---|---|
| nonworkday_morning_digest | 09:00 | all adults |
| nonworkday_checkin | 20:00 | all adults |

Both linked => normal upper target = 4 counted deliveries/day.

Sunday 09:00 includes both:
- Sunday today section
- next Monday-Sunday weekly section

There is no Sunday 12:00 weekly dispatch.

Applicability:
`is_nonworkday = weekend OR private.jp_holidays row`.
Non-workday suppresses all weekday role schedules.

## 3. Sunday 09:00 weekly section


### 対象期間
Sunday 09:00実行時、**翌Monday 00:00〜翌Sunday 23:59:59 household local time**。

### source
優先順ではなく、以下を統合する。

1. Google Calendar rolling occurrence projection
2. dropoff/pickup recurring task assignment
3. date-specific once reassignment
4. 特別準備task
5. due dateのあるrequest/shopping/manual taskのうち重要表示対象

### 出力例

```text
📅 来週の予定（8/24 月〜8/30 日）

月
・送り：パパ / 迎え：パパ
・昼寝用寝具・上履き
・15:30 言語

火
・送り：パパ / 迎え：ママ
・体操教室用品
・14:00 受付

...

⚠ 担当と予定の重なり 1件
→ Family Opsで確認
```

### Calendar freshness
- Sunday 09:00 weekly sectionの10分前を目安に`weekly_digest_preflight`内部処理でactive calendar connectionをsync enqueueする。
- preflightはuser-facing schedule rowではなくworker logic。`worker_run_receipts` key=`weekly_digest_preflight:{household_id}:{week_start}`で1回だけenqueue。
- digest時にCalendar cacheが最後の成功syncから60分以上古い、または`reauth_required=true`なら、digest自体は送るが末尾へ`⚠ Google予定を最新化できていません`を付与する。
- Calendar障害で家事担当まで送れなくなる設計にしない。

## 4. Daily assignment 07:00

夫婦双方へ:
- 今日の送り担当
- 今日の迎え担当
- special preparationがあれば短く追記
- conflict warningが既に計算済みなら追記

例:

```text
☀️ 今日の担当
送り：パパ
迎え：ママ

今日は英語の日です。
```

### 07:00 bundling
送り担当には同時刻の`dropoff_checklist`もある。
同じrecipientへ2通送らず、1つのLINE message envelopeへbundleする。

```text
☀️ 今日の担当
送り：パパ / 迎え：ママ

🎒 朝のチェック
□ 着替え
□ 英語用品
□ 上履き
□ 送り

[全部完了] [項目ごとに入力]
[PWAで開く]
```

非送り担当にはdaily assignment部分だけを送る。

## 5. Dropoff session

### session生成
07:00 dispatch時に`routine_checkin_sessions`をget-or-create。

- session_type=`dropoff`
- scheduled_date=today local date
- assignee_id=today's dropoff assignee
- items:
  - `routine_phase='morning'`で今日、role strategy/materializationによりassigneeへ割り当て済みのtask instances
  - dropoff task instance自身
- item orderはtask_definition.sort_order → task_instance.created_at

### 08:30 check-in
送信直前にsession itemsの最新状態を読む。

- 全required item completed/skipped/cancelled → reminderを送らない。session `auto_closed`可。
- 未完了あり → 未完了のみ表示。
- reassignmentで現在のdropoff assigneeがsession.assigneeと変わった場合:
  - old sessionを`superseded`
  - old assigneeへreminderを送らない
  - new assigneeのsessionがなければ生成
  - assignment change通知は変更時点で即時送信済みとする

例:

```text
📝 朝のチェックをお願いします
まだ未入力/未完了:
・英語用品
・送り

[全部完了] [項目ごとに入力]
[PWAで確認]
```

## 6. Pickup session 16:00 / 20:30

### target
今日の`pickup` task instanceの`planned_assignee_id`。

### checklist contents
- pickup task instance
- `routine_phase='evening'`で今日、そのpickup assigneeにplanned assignmentされているtask instances

**重要:** 「迎え担当なら夕食・風呂・洗濯を全部やる」とコードで仮定しない。
どのtaskが誰担当かはrecurrence/manual assignmentの正本を使う。Recurrence may use role strategy (`pickup_assignee` / `nonpickup_adult`) so pickup reassignment can intentionally move role-bound work; fixed-assignee tasks do not move automatically.

### 20:30 check-in
- same session
- all doneならskip
- incomplete only
- LINE/PWA両入力

## 7. Non-pickup evening session 20:00 / 22:00

### target selection
MVP adult membersが2人の場合:
`household_members - current pickup assignee` の1人。

例外:
- pickup assignee null → non-pickup roleを決めず送らない。双方へ`迎え担当が未設定`warningを1回送る。
- adult member数 != 2 →自動推測しない。PWA設定エラー表示。将来はrole assignment model拡張。

### checklist contents
- `routine_phase='evening'`
- scheduled_date=today
- planned_assignee_id=non-pickup user
- status active

20:00時点で0件なら通知なし、sessionも作成しなくてよい。

22:00 check-inはpickup同様、未完了がある時だけ送る。

## 8. LINE内input contract

LINEはnative checkboxを前提にしない。
Message action / postback action / quick replyを組み合わせる。

### top-level actions
1. `全部完了`
2. `項目ごとに入力`
3. `今回は不要`
4. `PWAで開く`

### 全部完了
- current userに属するsessionをserver-side load
- active itemsのみ列挙
- whole taskはcurrent userでcomplete
- subtask modeは未完了required subtasksをcurrent userでcomplete
- request-linked task等の副作用も通常`complete-task` contractを通す
- 1 transaction per mutation operation、session finalizationは全item判定後

### 項目ごとに入力
botが未完了itemを順番に提示。

各item:
- `完了`
- `相手が対応`
- `今回は不要`
- `次へ`

`相手が対応`はactual_completed_by=partnerまたはsubtask contributorをpartnerにする。planned assigneeは書き換えない。

### 今回は不要
session全部を一括skipしない。
確認を1段挟む:
- `未完了の項目を「今回は不要」にしますか？`
- confirm後、skip可能taskだけskip
- mandatory business rule taskが将来導入された場合はskip拒否

### PWA deep link
`{APP_BASE_URL}/checkin/{session_id}`

- bearer secretをURLへ含めない
- login済みなら直接session画面
- 未loginならGoogle Sign-In後`returnTo`でsessionへ戻す
- RLS/Edge authorizationでrecipient本人のみ操作可能

## 9. PWA check-in screen

表示:
- session type/date/assignee
- item list
- planned assignee
- current state
- subtask expansion
- buttons: complete / partner handled / skip / undo where allowed
- `全て確認して完了`

LINEとPWAは同じmutation APIを使う。
sourceだけ`line` / `pwa`でtask_eventへ記録する。

## 10. Idempotency

### scheduled send
`private.scheduled_dispatch_receipts`:
- household_id
- schedule_kind
- scheduled_local_date
- recipient_user_id
- dispatch_slot_key exact=`{schedule_kind}:{HH:MM}:v{schedule_version}`
- notification_outbox_id
- created_at
- UNIQUE(household_id,schedule_kind,scheduled_local_date,recipient_user_id,dispatch_slot_key)
- **UNIQUE(household_id,schedule_kind,scheduled_local_date,recipient_user_id)** semantic one-send guard

weekly digestの`scheduled_local_date`はweek-start Monday dateを使う。

### same-day schedule edit
- settings mutationごとに`schedule_version += 1`
- その日のlogical receiptが未作成なら、新時刻で1回送信可能
- 既にその日/週のreceiptがある場合、時刻変更後も自動再送しない
- explicit resendはMVP外


### bundle
同recipient + same local minuteで複数scheduleがdueなら:
- due scheduleを集約
- business payloadは別section
- outbox rowは1つ
- receiptは各schedule kindごとに同じoutbox_idを参照可

### LINE action
LINE webhook event IDまたはserver-generated operation IDを`mutation_receipts`へ渡す。
redelivery/double tapで二重task completionしない。

## 11. Notification preferences

`notification_preferences`に以下を持つ:
- weekly_digest_line default true
- daily_assignment_line default true
- routine_checklist_line default true
- routine_checkin_prompt_line default true

ただし:
- userがroutine checklistをOFFにしてもPWA task/sessionは残る
- critical assignment conflictは`conflict_line`別設定

## 12. Schedule settings UX

PWA Settings > 通知タイミング:

- 土日祝の予定: 09:00
- 日曜09:00は翌週予定も同梱
- 今日の担当: 07:00
- 朝チェック: 07:00
- 朝の実績確認: 08:30
- お迎え担当チェック: 16:00
- お迎え担当実績確認: 20:30
- 迎え担当以外の夜チェック: 20:00
- 夜の実績確認: 22:00

変更UI:
- hour/minute picker
- weekly digest weekday picker
- enabled toggle
- restore defaults

制約:
- minute precision
- fixed Asia/Tokyoで保存/表示
- same schedule kind only 1 active row in MVP
- every update increments schedule_version

## 13. Scheduler worker

`dispatch-routine-automation`をevery 1 minuteでCron実行。

algorithm:
1. `CRON_WORKER_TOKEN` verify
2. now UTCを取得
3. now UTCをAsia/Tokyo local datetimeへ変換
4. due scheduleを最大batch sizeでselect
5. recipient/role resolve
6. current task state load
7. no-op判定
8. session get-or-create
9. same-minute bundle group作成
10. scheduled receipt claim
11. notification outbox insert
12. commit

External LINE API callはこのworkerで直接しない。
`send-notifications`がdurable outboxを送る。

## 13A. LINE quota-aware dispatch

Schedulerはoutboxへbusiness intentを作るだけでquota判定しない。
Actual LINE送信直前の`send-notifications`がpriorityで判断する。

Schedule priority:
- nonworkday_morning_digest = normal
- nonworkday_checkin = reminder
- daily_assignment = normal
- dropoff_checklist = normal
- pickup_checklist = normal
- nonpickup_evening_checklist = normal
- dropoff_checkin = reminder
- pickup_checkin = reminder
- nonpickup_evening_checkin = reminder

QuotaでLINE fallbackしても:
- PWA session/taskはそのまま存在
- public.user_notificationsへ同内容を残す
- scheduled_dispatch_receiptは「business dispatch済み」として維持
- notification_outbox status=`fallback`
- 同slotを後からLINEへ自動再送しない

## 14. Failure behavior

- scheduler process crash before receipt commit →次minute retry可能
- receipt commit + outbox insert同transaction → duplicateなし
- outbox send crash →existing notification queue lease/retry
- LINE delivery failure →in-app notificationは独立に保持
- Google Calendar unavailable →weekly digestの家事部分は送る
- PWA unavailable →LINE input still works for basic actions
- LINE unavailable →PWA session remains usable

## 15. Reassignment behavior

### before scheduled notification
最新assignmentを使う。

### after scheduled notification
`reassign-once` / recurrence change transactionで:
- assignment change event
- old/new assigneeを双方へnotification outbox
- active routine sessionをsupersede/rebuild
- old assigneeへのfuture check-in reminder抑止

## 16. Acceptance examples

### A. Monday Papa dropoff / Papa pickup
07:00 Papa:
- daily assignment + morning checklist bundle
07:00 Mama:
- daily assignment only
08:30 Papa:
- morning incomplete if any
16:00 Papa:
- pickup/evening checklist assigned to Papa
20:00 Mama:
- evening checklist assigned to Mama
20:30 Papa:
- incomplete reminder if any
22:00 Mama:
- incomplete reminder if any

### B. Thursday Mama dropoff / Mama pickup
同じlogicでMamaが07:00/08:30/16:00/20:30 target、Papaが20:00/22:00 target。

### C. completed early
Papaが07:40にPWAで朝sessionを全部完了。
08:30 LINEは送らない。

### D. reassignment at 15:30
Mama pickup予定をPapaへ変更。
- 変更直後: 両者へ担当変更通知
- 16:00: Papaへpickup checklist
- 20:30: Mamaにはreminderなし

## 17. Non-goals MVP

- LINE group roomをhousehold canonical identityにしない（1:1 linked userを正本）
- unread LINE message追跡に依存しない
- exact read receiptをLINE providerから取る前提にしない
- SMS/email scheduled dispatchはMVP外


## 7A. Non-workday 09:00 / 20:00

09:00 per adult:
- today's Calendar
- shared ToDo/shopping/request highlights
- own assigned tasks
- Sunday only next-week section

20:00 per adult:
- own incomplete actionable items
- LINE/PWA input actions

If one recipient has no incomplete item, suppress only that recipient's 20:00 delivery.


## 15A. A→B→A same-day session

A→B:
- A superseded
- B current

B→A same date:
- reuse/lock old superseded A row
- rebuild/reconcile items
- status=open
- assignment_generation++
- stale prior-generation actions => SESSION_SUPERSEDED
- no second A insert
