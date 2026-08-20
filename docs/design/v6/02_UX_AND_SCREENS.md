# 02. UX / Screens

## 1. UX原則

- 2秒で主要操作。
- Todayはdashboardではなく「次に何をすべきか」。
- 低優先度は折りたたむ。
- 採点しない。
- お願いは受ける/今回は難しいを明確に。
- 原文と共有文を混ぜない。

## 2. Bottom nav

- 今日
- タスク
- 買い物
- 履歴
- `+`

設定は右上。

## 3. Today 情報優先順位

### Priority 1: 今/次の予定
例:
`17:30 お迎え（担当: ママ）`
`18:00 ママ予定あり ⚠ お迎えと重複`

### Priority 2: 自分の判断待ち
- 受け取ったお願い
- 担当衝突の確認
- LINEから作ったpending action

### Priority 3: 今日の自分のタスク
- 送り/迎え
- 夕食/お風呂/洗濯等

### Priority 4: 重要な引き継ぎ
未読のみ最大2件。`すべて見る`で展開。

### Priority 5: 折りたたみ
- 買い物
- 家族全体の低優先ToDo
- 完了済み

## 4. タスクカード

表示:
- title
- planned assignee
- status
- due/time optional
- subtask progress `3/5`
- primary CTA `完了`

完了後:
- actual contributor(s)
- completed_at

subtasks modeで複数人なら:
`パパ: 回す / ママ: 畳む・収納`

task-levelで「完了者: ママ」と単一表示しない。

## 5. お願い作成

Step 1: 自分専用入力
`帰りに牛乳買ってきて。もうないよ。`

Step 2: AI/shared preview
`牛乳がなくなっているので、帰りに買ってきてもらえる？`

Step 3:
- 宛先
- shared text
- due
- `[この内容でお願いする]`
- `[自分で修正]`

recipientにはStep1を一切表示しない。

recipient:
`🙏 パパからお願い: 牛乳を買う`
`[引き受ける] [今回は難しい]`

## 6. LINEでの定例変更

入力:
`今週から木曜の送りはママ`

preview:
`定例変更候補: 木曜 送り パパ→ママ`
`[今後ずっと変更] [今回だけ] [やめる]`

入力:
`明日迎え行くよ`

preview:
`8/20のお迎えを今回だけパパに変更しますか？`

## 7. 引き継ぎ

共有表示は箇条書き中心。

例:
- 朝食は少なめ
- 眠そうな様子あり
- 着替えに時間がかかった

未読バッジは`handover_reads`で永続化。

## 8. 履歴

見出し:
`今週、家庭で完了したこと 42件`

カテゴリ別:
- 送迎
- 食事
- お風呂
- 洗濯
- 掃除
- 学習
- 買い物
- ToDo

表示できるもの:
- planned assignee
- actual contributor(s)
- 代理対応
- completion count

禁止:
- 勝率
- ポイント
- 負け/勝ち
- やってないランキング

## 9. Offline

offline時:
- cached Todayを閲覧可能
- mutation CTAをdisabled
- 上部に`オフライン: 更新はオンライン接続後にできます`

MVPでmutation queueは実装しない。

## 10. Routine check-in screen — v6

Route: `/checkin/:sessionId`

Header:
- `朝のチェック` / `お迎え・夜のチェック` / `夜のチェック`
- date
- planned assignee
- session status

Body:
- task cards in the same order as LINE checklist
- subtasks expandable
- current completion source/contributor

Actions:
- 完了
- 相手が対応
- 今回は不要
- undo where lifecycle allows
- `残りをすべて完了`

If session is superseded after reassignment:
- destructive controls disabled
- show `担当が変更されました`
- link to latest Today/session

## 11. Notification timing settings — v6

Settings > 通知タイミング:
- 来週の予定
- 今日の担当
- 朝チェック
- 朝チェック確認
- お迎え担当チェック
- お迎え担当確認
- 迎え担当以外の夜チェック
- 夜チェック確認

Each row:
- enabled toggle
- local time
- weekly only weekday

Display timezone as fixed `Asia/Tokyo`; no timezone editor in MVP.


## v6 setup wizard — evening routines

Before Ready:
1. confirm dropoff/pickup
2. configure evening tasks
3. connect Google Calendar
4. connect LINE accounts
5. review notification times

Each evening task:
- weekday chips
- strategy: お迎え担当 / お迎え担当ではない人 / 固定 / やらない
- fixed person only when fixed
- optional time
- explicit Save


## v6 weekend/holiday Today screen

Badge `土日祝モード`.
Shows today events/shared ToDo/each person's tasks.
Sunday also shows next-week preview.
Settings separates 平日 vs 土日祝.
No Sunday-noon weekly setting.
