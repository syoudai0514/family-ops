# 次セッションへの引き継ぎプロンプト

以下をそのままコピーして、新しいセッションの最初のメッセージとして貼ってください。
（`---` の内側だけをコピー）

---

あなたには `syoudai0514/family-ops`（おうちノート）を引き継いでもらいます。
家族の予定・家事・お願い・買い物・引き継ぎを扱う、LINE + PWA + Supabase のプロダクトです。

## 前提: このリポジトリの性質を先に理解してください

**AIによる開発で「足し算」しか起きず、肥大化しています。**

```
マイグレーション      207   （うち drop を含むのは 3 ファイルだけ）
Edge Function        100
SQLテスト            105
Webテスト             60ファイル / 178テスト
```

設計レビューは5ラウンド回っていますが、**全部が「要件を満たしているか」を問うており、
「多すぎないか」を問うたものが1つもありません。** その結果:

- Todayが18セクション、`+` ボタンが10択、家事の結果が7択、買い物が6状態
- 設定11項目のうち2つは「アプリの概念の説明ページ」

**あなたが足す側に回ると、この問題を悪化させます。** 以下を守ってください。

1. **スクリーンショットを見てから直す。** このリポジトリのテストは canonical なデータ契約を
   検証していて、**人が画面で何を見るかを検証していません**。直近で見つかった実バグ5件は、
   SQLテスト105本 + Webテスト170本を全部通過していました。コードだけ読んでも見つかりません。
2. **足す前に、消せないか考える。**
3. **テストが古い仕様を守っていることがある。** 消さず、新しい意図に付け替える。
4. **正本（`docs/design/current/` と `docs/requirements/`）を直さずに実装だけ簡素化しない。**
   READMEが「Accepted ADR → Requirements → CURRENT設計 → 実装」を正本と宣言しているので、
   実装だけ変えると次のレビューで「仕様違反」として戻されます。
5. **DB・マイグレーション・SQLテストには最後に触る。** 表示層で直せることを先に全部やる。

## まず読むもの（この順で）

1. `docs/review/HANDOFF-UX-FIXES-2026-09-15.md` — 直近の修正内容・根拠・残件
2. `docs/review/FAMILY-OPS-INDEPENDENT-PRODUCT-UX-REVIEW-2026-09-14.md` — UXレビュー全文
3. `README.md` — 正本の優先順位

ブランチ: `claude/family-ops-ux-review-em3wns`（`main` から4コミット先行、push済み）

## 訂正済み: 本番の通知障害は原因が確定しています（2026-09-29）

> **この節の旧版は誤りでした。** 旧版は「09:00は土日祝専用の時刻だから、システムが毎日を
> 休日扱いしている」「LINE無料枠の枯渇」などを仮説にしていましたが、本番DBの読み取り診断で
> **どれも該当しないと確認されています。** 旧ルーチン通知（07:00/16:00/20:00系）は
> 2026-09-04 から `daily_brief_v2` ゲートで抑止されており、現行の配信系統は別物です。

**症状**: 「朝9:00しか来なくなった。夜も来ない。」

**原因（本番DBとリポジトリ main の両方で確認済み）**:
`20260916090000_codmon_daily_submission` が `private.fn_line_preference_column_for_type()` を
全文書き直した際、直前の版にあった5種類を落としました。

```
daily_brief.v2             → daily_assignment_line   ← 朝夜のブリーフ
request.followup_requested → request_line
request.followup_declined  → request_line
shopping.handled_neutral   → shopping_minor_line
shopping.reopened_neutral  → shopping_minor_line
```

`private.fn_enqueue_line_notification()` はこの関数が NULL を返すと**何も起こさず return** します。
アプリ内通知は作られ、エラーも出ず、LINEの送信キュー（`notification_outbox`）にだけ入りません。
9/16 06:30 の朝ブリーフが最後で、同日夜以降は 0 件でした。09:00 に届いていたのは、
新しい本体が唯一マッピングしていた `codmon.deadline`（コドモン期限リマインド）です。
**09:00 は土日祝の時刻ではなく、毎日届くコドモンの時刻でした。**

切り分けの結果（本番の読み取り診断）:

| 仮説 | 結果 |
|---|---|
| 平日スケジュール行の無効化 | 該当せず（9行とも enabled。そもそも旧系統は抑止中で通知に使われない） |
| `jp_holidays` の汚染 | 該当せず（逆に **0件で空**） |
| LINE無料枠の枯渇 | 該当せず（9月は 73 / 200 通、`failed` も 0 件） |
| 夜の抑止（タスク0件） | 該当せず（毎日 9〜23 件生成、夜ブリーフも毎日発火） |

**修正**: `supabase/migrations/20260929140000_restore_line_preference_mappings.sql`
（5種類を復元し `codmon.deadline` を維持）＋ `tests/sql/94_line_preference_mapping_regression.sql`。
ローカルの一時PostgreSQL 16で、**全214マイグレーション適用 → テストが修正前は
`daily_brief.v2 maps to NULL` で落ち、修正後は通る**ことと、隣接するSQLテスト5本が通ることを
確認済みです。**本番への適用は未実施です。** 適用にはユーザーの承認が必要です。
適用後は次の夜 20:30 から自動復活します（ブリーフは約8時間で失効するので過去分の再送は不要）。

**再発防止**: この事故は `create or replace` で関数の全文を書き直す方式が原因です。マッピングを
足すときは必ず既存の行を全部残し、94 番のテストに種類を追加してください。

