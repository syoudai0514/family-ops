# LINE担当変更の保存までの経路レビュー

対象は2026-10-15 06:36 JSTの実際の会話。「今日の送りは私に変更してください」に担当調整画面のURLを返し、続く「確認した済みです」に「了解！」とだけ返していた。送信内容への返事と担当変更の保存が切り離されていたことを確認した。

## 実装と独立レビュー

- 実作業の送り/お迎えを日付・定義・家庭で特定し、サーバーで本人・成人の家族・実タスク・担当・日時・revisionを再検証する15分間のpreviewを作る。
- LINEで現在→変更後を示し、2人で調整済みという明示操作だけで既存canonical commandを実行する。関連する当日の未完了作業も既存の送迎role再計算へ渡す。通常のお願いや新規ToDoは作らない。
- previewの保存結果とcanonical receiptを確認してから成功返信する。DB結果が不明なら成功とも未変更とも断定せず、同じボタンで結果を確認する。二重押しは保存済み結果を返す。
- 古い確認の取消で「変更していない」と誤って返す点、未調整→調整済みへの会話再開、Push代替での確認ボタン欠落、JST日付またぎを独立レビューで修正した。
- 共有LINE helperのPush保存形式を変更するため、本番はschema→send-notifications→process-line-inboxの順で反映する。旧Push consumerへ本文のないボタンmetadataを渡さない。

## 検証

- 全migration適用と全SQL suite・実並列concurrency suite成功。新SQL132で実際のママ→パパ変更、関連作業、単一のLINE sourceイベント、再送、別人・別家庭、期限切れ、変更後revision、simulation分離を検証。
- 実workerのHTTP回帰17 stepsで、今回の日本語→確認の再表示→明示postback→成功までを再現。JST前日23:59の送信も送信日の作業を選ぶ。
- 共有LINE helperの期限切れReply→outbox→Push組立でボタンの保持、本文重複なし、既存dedupとquota経路を検証。
- 変更したEdge入口の型検査、Deno lint、auth matrix（設計52 / live100）成功。Web画面の変更なし。CIでは既存のWeb/DB/Edge/実Supabase integration/operational/Todayの必須チェックも実行する。

実家庭の担当は開発テストとして書き換えず、実LINE送信も行わない。スマートフォン2台での本人操作はこの自動検証に含めない。
