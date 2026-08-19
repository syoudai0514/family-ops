# family-ops 実装計画 v6

作成日: 2026-08-19  
対象: Claude Code Sonnet 実装用 / GPT-5.6 Sol 独立レビュー用  
前版: `family-ops-sonnet-plan-v3`  
v3独立再レビュー: **REQUEST CHANGES / P0 0 / P1 10 / P2 8 / P3 3**

## 0. v6の結論

- 主DB/Backendは **Supabase Free**。
- 家族予定の正本は **Google Calendar shared calendar**。
- 日常入力・通知は **LINE**、全体把握・設定・履歴・詳細入力は **PWA**。
- AIは **Google Gemini無料枠**を利用し、自然文分類と夫婦間依頼の柔らかい言い換えに使う。
- 相手への依頼原文は相手から読めないprivateデータとし、共有されるのは本人確認済みの変換後テキストだけ。
- 定例家事、追加ToDo、お願い、買い物、引き継ぎ、Google Calendar予定を1つの家庭運営モデルで扱う。
- **定時LINE運用をMVPの中核に追加**。単なる通知ではなく「今日の担当確認 → チェックリスト提示 → 実績チェックイン」までをLINE/PWA両方で完結可能にする。
- PWA clientからの状態変更入口は **Edge Function only**。原子的DB更新はserver-only transaction RPCへ委譲し、browserからRPCを直接実行させない。
- client-originated mutationはすべて`operation_id`で冪等化する。
- Google Calendar createはclient-generated event ID方式に固定する。
- Google event cacheはdeleted/cancelled/untitled resourceを正しく保存できるnullable schemaにする。
- Google予定の「作成者」と「誰の予定か」を分離し、busy memberをFamily Ops metadataで管理する。
- Supabase Free前提でも、暗号化論理dumpのオフサイトバックアップとrestore drillをMVPに含める。

## 1. プロダクトの一言定義

**家族の予定・家事・お願い・買い物・引き継ぎを、誰が何をするか／したかという事実として共有し、必要なタイミングでLINEが家庭運営を思い出させてくれる家庭運営OS。**

採点、勝敗、家事品質評価はしない。

## 2. 定時LINEの初期値

時刻は**家庭設定で変更可能な初期値**。MVP timezoneは`Asia/Tokyo`固定。

| タイミング | 対象 | 内容 | 送信条件 |
|---|---|---|---|
| 毎朝 07:00 | 夫婦2人 | 今日の送り・迎え担当 | 送り/迎えのいずれかが存在 |
| 毎朝 07:00 | 送り担当 | 朝のチェックリスト | 該当taskが1件以上 |
| 毎朝 08:30 | 送り担当 | 実施チェック入力依頼 | 対象sessionが未完了/一部完了 |
| 毎日 16:00 | 迎え担当 | お迎え〜夜のチェックリスト | 迎え担当が存在し、対象taskが1件以上 |
| 毎日 20:30 | 迎え担当 | 実施チェック入力依頼 | 対象sessionが未完了/一部完了 |
| 毎日 20:00 | 迎え担当ではない大人 | その人の夜チェックリスト | 対象taskが1件以上 |
| 毎日 22:00 | 同上 | 実施チェック入力依頼 | 対象sessionが未完了/一部完了 |

### 通知疲労を避ける固定ルール

- 同じrecipient・同じminuteに複数メッセージが発生する場合は**1通へbundle**する。
  - 例: 送り担当の07:00は「今日の送り/迎え担当」＋「朝チェックリスト」を1通にする。
- 対象taskが0件ならチェックリスト通知を送らない。
- reminder前に対象が全完了ならチェックイン依頼を送らない。
- reassignmentが定時通知後に発生した場合は、双方へ即時の担当変更通知を送る。
- LINEには必ずPWA deep linkを含める。
- LINE内入力は「全部完了 / 項目ごとに入力 / 今回は不要 / PWAで開く」を基本にする。

詳細は `17_ROUTINE_LINE_AUTOMATION.md` を正本とする。

## 3. 現在確定の外部前提

- Supabase project: `family-ops`
- Region: Northeast Asia (Tokyo)
- Plan: Free
- Google Calendarを家族予定マスターにする
- LINE Messaging APIを使う
- Gemini無料枠を利用する
- React + TypeScript + Vite PWA
- iPhoneホーム画面追加を最優先
- householdはMVPで大人2人を想定するが、DBはmember identityを固定IDで扱い「パパ/ママ」という文字列を認可ロジックに使わない

