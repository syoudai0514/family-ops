# 【おうちノート / Family Ops｜REQUIREMENTS & UX INDEPENDENT REVIEW｜NO IMPLEMENTATION】

@GitHub

repository:
`syoudai0514/family-ops`

canonical branch:
`main`

review target:
`docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`

source-of-truth policy:
`docs/requirements/README.md`

==================================================
0. IMPORTANT
==================================================

今回は**独立設計レビューのみ**です。

以下は禁止です。

- code変更
- CSS変更
- migration作成/変更
- commit
- PR作成
- Supabase変更
- Edge Functions deploy
- cron変更
- Vercel deploy
- 本番データ変更

最初にCURRENT GitHub `main` をfresh readしてください。
古いPR説明や過去の会話だけを前提にせず、CURRENT実装・CURRENT docsとreview targetを比較してください。

GitHub上の `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md` を**最初から最後まで通読**してからレビューを開始してください。添付ファイルや過去のコピーではなく、レビュー対象PRのhead（merge済みならCURRENT `main`）にあるcanonical pathを使用してください。

==================================================
1. PURPOSE
==================================================

家庭運営アプリ「おうちノート / Family Ops」の次期要求・UXを、実装者とは独立した立場でレビューしてください。

目指しているものは単なる家事チェックリストではなく、

**LINEを中心に、家族の日々のタスク・お願い・担当調整・共有・引き継ぎ・予定・イベント準備・実績記録を、ほとんど負担なく回せる家庭運営OS**

です。

特に、以下の両立を最重要視しています。

1. **通常ケースは極めて少ない操作で終わること**
2. **複雑な例外も必要なときだけ正確に扱えること**

レアケースを支えるために、普段のLINE/PWAが見づらい・入力しづらい設計になっている場合は厳しく指摘してください。

==================================================
2. PRODUCT PRINCIPLES TO CHALLENGE
==================================================

以下は仕様書の前提ですが、妥当でない場合は遠慮なく否定してください。

- LINEを日常の主導線、PWAを詳細/一括/設定の補完にする
- 自分の今日タスクはLINE本文に全部表示する
- scheduled pushは朝/夜中心、重要な新規事項は随時通知
- 通常の実績入力は `全部やった / 大体やった / 個別で答える`
- 予定担当と実施者を分離する
- 担当外サポートは自動判定するが、LINEでは恩着せがましく強調しない
- 共有する相手と、作業担当を分離する
- AIは候補を作るが、重要な担当変更や人が確定した値を勝手に確定/上書きしない
- 園画像の「明記された事実」と「AI推測」を分離する
- Google Calendarは予定中心、おうちノートは家庭作業中心
- 1人LINEテストモードから2人本番運用へ同じ業務モデルで移行する

==================================================
3. REVIEW SCOPE
==================================================

以下を横断してレビューしてください。

### A. Daily UX / LINE noise

- 朝6:30、土日祝9:00、夜20:30の構成は妥当か
- 自分のタスクをLINEに全部載せても読めるか
- `まず確認 → 例外 → 共有 → タスク` の優先順は自然か
- 随時通知と定時通知の境界が破綻していないか
- 依頼/共有/担当変更が通知に埋もれないか
- 同一操作の通知まとめ方が適切か
- `相手がやった` を強調しない方針は二重対応防止と両立するか

### B. Task / assignment state model

- 基本ルール
- 期間付き曜日ルール
- override
- 個別合意
- 担当未定
- 誰でもOK
- claim
- 予定担当
- 実施者
- 担当外サポート

これらが矛盾なく共存できるか確認してください。

特に、**未来の基本ルール変更時に個別合意を守りつつ、双方へ確認する設計**が過剰に複雑ではないか、または逆に不足していないかを評価してください。

### C. Request / assignment negotiation

以下の状態遷移を具体的にwalkthroughしてください。

- やる
- 難しい
- コメント付きで難しい
- 確認してみる
- 相談する
- 担当調整中
- 返答期限超過
- 依頼内容変更
- 了承後の取消
- 事前調整済み

`確認してみる` は自分側の予定調整、`相談する` は相手との代替案相談です。
この違いがユーザーに自然に理解できるかも評価してください。

### D. Actuals / history

以下が集計上破綻しないか確認してください。

- 全部やった
- 大体やった（子タスク詳細集計外）
- 個別で答える
- 未入力
- できなかった
- 今回不要
- 再予定
- 複数人実施
- 担当外サポート
- 誰でもOKをclaimして実施
- 後日訂正

特に、**入力を楽にするほど実績の正確さが下がる問題**に対して、このBaselineの落とし所が妥当かを厳しく評価してください。

### E. Event / preparation

- イベント全体の責任者を置かない判断
- 各準備ToDoの担当
- 待ち / 次回確認日
- 日付変更時の準備再配置
- event-level notificationを節目だけにする方針
- 複雑なtask dependency DAGを現時点で持たない判断

