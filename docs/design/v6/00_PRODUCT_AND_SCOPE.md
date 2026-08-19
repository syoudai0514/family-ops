# 00. Product / Scope

## 1. MVPの目的

家事の量を競うのではなく、家庭を回すための以下の情報を一か所に集約する。

1. 定例家事
2. 追加ToDo
3. 相手へのお願い
4. 買い物
5. 朝/夜/子どもの様子の引き継ぎ
6. Google Calendarの家族予定
7. LINEからの入力・更新・通知
8. AIによる自然文の構造化・言い換え

## 2. 絶対原則

- `planned_assignee` と `actual actor` を分ける。
- 「掃除の質 3/5」のような主観評価は持たない。
- 実施範囲はサブタスクで表す。
- partner requestは一方的に相手の確定タスクにしない。
- raw textは相手に見せない。
- AIは事実・数量・期限・依頼対象を変えない。
- AIが失敗してもraw textを相手へfallback送信しない。
- 定例ルール変更と「今回だけ」は別操作。
- Google Calendarは家族予定の正本。
- LINE/PWA/Googleのどこから変更されても冪等に収束する。

## 3. MVP機能

### A. 定例家事

- 曜日ルールから当日のtask instanceを生成。
- PWA/LINE両方から完了可能。
- PWA/LINE両方から「今回だけ担当変更」「今後の定例担当変更」。
- `相手が対応` はskipではなく、planned assigneeを残したままactual contributorとして記録。
- サブタスクモードでは複数人の貢献を表示。

### B. 追加ToDo

- PWA/LINEから作成。
- title, category, due, assignee(optional)。
- 家庭共通の未担当ToDoも許可。

### C. お願い

状態:
`pending -> accepted -> completed`
または
`pending -> declined`

- send時点ではrecipientのtaskを作らない。
- accept時にtransactionでtaskを作成・link。
- decline時はtaskを作らない。
- linked taskが完了したらrequestもcompleted。
- 原文はrequest recipientから不可視。

### D. 買い物

- `store / online / either / undecided`
- status: `wanted / assigned / ordered / purchased / arrived / cancelled`
- online URL任意。
- 外で買う場合は `purchased` が終端。
- onlineは `ordered -> arrived`。

### E. 引き継ぎ

- 朝/夜/子どもの様子/持ち物/食事/睡眠/家のこと/その他。
- PWA/LINEから入力。
- AIで要点化可能。
- AIを使わず手動共有も可能。
- unread表示をするためread receiptを永続化。

### F. Google Calendar

- 共有secondary calendar 1つを正本。
- PWAから閲覧/作成/更新。
- LINEから予定作成。
- Google側の直接変更をpush + incremental syncで取り込む。
- 「誰が編集したか」は必ず取れる前提にしない。
- editor不明時は「家族カレンダーで予定が変更されました」と通知。
- 家事担当との衝突候補を表示。

### G. LINE

- 公式アカウントを家庭Botとして使用。
- 自然文入力、確認ボタン、完了報告、担当変更、お願い、買い物、引き継ぎ、予定追加。
- webhookは署名検証後 durable inboxへ保存して即応答。
- 後段processorが冪等処理。
- outbound notificationはoutbox経由。

### H. 履歴

- 日/週単位。
- planned/actual、代理対応、複数contributorsを事実として表示。
- 夫婦の勝敗/ランキング/スコアは出さない。

## 4. MVPでやらない

- オフライン書き込み
- Amazon自動注文
- TimeTree直接同期
- 位置情報監視
- 家事品質採点
- メール通知
- 音声録音保存
- 子どもアカウント
- AIによる相手向け自動送信
- 高度なAIエージェントが勝手に複数変更を実行

## 5. 成功指標

- 完了記録: 2タップ以内。
- LINE入力から登録確定: 原則2往復以内。
- partner raw textがrecipient UI/API/logに出ない。
- duplicate webhookでduplicate task/notificationゼロ。
- Todayは「今すぐ必要なもの」が最上段。
- 家族予定と送迎の衝突に気づける。

## 6. v6 — Scheduled household operation loop

The following is MVP, not future polish:

- Sunday weekly family schedule LINE digest
- 07:00 daily dropoff/pickup assignment to both adults
- dropoff assignee checklist + later check-in
- pickup assignee checklist + later check-in
- non-pickup adult evening checklist + later check-in
- LINE and PWA operate on the same canonical task/check-in session
- reminder suppression when already completed
- immediate reassignment notification if a scheduled message became stale

Times are household-configurable defaults, not hardcoded business constants.
Detailed behavior is normative in `17_ROUTINE_LINE_AUTOMATION.md`.


## v6 free-operation constraints

MVPは月額0円を第一運用目標とする。

- LINE Official AccountはCommunication Planを前提とし、provider reported monthly limitをhard capとして扱う。
- LINEのpush/multicast/broadcast/narrowcastはquota対象、replyはquota非対象として送信経路を選ぶ。
- `soft_budget=180`、`reserve=20`を初期値とする。ただしhard limitはprovider API値が正本。
- soft budget以降、check-in reminderはLINEを使わずin-appへfallback。
- hard limit到達後はLINE push attemptを止め、in-appへfallbackする。
- user interaction直後は有効なreply tokenがある限りreply messageを優先する。


## v6 non-workday notification rule

### 平日（祝日を除く月〜金）
- 07:00 今日の担当 + 送り担当チェック
- 08:30 送り担当check-in
- 16:00 迎え担当チェック
- 20:00 迎え担当外の夜チェック
- 20:30 迎え担当check-in
- 22:00 迎え担当外check-in

### 土日・国民の祝日/休日
平日routineを抑止し:
- 09:00 `nonworkday_morning_digest` → 夫婦2人
- 20:00 `nonworkday_checkin` → 夫婦2人

両者LINE link済みなら通常上限は **4 counted deliveries/day**。

Sunday 09:00は:
- 今日
- 翌Monday〜Sunday
を同じLINE envelopeへbundle。
旧Sunday 12:00 weekly digestは送らない。

`is_nonworkday(date)`:
- Saturday/Sunday
- OR `private.jp_holidays`に存在

祝日正本は内閣府公開CSV。checked-in fixtureをfallbackにする。