**別件（今回の障害の原因ではない）**: `private.jp_holidays` が空です。祝日を同期する
`sync-jp-holidays` が cron に無いことが理由と考えられます（次節）。9/21〜9/23 が平日扱いで、
朝ブリーフが 06:30 に飛んでいました。

## 確定している別のバグ: 5つのworkerがcronに登録されていません

`.github/workflows/configure-production-cron.yml` が登録しているのは6本だけです。

```
登録済み: materialize-recurring / process-line-inbox / process-pending-actions
          dispatch-routine-automation / send-notifications / process-family-ops-calendar-outbox

未登録:   sync-jp-holidays              → 祝日テーブルが更新されない
          enqueue-periodic-google-sync  ┐
          process-google-sync           ┘→ Googleカレンダーが同期されない
          renew-google-watch            → Googleのpushチャンネルが失効したまま
          cleanup-expired-private-data  → 期限切れデータが消えない
```

### ★ 重要: 前セッションのカレンダー修正は「半分」です

前セッションで「Googleカレンダーの予定が届かない」問題を修正しましたが、**不完全でした。**

- 直したこと: `ensure-calendar-fresh` の**呼び出し口がPWAに存在しなかった**ので追加した
  （関数自身のコメントに「PWAがカレンダー画面を開いたときに呼ばれる」と書いてあるのに未配線だった）
- **見落としていたこと**: `ensure-calendar-fresh` は
  `server_tx_ensure_calendar_fresh` → `private.google_enqueue_sync()` で**キューに積むだけ**。
  それを処理する `process-google-sync` が **cron未登録**なので、
  **積まれたジョブは永久に処理されません。**

PWA側の修正（呼び出し口・警告バナー・書き込み先ラベル）自体は正しく、必要です。
ただし**それだけでは予定は届きません。** cron登録が残り半分です。

`process-google-sync` と `enqueue-periodic-google-sync` を
`configure-production-cron.yml` に追加してください。既存6本と同じ書き方で足せます。
**この変更は本番のcronを書き換えるので、必ずユーザーの承認を取ってから実行してください。**

## 直近で完了している作業（`git log` で確認可）

ブランチ `claude/family-ops-ux-review-em3wns` に4コミット。
web 60ファイル / 178テスト green、lint exit 0、typecheck clean。**DB・マイグレーションは未変更。**

- `6eb4d29` 画面に出ていた実バグ5件
  - 履歴が未来を表示（`.lte` 欠落 + UTC/JST混在）
  - Googleカレンダーで週ビューと設定が矛盾（別々の信号を見ていた）
  - 書き込み先カレンダーが「読み取り対象」と表示
  - フィルタchipが全部「選択中」に見える（CSS。履歴・チェックイン・conciergeの3画面に影響）
  - Todayに英語のenum `day` が生表示
  - 文言: ログイン画面だけ `Family Ops`、`監査情報`、日本語文中の英語 `truth`、秒つき時刻
- `aee0115` Today: KPIタイル4個を削除、相手カードの `完了 N件` を削除、朝/日中の並び替え
- `da245cb` 買い物: 未着手を先頭に・完了は折りたたみ / 設定: 死んだ招待カード・レイアウト崩れ
- `fd074da` 引き継ぎ書

**`aee0115` の「相手の `完了 N件` 削除」は判断が入っています。**
覆す場合は `HANDOFF-UX-FIXES-2026-09-15.md` §2-2 の4つの出典を読んでから。

## 残件バックログ（優先順）

| | 内容 | 規模 |
|---|---|---|
| **A** | PWAの `+` が10択を要求。思想「分類させない」と正反対。入力欄1つにする | 表示層のみ |
| **B** | conciergeが4画面（results と confirm がほぼ同じリストを2回）。インライン1画面へ | 表示層のみ |
| **C** | 家事の結果7択 / 買い物6状態。**DBとSQLテストに深く埋まっている**（`not_needed_this_occurrence` は11ファイル）。正本を先に直すこと | DB |
| **D** | 初期設定8ステップのゲート（送迎14セルグリッド含む）。ステップ表示も `2/8` と `4/7` で不整合 | 中 |
| **E** | ~~LINE無料枠と定例通知の衝突~~ **旧系統の話で、現状は該当しません。** 旧ルーチン通知は 9/4 から抑止中。現行のブリーフは朝夜×2人で月100〜120通前後（推定）で200通に収まる見込み。ただし通知復旧後に実使用量を確認すること。PWAにWeb Pushが無い点は事実 | 監視 |
| **F** | LINEリッチメニューが未公開（richmenu APIの呼び出しがリポジトリに存在しない）。ユーザーは「メニュー」と打つ必要がある | 小 |
| **G** | 設定11項目のうち本当の設定は4つ。`Google予定の変更確認` は未処理の作業キューなのでTodayへ | 中 |

## 最初にやってほしいこと

1. 上の3ファイルを読む
2. **通知障害の修正マイグレーション**（`20260929140000_restore_line_preference_mappings.sql`）の
   内容をユーザーに見せ、**本番へ適用してよいか承認を取る。** 適用は承認後のみ。
   適用後は、次の夜 20:30 に朝夜のブリーフが LINE に届くことを、`private.notification_outbox` に
   `type='daily_brief.v2'` の新しい行が入ったかで確認する（読み取りのみ）
3. `sync-jp-holidays` などの cron 未登録 5 本の扱いを、ユーザーと相談する
4. 本番のcron・DBを書き換える操作は、必ず事前にユーザーの承認を取る

ユーザーは日本語で対話します。技術レビューではなく、
**「普通の家族が毎日使いたいと思うか」**を基準に判断してください。

---