をレビューしてください。

### F. Google Calendar

- Googleを時間予定中心にする境界
- ToDoを必要時のみGoogle表示する設計
- Google側日時変更
- Google側削除
- duplicate link
- human-confirmed valueとのconflict

で、sync loop、重複、silent overwrite、履歴破壊のリスクを指摘してください。

### G. Nursery / Codmon image intake

特に重点レビューしてください。

家庭前提:
- マサキ: 年長 / すだちぐみ
- ウタノ: 3歳クラス / ゆきぐみ
- 別保育園

対象:
- 園掲示物写真
- 月間予定表
- コドモンのスクリーンショット
- 複数画像
- 定例予定
- 中止/延期通知
- 提出物
- URL/QR

確認事項:

- 子/園/クラス自動判定の安全性
- 他クラス/他児童情報の除外
- OCR/vision誤読時のUX
- 明記情報 vs AI推測の分離
- 園別の確認済みルール学習
- 既存予定との重複/変更/競合
- 元画像保持とprivacy
- 大量月間予定表から重要項目を優先する方式
- QR/URL抽出の安全性

### H. LINE ↔ PWA

- deep linkで対象作業をそのまま引き継げる設計になっているか
- LINEとPWAで同時編集した時のconflict
- PWA保存後に自分宛LINEを返さない方針
- 一覧操作でreload/scroll resetを起こさない要件

### I. One-user test mode

妻を実LINEユーザーとして追加する前に、同じLINEでパパ/ママ双方を疑似操作する要件があります。

- test modeが本番モデルを汚さないか
- operatorとsimulated actorを分離できるか
- analyticsからtest dataを除外できるか
- 2人本番へ移行時に再設計不要か

を確認してください。

==================================================
4. CURRENT IMPLEMENTATION GAP REVIEW
==================================================

CURRENT `main` を確認し、review targetのBaselineと現実装が衝突する箇所を特定してください。Baseline自体がopen PR上にある場合は、そのPRのhead版を要求仕様として読み、実装比較はCURRENT `main` に対して行ってください。

特に既存の:

- Today / Daily UI
- routine tasks
- requests
- handovers
- task completion / history
- LINE Flex / conversation handling
- scheduled LINE notifications
- Google Calendar sync
- recurrence / assignment model
- PWA navigation

について、

1. そのまま活かせる
2. 拡張すればよい
3. 方針が衝突するため再設計が必要

を分類してください。

ただし今回は**修正しないでください**。

==================================================
5. REQUIRED REVIEW OUTPUT
==================================================

最初に結論だけ短く示し、その後根拠を詳細化してください。

各指摘は必ず以下で分類してください。

- `BLOCKER`
- `HIGH`
- `MEDIUM`
- `LOW`

各指摘の形式:

**問題**
→ **実際に起こる家庭内シナリオ**
→ **なぜ問題か**
→ **推奨修正**

単なる好みや抽象的な感想ではなく、具体的な家庭内操作で説明してください。

また、以下を必ず出してください。

### 5.1 Contradiction matrix

仕様内で相互に矛盾・緊張する要件を列挙してください。

例:
- LINEに全部出す vs 通知/可読性
- 実績を正確に残す vs 入力を最短にする
- 自動推定 vs 人の確認回数

### 5.2 Missing scenario list

この仕様でまだ決まっていない、実装前に決めるべき現実的シナリオを重要度順に列挙してください。
ただし「何でも念のため」と無限に増やさず、実運用で起こる可能性・事故影響が高いものを優先してください。

### 5.3 Simplification opportunities

同等の価値を保ちながら、状態・画面・通知・操作を減らせる箇所があれば提案してください。

### 5.4 Data-model pressure points

DB schemaそのものは実装しなくてよいですが、要求を実現する上で特に危険な概念境界を指摘してください。

例:
- task definition vs occurrence
- assignment vs claim vs actual performer
- source fact vs AI inference
- event vs task group
- request vs assignment-change negotiation

### 5.5 Final verdict

最後に必ず、

- `GO`
- `GO WITH CONDITIONS`
- `NO-GO`

のいずれかで、**このRequirements Baselineを詳細設計フェーズへ進めてよいか**を判定してください。

`GO WITH CONDITIONS` / `NO-GO` の場合、詳細設計開始前に直すべき項目を明示してください。

==================================================
6. REVIEW POSTURE
==================================================

この仕様を肯定することが目的ではありません。

- 過剰設計
- 状態爆発
- 通知疲れ
- 家庭内での心理的圧
- 入力負荷
- 二重対応
- silent overwrite
- AI誤判定
- image privacy
- test data contamination

が起きる設計なら、遠慮なく止めてください。

一方、問題がない箇所まで変更案を出す必要はありません。

**実際に夫婦が毎日使い続けられるか**を最優先に独立評価してください。