## 3.1 v5で固定した運用制約

- MVPのhousehold timezoneは **`Asia/Tokyo` 固定**。timezone変更UIはMVP外。
- active adultは **最大2人**。3人目のjoinはDB transactionで拒否。
- auth user / household memberのhard deleteはMVP非対応。履歴参照を壊すため管理画面から直接削除しない。
- 月額0円運用を明示要件とし、LINE counted pushはCommunication Planのprovider limitを超えないようbudget制御する。
- Google Calendar OAuth scopesは `calendar.events` + `calendar.calendarlist.readonly` に固定。
- Google Calendar recurrenceの展開はGoogle API `events.list(singleEvents=true)`へ任せ、ローカルRFC5545 parserは実装しない。

## 4. 初期seed

### 送り
- 月: パパ
- 火: パパ
- 水: パパ
- 木: ママ
- 金: パパ

### 迎え
- 月: パパ
- 火: ママ
- 水: ママ
- 木: ママ
- 金: パパ

### 曜日準備
- 月: 昼寝用寝具、洗った上履き
- 火: 年長の体操教室用品
- 木: 英語用品
- プール用品は曜日固定seedにせずmanual/calendar-assistで追加

### 夜の主要タスク候補
- 夕食準備/配膳/食事対応/食卓片付け
- お風呂
- 洗濯
- 食器洗い
- 掃除
- 年長のスマイルゼミ
- スマイルゼミ後30分のTV/ゲーム管理

**重要:** 夜タスクの「誰が担当か」は上記説明だけから勝手に固定しない。初期設定画面で夫婦が決める。定時LINEは当日の`task_instances.planned_assignee_id`を正本として対象者を決める。

## 5. 読み順

1. `00_PRODUCT_AND_SCOPE.md`
2. `01_ARCHITECTURE.md`
3. `02_UX_AND_SCREENS.md`
4. `03_DOMAIN_AND_DATA_MODEL.md`
5. `04_SECURITY_RLS_PRIVACY.md`
6. `05_AI_GEMINI.md`
7. `06_LINE_INTEGRATION.md`
8. `07_GOOGLE_CALENDAR.md`
9. `08_RECURRING_TASKS_AND_RULES.md`
10. `09_API_AND_EDGE_FUNCTIONS.md`
11. `17_ROUTINE_LINE_AUTOMATION.md`
12. `18_MUTATION_CONTRACT_MATRIX.md`
13. `10_WORK_PACKAGES.md`
14. `11_TEST_AND_ACCEPTANCE.md`
15. `12_OBSERVABILITY_BACKUP_COST.md`
16. `13_OPEN_DECISIONS.md`
17. `14_EXTERNAL_SETUP_STEPS.md`
18. `15_DDL_CONTRACT.md`
19. `16_REVIEW_DISPOSITION.md`
20. `SONNET_EXECUTION_PROMPT.md`
21. `SOL_REVIEW_PROMPT.md`
22. fixtures

## 6. 実装開始ゲート

- WP0は開始可。
- **WP1 migrationはv6独立SOLレビューでP0/P1=0になるまでHOLD。**
- v6のみを設計正本とし、v1/v2/v3/v4/v5を実装判断に使わない。
- Sonnetは本文中の固定方針を別案へ変更しない。
- secret、OAuth consent、LINE Official Account、Google Cloud設定など人間しかできない作業だけ質問する。


## v6 implementation gate

v5独立レビュー結果は `REQUEST CHANGES / P0 0 / P1 8 / P2 8 / P3 2`。
v6で全P1を閉じ、WP1開始条件を **独立SOLレビューでP0=0/P1=0** に固定する。

v6 fixed:
- Supabase Edge Function `verify_jwt` matrix + normative `supabase/config.toml`
- LINE月200通をFamily Ops側hard capにするatomic quota reservation
- LINE retry key 24h境界 + `delivery_unknown`
- Google recurring occurrence identity
- normalized calendar busy classification
- Google writable calendar accessRole / PATCH contract
- fresh household evening routine setup
- 土日祝は09:00に夫婦へ予定、20:00に夫婦へ入力依頼
- 日曜09:00へ翌週予定を同梱し、旧Sunday 12:00 weekly digestは廃止
- 日本の祝日は内閣府公開データを正本として判定
