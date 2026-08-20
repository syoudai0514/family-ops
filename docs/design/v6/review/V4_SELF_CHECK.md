# v4 Self Check

SOL再レビュー前に以下をmutation testとして確認する。

## Schema / Google
- [ ] untitled Google eventを保存できる
- [ ] id-only deleted eventでsync transactionが落ちない
- [ ] minimal cancelled recurring exceptionをtombstone保存できる
- [ ] cancelled occurrenceをTodayへactive表示しない
- [ ] transparent eventを担当衝突へ使わない
- [ ] busy member不明eventをcreatorから勝手に推測しない
- [ ] cross-household Google credential FKがDBで失敗する

## Mutation boundary
- [ ] browserはserver transaction RPCを直接executeできない
- [ ] EdgeがJWT actorをderiveする
- [ ] client supplied household_id/actor_idは認可根拠にならない
- [ ] same operation + same payloadは同じresultを返す
- [ ] same operation + different payloadは409 conflict

## Queue / Cron
- [ ] `google_sync_jobs`にfailed statusがない
- [ ] transient failureはprocessing→queued
- [ ] rerun_requestedをlostしない
- [ ] Cron worker tokenなし/不正は401
- [ ] tokenはlogへ出ない

## Scheduled LINE
- [ ] 日曜12:00は次の月〜日を送る
- [ ] 07:00 daily assignmentは双方へ送る
- [ ] 送り担当07:00はdaily summaryとchecklistを1通にbundle
- [ ] 08:30時点で全完了ならreminderなし
- [ ] 16:00 pickup、20:00 non-pickupを正しくtargetする
- [ ] 20:30/22:00 reminderは未完了項目だけを示す
- [ ] LINE postbackとPWA deep linkが同じsession/taskを更新する
- [ ] cron rerunでもscheduled pushが重複しない
- [ ] reassignment後は古い担当へreminderしない
- [ ] reassignmentがdigest後なら双方へ即時変更通知する
