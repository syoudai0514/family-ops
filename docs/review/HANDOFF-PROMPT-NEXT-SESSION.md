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

## 最優先タスク: 本番の定例通知が壊れています

**症状（ユーザー報告）**: 「朝9:00しか来なくなった。夜も来ない。」

### 分かっていること

`server_tx_create_household` が投入する既定スケジュール:

| kind | 時刻 | 適用日 |
|---|---|---|
| daily_assignment | 07:00 | 平日 |
| dropoff_checklist | 07:00 | 平日 |
| dropoff_checkin | 08:30 | 平日 |
| pickup_checklist | 16:00 | 平日 |
| nonpickup_evening_checklist | 20:00 | 平日 |
| pickup_checkin | 20:30 | 平日 |
| nonpickup_evening_checkin | 22:00 | 平日 |
| **nonworkday_morning_digest** | **09:00** | **土日祝のみ** |
| nonworkday_checkin | 20:00 | 土日祝のみ |

**09:00 は「土日祝」の時刻です。平日は 07:00。**
つまり平日にも 09:00 だけが来ているなら、システムが**毎日を休日として扱っている**可能性があります。

判定は `private.fn_is_nonworkday(date)` = `土日 OR private.jp_holidays に行がある`。
`dispatch-routine-automation` が毎分走り、`household_routine_schedules` から
`enabled AND local_time = 現在時刻` の行を、休日フラグで絞って発火させます。

### 診断手順（この順に、本番Supabaseへ read-only で）

Supabase MCP（`mcp__Supabase__execute_sql`）が使えます。プロジェクト ref は `dnlqxjpjpkxnfgculzip`。
**まず読むだけ。書き込みはユーザーの承認を取ってから。**

```sql
-- ① スケジュール行が生きているか（一番ありそう）
select schedule_kind, local_time, enabled, schedule_version
from public.household_routine_schedules order by local_time;

-- ② 祝日テーブルが汚染されていないか（毎日が祝日になっていないか）
select count(*), min(local_date), max(local_date) from private.jp_holidays;
select local_date from private.jp_holidays
where local_date between current_date - 14 and current_date + 14 order by local_date;

-- ③ LINE無料枠を使い切っていないか（今は月末。soft_budget=180 / hard cap=200）
select * from private.line_quota_state;

-- ④ タスクが生成されているか（夜の通知は「未完了が0件なら送らない」仕様）
select scheduled_date, count(*) from public.task_instances
where scheduled_date >= current_date - 7 group by 1 order by 1;

-- ⑤ cron が実際に動いているか
select jobname, schedule, active from cron.job order by jobname;
select jobname, status, start_time from cron.job_run_details
order by start_time desc limit 20;
```

### 有力な仮説（①〜④に対応）

- **① スケジュール行が無効化された** — 平日kindが `enabled=false` になっていれば、平日は何も来ず、
  土日だけ 09:00 が来る。ユーザーが「9:00しか来ない」と感じる説明として最も素直
- **② `private.jp_holidays` の汚染** — 後述のとおり `sync-jp-holidays` は cron 未登録なので、
  もし手動で一度走らせて CSV のパースを誤っていれば、全日が祝日として入り得ます
- **③ 月間200通の枠切れ** — 今日は月末。`soft_budget=180` を超えると `reminder` 優先度の送信が
  先に止まります。**PWAにWeb Pushが無いので、枠が尽きると本当に何も届きません**
- **④ 夜は仕様どおりの抑止** — `17_ROUTINE_LINE_AUTOMATION.md` #6-7 に
  「20:00時点で0件なら通知なし」「22:00 check-inは未完了がある時だけ送る」とあります。
  `materialize-recurring` が止まっていればタスクが0件になり、夜は正しく沈黙します

**①〜⑤を確認するまで、修正を始めないでください。** 仮説のまま直すと別の壊し方をします。

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
| **E** | **LINE無料枠200通と定例通知の構造的衝突。** 平日最大8通/日で月165〜210通。`soft_budget=180`に定例だけで到達。枠が尽きるとin-appフォールバックだが**PWAにWeb Pushが無い**ので何も届かない。`08:30 / 20:30 / 22:00` を既定オフにするだけでも効く | 設定変更 |
| **F** | LINEリッチメニューが未公開（richmenu APIの呼び出しがリポジトリに存在しない）。ユーザーは「メニュー」と打つ必要がある | 小 |
| **G** | 設定11項目のうち本当の設定は4つ。`Google予定の変更確認` は未処理の作業キューなのでTodayへ | 中 |

**今回の通知障害は E と地続きです。** 診断で③（枠切れ）が当たっていたら、Eは「将来のリスク」ではなく
「今起きている障害」なので、最優先で対処してください。

## 最初にやってほしいこと

1. 上の3ファイルを読む
2. 診断クエリ①〜⑤を**read-onlyで**実行し、結果をユーザーに報告する
3. **原因が確定してから**、修正案を出して承認を取る
4. 本番のcron・DBを書き換える操作は、必ず事前にユーザーの承認を取る

ユーザーは日本語で対話します。技術レビューではなく、
**「普通の家族が毎日使いたいと思うか」**を基準に判断してください。

---
