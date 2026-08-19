# v4 Changelog

## v3独立SOLレビュー反映

1. Google canonical cacheのtitle等をnullable化し、deleted/cancelled tombstone contractを固定。
2. Google create idempotencyをclient-generated event IDへ固定。
3. `google_write_operations`追加、409/timeout/412 recoveryを固定。
4. `google_sync_jobs`からambiguous `failed`を削除し、`queued/processing/done/dead`へ固定。
5. PWA mutation entrypointをEdge Function onlyへ固定。
6. server-only transaction RPCのEXECUTEをPUBLIC/anon/authenticatedからREVOKE。
7. `CRON_WORKER_TOKEN`でCron→worker認証を固定。
8. `MUTATION_CONTRACT_MATRIX`追加。
9. `mutation_receipts`でPWA/LINE-originated mutationを冪等化。
10. Google credentialをhousehold composite FKへbinding。
11. recurrenceへ`scheduled_local_time`と`conflict_window_minutes`追加。
12. Google event creatorとbusy memberを分離。
13. Google `transparency`を保存しtransparent eventをconflict対象外へ。
14. OAuth TestingのCalendar refresh token 7日失効をsetup/runbook gateへ明記。
15. subtask contributor / handover read / creator mappingのsame-household DB保証を強化。
16. notification dedupをrecipient/channel scopeへ修正。
17. request cancel lifecycleをpending-onlyへ固定。
18. shopping state machineを固定。
19. all-day eventはMVPで常にconflict対象外へ固定し、未実装設定文言を削除。
20. special preparation seedを通常task definition + recurrenceへ正規化。
21. historical FKのON DELETEをRESTRICT + deactivateへ固定。
22. recurrence overlapを`btree_gist` exclusion constraintへ固定。
23. invalid Google watch webhookは2xx ignore + structured warningへ固定。
24. expired one-time tokenはhard deleteへ固定。

## ユーザー追加要件

1. 日曜12:00に次週予定を夫婦へLINE配信。
2. 毎朝07:00に今日の送り/迎え担当を夫婦へLINE配信。
3. 送り担当へ07:00朝チェックリスト、08:30チェックイン依頼。
4. 迎え担当へ16:00チェックリスト、20:30チェックイン依頼。
5. 迎え担当以外へ20:00夜チェックリスト、22:00チェックイン依頼。
6. チェック実績はLINEまたはPWAで入力。
7. LINEメッセージには該当PWA画面へのdeep linkを必須化。
8. 同時刻同一recipientはbundle、完了済みreminderは抑止。
9. 定時通知時刻はhousehold設定から変更可能。
10. `routine_checkin_sessions`で「提示したチェックリスト」と「後から入力する実績」を同じsessionに束ねる。
