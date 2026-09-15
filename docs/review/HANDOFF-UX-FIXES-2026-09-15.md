# 引き継ぎ: おうちノート UX修正 第1〜3弾

- 日付: 2026-09-15
- ブランチ: `claude/family-ops-ux-review-em3wns`
- 基点: `76b746d`（レビュー文書のみ）→ 現在 `da245cb`
- 規模: 25ファイル / +400 −143
- 検証: **web 60ファイル / 178テスト green、lint exit 0、typecheck clean**
- DB・Edge Function・マイグレーションへの変更: **なし**（207個のマイグレーションと105本のSQLテストは一切触っていない）

このドキュメントは、**他のAI（GPT等）や人が、この変更を理解して続きを作業するため**のものです。
背景の詳細は `docs/review/FAMILY-OPS-INDEPENDENT-PRODUCT-UX-REVIEW-2026-09-14.md` にあります。

---

## 0. 最初に読むべきこと — なぜこの変更が必要だったか

**修正した5つのバグは、全て既存のテスト（SQL 105本 + Web 170本）を通過していました。**

理由は単純です。既存のテストは **canonicalなデータ契約** を検証しています。

- `.gte` だけで `.lte` が無くても、データは正しい
- フィルタchipが全部同じ色でも、状態管理は正しい
- 買い物の状態遷移も正しい

**「人が画面を見て何が起きるか」を検証しているテストが1本もありませんでした。**

だから207回のマイグレーションと5ラウンドの設計レビューを経ても、
「履歴に3ヶ月先の未来が表示される」「アプリが自分自身と矛盾する」が残り続けました。

**発見の手段は実機スクリーンショット15枚です。コードを読むだけでは1件も見つかりませんでした。**

### この先に作業する人への警告

このリポジトリは、AIに作業を依頼すると**足し算しか起きない構造**になっています。

| 罠 | 実態 | 対処 |
|---|---|---|
| **正本の宣言** | READMEが「Accepted ADR → Requirements → CURRENT設計 → 実装」を正本と宣言。1467行の要件が全て「満たすべきもの」 | 簡素化するなら、**先に設計文書を直す**。実装だけ直すと次のレビューで「仕様違反」として戻される |
| **テストが古い仕様を固定** | 7択の結果は11ファイル、concierge 3画面フローは17ファイルに埋まっている | テストを消す判断が必要。**テストが正しいのではなく、テストが古い仕様を守っている**場合がある |
| **レビューが全部「足りているか」** | ROUND1〜5、`remediation` の次に `hardening` | 「多すぎないか」を問う人を必ず1人置く |

**この変更では実際にテストを2本書き換え、1本を全面的に付け替えました**（§3参照）。
同じ判断が必要になったら、消すのではなく**新しい意図に付け替えて**ください。

---

## 1. 修正したもの（コミット単位）

### `6eb4d29` — 画面に出ていた実バグ5件

#### 1-1. 履歴が「未来」を表示していた ★最重要バグ

**症状**: 今日が 2026-09-14 なのに、履歴の先頭が **2026-12-10**。以下12/9、12/8…と未来へ並ぶ。

**原因**: `apps/web/src/features/history/useHistoryData.ts`

```ts
// 修正前
const startDate = windowStartDate();          // 今日 − 14日
  .gte('scheduled_date', startDate)           // 下限だけ。上限がない
  .order('scheduled_date', { ascending: false })  // 降順
```

`HISTORY_WINDOW_DAYS = 14` が定義されているのに、**開始側にしか使われていなかった**。
定例タスクは数ヶ月先まで materialize されるため、下限だけだと未来が全部入り、
降順ソートで**一番遠い未来が先頭**に来る。

実害: 昨日の記録に到達するには未来の送迎カードを200枚以上スクロールする必要があり、
**履歴機能が事実上使用不能だった**。

**修正**:
```ts
const endDate = todayIsoDate();               // JST
const startDate = windowStartDate(endDate);
  .gte('scheduled_date', startDate)
  .lte('scheduled_date', endDate)             // ← 追加
```

副次的に、`windowStartDate()` が `toISOString()`（UTC）で計算していた問題も直しました。
`lib/date.ts` 自身が「端末ローカル日付は誤り」とコメントで警告しているのに、
履歴だけがその規約に違反していました。両端ともJST基準に統一。

- テスト追加: `features/history/useHistoryData.window.test.ts`
- `test/supabaseMock.ts` に `.lte` を追加（モックが未対応だった）

#### 1-2. Googleカレンダーで、アプリが自分自身と矛盾していた ★最重要

**症状**:
- 週ビュー: 「Googleカレンダーの同期が古いか、**再接続が必要です。**」
- 言われた通り設定へ行くと: 「Google Calendar **✓ 接続済み**」
- ボタンも「再接続」ではなく「接続」

**完全な行き止まり。** そして月ビューの全日が「予定はありません」。

**原因**: 2画面が**別々の信号**を見ていた。

| 画面 | 参照 | 意味 |
|---|---|---|
| `WeekView.tsx` | `schedule.calendar_stale` | サーバ側の同期の鮮度 |
| `CalendarIntegrationSettings.tsx` | `row.active` / `row.reauth_required` | 接続・認証フラグ |

**同期が止まっている**ことと**認証が切れた**ことは別の障害で、別の対処が必要。
片方だけ true のとき、2画面が正反対を言う。

**根本原因**: `supabase/functions/ensure-calendar-fresh/` は**最初から存在していた**。
そのヘッダコメントにこう書いてあります。

> called when the PWA opens the calendar view (or ~10m before the Sunday weekly digest)
> so a stale cache gets a coalesced sync enqueued

**しかしPWAからの呼び出しが一度も書かれていませんでした。**
`grep -rn "ensure-calendar-fresh" apps/web/` の結果はゼロ件。
`lib/edgeFunctions.ts` にも未登録。

つまり**誰も新しいデータを要求していなかった**ので、キャッシュは古いまま固定され、
週ビューは永久に `calendar_stale` を報告し続けていました。

**修正**:
- `lib/edgeFunctions.ts` に `ensureCalendarFresh` を登録
- **新規** `features/planning/useCalendarFreshness.ts` — 欠けていた呼び出し口
- `WeekView.tsx` / `MonthView.tsx` — カレンダー画面を開いたら自動で同期要求（設計の意図どおり）
- **新規** `features/planning/CalendarStaleBanner.tsx` — 警告に `[今すぐ同期する]` を付ける
- `CalendarIntegrationSettings.tsx` — **同じ再同期操作**を設定にも置き、2画面が同じ対処を提供する

警告の文言も変更しました。「再接続が必要です」は**間違った場所へ誘導する**ので、
ユーザーが実際に観測できる事実（予定が届いていない）を述べ、
再接続は**同期を試した後のフォールバック**としてのみ案内します。

> サーバ側は `p_stale_minutes: 5` で coalesce するので、画面を開くたびに呼んでも安全です。

#### 1-3. 書き込み先カレンダーが「読み取り対象」と表示されていた

**症状**:
```
○ syoudai0514@gmail.com （接続中・読み取り対象）
● おうちノート          （接続中・読み取り対象）
```
両方同じラベル。**ラジオボタンが何を選んでいるのか画面から分からない。**

**原因**: サフィックスが `is_family_write_target` を一切見ていなかった。

**修正**: `calendarRowLabel()` として抽出し、書き込み先を明示。
- 書き込み先 → `（家族カレンダー・ここに書き込みます）`
- それ以外 → `（読み取りのみ）`
- 障害は役割より優先（停止中 / 再認証が必要）

テスト追加: `features/settings/calendarRowLabel.test.ts`

#### 1-4. フィルタchipが全部「選択中」に見えていた

**症状**: 履歴の `すべて / 定例作業 / 予定 / お願い` が4つとも濃い緑。どれが効いているか不明。

**原因**: `App.css`
```css
button { background: var(--color-accent); }              /* グローバル既定が既に塗り */
.filter-chips button { min-height: 36px; border-radius: 999px; }  /* 背景の指定なし */
.filter-chips button.active { background: var(--color-accent); }  /* = 既定と同じ色 */
```

**修正**: 未選択を中立のアウトラインに戻し、`.active` だけが塗りを持つようにした。

> **影響範囲**: `.filter-chips` は履歴だけでなく **CheckinPage**（今夜 / 朝の未入力 / 昨日分修正 / 予定外実績）
> と **ConciergePage** でも使われています。1箇所の修正で3画面が直ります。

#### 1-5. Todayに英語のenum「day」が出ていた

**症状**: 未読の引き継ぎカードに `day — 【言語通級】…`

**原因**: `Today.tsx` が `{handover.period}` を生で描画。
`HandoverPeriod = 'morning' | 'day' | 'evening' | 'other'`

**修正**: 日本語ラベル表は `Handovers.tsx` に**既に存在**していました（`PERIOD_LABELS`）。
export して Today で共有するだけ。

#### 1-6. 内部用語・製品名の流出

| 場所 | 修正前 | 修正後 |
|---|---|---|
| `SignIn.tsx` | `<h1>Family Ops</h1>` ← **新規ユーザーが最初に見る画面** | `おうちノート` |
| `SignIn.tsx` | 「…共有する家庭運営OS。」 | 「…ひとつにまとめる共有ノート。」 |
| `WeekView.tsx` | 予定ソース表示 `Family Ops` | `おうちノート` |
| `CalendarIntegrationSettings.tsx` | 「Family Ops予定」「Family Opsミラー」 | 平易な日本語に書き換え |
| `HistoryPage.tsx` | `監査情報` / `登録時刻` | `記録の詳細` / `記録した時刻` |
| `ConciergePage.tsx` | 「実績日は作業した日の**truth**で…」 ← 日本語文中に英語 | 「確認するまでは、登録も家族への送信もしません。」 |
| `lib/date.ts` | `formatDateTimeJa` が秒を出力（`18:20:00`） | 秒を削除（`18:20`） |

> `index.html` の `<title>`、manifest、apple-mobile-web-app-title は**元から全部おうちノート**でした。
> ログイン画面だけが `Family Ops` だった＝**第一印象だけが開発コードネーム**という状態。

---

### `aee0115` — Today: 相手の採点をやめ、KPIタイル行を削除

#### 2-1. 4つの数値タイルを削除

実機の朝の画面はこうでした。

```
要対応 0      残り 1
待ち  0      明日影響 1
```

**4つのうち3つがゼロ。** 第一画面の半分が「何も起きていません」という報告に使われ、
その日の唯一の実タスク（朝ごはん 2/3）は**画面外**。

削除の根拠は、このプロダクト自身の宣言です。

- `00_PRODUCT_AND_SCOPE`: 「家庭を仕事のプロジェクト管理のようにしない」
- `02_UX_AND_SCREENS §1`: 「**Todayはdashboardではなく「次に何をすべきか」**」

家庭の状態を4つのKPIに要約する行は、定義上ダッシュボードです。

**情報は失われていません。** 各セクションの見出しが元から `n件` を持っています。

付随して削除: `jumpToSection()`、`attentionCount`、`remainingCount`、素のアンカー `<div id="today-remaining">`。
セクション自身の `id` は deep link（設計 04 §11）のために**残してあります**。

#### 2-2. 相手の今日から `完了 N件` を削除 ★思想に関わる変更

**修正前**:
```tsx
<h2>残り {open}件・完了 {completed}件</h2>
```

実機ではこれが朝10:14に **「残り 11件・完了 0件」** と、画面で最大の文字で出ていました。
**「パートナーは今日まだ何もしていない」と読めます。**

**判断の根拠**（ここは設計文書に触れるので、根拠を明示します）:

| 出典 | 記述 |
|---|---|
| Requirements §3 / `00_PRODUCT_AND_SCOPE §3` | 勝率・ポイント・ランキングを**仕様として禁止** |
| 設計 04 §5 | 相手の通常業務の完了は「detail/historyで参照可能だが、**scorekeepingとしてpushしない**」 |
| 設計 04 §16.2 | 相手の完了は「ママがやってくれました」ではなく中立に。**自分の負担が減る場合のみ** |
| 設計 04 §5 | 一方で「summary counts」も表示項目として列挙されている |

設計文書の中に**矛盾があり**、実装はそれを scorekeeping 側に倒していました。

**両方を満たす解**:
- `完了 N件` は**削除**。読み手の行動を何も変えず、
  相手の完了が実際に自分の負担を減らす唯一のケースは
  **別セクション `もう済んでいること`（`already_handled`）が既にカバー**している
- `残り N件` は §5 の "summary counts" として**残す**。ただし `<h2>` から静かなメタ行へ降格
- 先頭に来るのは `critical_items`（お迎え / 夕食対応 / お風呂）。
  これは §5 が "tasks that alter user's behavior" と呼んでいる部分

**この判断を覆す場合は、上の4つの出典を読んでからにしてください。**

#### 2-3. 朝・日中の並び替え

自分のやることを、未読の引き継ぎより**上**へ。

```
修正前（朝）: 判断 → 例外 → 持越 → 引き継ぎ → 対応済み → 待ち → 入力 → 朝やること → …
修正後（朝）: 判断 → 例外 → 持越 → 入力 → 朝やること → 引き継ぎ → 待ち → このあと → 対応済み → 予定 → 相手
```

**夜（evening）の並びは変更していません。** 既存テストの順序検証はそのまま通ります。

---

### `da245cb` — 買い物・設定

#### 3-1. 買い物が「終わったもの」に占領されていた

実機では画面全体が `購入済み (4)` と `キャンセル (1)`。
**これから買うものが1件もなく、その旨の表示もなし。**

原因: `STATUS_ORDER` でライフサイクル順に並べていたため、
未着手が空だと完了済みだけが画面を埋める。

**修正**:
- `OPEN_STATUSES`（wanted/assigned/ordered）が**先頭・常時表示**。空なら「いま買うものはありません。」
- `DONE_STATUSES`（purchased/arrived/cancelled）は**1つのトグルに折りたたみ**

#### 3-2. 行のラベルが何も指していなかった

- `その他`: primary action が無い行（購入済みなど）でも出ていたため、
  **その行の唯一の操作が「その他」**という状態だった → 単独のときは `変更`
- `牛乳 — 未定`: `purchase_method: undecided` の生表示。
  **牛乳自体が未定**のように読める → undecided のときはサフィックスを出さない

#### 3-3. 招待できない「招待」カード

家族カードが両メンバーを列挙した**すぐ下**に、
「招待」という見出しで「パートナー『ママ（仮）』がすでに参加しています」だけを表示していました。

**修正**: 設定では非表示。ただしオンボーディング（`HouseholdGate`）では
「参加状況を確認」を押した確認として意味があるので、`confirmWhenJoined` prop で残しました。

#### 3-4. 家族セレクタのレイアウト崩れ

`<label>` が inline のため、名前とselectのペアが**ペアの途中で折り返し**ていました
（`ママ（仮）[select] パパ` → 次行に `[select]`）。grid に変更。

---

## 2. 変更ファイル一覧

```
新規:
  features/planning/useCalendarFreshness.ts        欠けていたensure-calendar-fresh呼び出し口
  features/planning/CalendarStaleBanner.tsx        操作可能な同期警告
  features/history/useHistoryData.window.test.ts   履歴ウィンドウの回帰テスト
  features/settings/calendarRowLabel.test.ts       書き込み先ラベルの回帰テスト

バグ修正:
  features/history/useHistoryData.ts               .lte 追加 + JST統一
  features/planning/WeekView.tsx                   同期呼び出し + 操作可能な警告
  features/planning/MonthView.tsx                  同期呼び出し
  features/settings/CalendarIntegrationSettings.tsx ラベル修正 + 同じ再同期操作
  App.css                                          chip選択状態 / バナー / 家族行
  features/handovers/Handovers.tsx                 PERIOD_LABELS を export
  lib/edgeFunctions.ts                             ensureCalendarFresh 登録
  test/supabaseMock.ts                             .lte 対応

情報設計:
  features/today/Today.tsx                         KPIタイル削除 / 相手の採点削除 / 並び替え
  features/shopping/Shopping.tsx                   未着手優先 / 完了は折りたたみ / ラベル
  features/household/InviteSection.tsx             死んだ招待カードを非表示
  features/settings/SettingsHome.tsx               家族行のレイアウト

文言:
  features/auth/SignIn.tsx                         Family Ops → おうちノート
  features/history/HistoryPage.tsx                 監査情報 → 記録の詳細
  features/concierge/ConciergePage.tsx             "truth" 削除
  features/settings/OutcomeSemanticsPage.tsx       監査 表現の平易化
  lib/date.ts                                      秒を出さない
  app/HouseholdGate.tsx                            confirmWhenJoined

テスト更新:
  App.test.tsx                                     見出し名の変更に追随
  features/history/HistoryPage.test.tsx            文言変更に追随
  features/today/Today.priority.test.tsx           §3 参照
```

---

## 3. テストについて（重要）

**3本のテストに手を入れました。理由を明示します。**

| テスト | 変更 | 理由 |
|---|---|---|
| `App.test.tsx` | `'Family Ops'` → `'おうちノート'` | 文言変更への追随。意図の変更なし |
| `HistoryPage.test.tsx` | `'監査情報'` → `'記録の詳細'` | 同上 |
| `Today.priority.test.tsx` | **全面的に付け替え** | §下記 |

### `Today.priority.test.tsx` の扱い

このテストは **KPIタイル4つと `残り N件・完了 N件` を「要件として」検証**していました。
テスト名も `approved priority order`。つまり**削除したい仕様を、テストが守っていた**。

**カバレッジを消さず、新しい意図に付け替えました。**

- 削除: タイルの存在・カウント・スクロール先の検証
- 追加: **KPI行が無いこと**の回帰ガード（元に戻す変更を検知する）
- 追加: 相手カードに `完了` が無いこと / `<h2>` が無いこと
- 追加: `critical_items` が先頭に来ること（新規ケース）
- **維持: DailyBriefの順序検証は全て残した**（夜の並びは変更していないため）

結果: 38テスト → 40テスト（純増2）。

**同種の判断が必要になったら、テストを消さず付け替えてください。**

---

## 4. 検証結果

```
npx vitest run --root apps/web    →  60 files / 178 tests passed
npm run typecheck                 →  clean (tsc -b)
npm run lint                      →  exit 0
```

lint の警告は 66 → 68 に増えていますが、**新規2件はこのリポジトリの既存慣習**によるものです：
テスト用のヘルパを component ファイルから export する `only-export-components` 警告で、
`Requests.tsx` の `requestBucket`、`HistoryPage.tsx` の `completedNextTokyoMorning`、
`Today.tsx` の `selectNextOwnedTask` と同じパターンです。慣習に合わせ、代わりにテストを付けました。

**SQLテスト（105本）は実行していません。DB側を一切変更していないためです。**

---

## 5. まだ直していないもの（優先順）

### 未着手 A: PWAの `+` が10択を要求する ★思想との最大のズレ

`features/tasks/QuickAdd.tsx` の `quickAddOptions` が10個。
ユーザーは入力の**前に**「何を追加するか」を分類させられます。

要件「お願い・共有・予定・買い物等をユーザーが意識して分類しなくて済むか」と正反対。

**提案**: `+` を押したら入力欄が1つ出るだけにする。分類は結果のプレビューで示す。
`定例を追加` `朝準備を編集` は設定へ移動、`予定外実績` は自然文で解釈されるべき。

### 未着手 B: concierge が4画面

`/concierge → /concierge/results → /concierge/confirm → 完了`。
results と confirm が**ほぼ同じリストを2回**見せています。

LINEでは同じ入力が1画面2タップ。PWAは4画面6〜7タップ。

**提案**: 入力欄の直下にインラインでプレビュー。画面遷移ゼロ。

### 未着手 C: 家事の結果7択 / 買い物6状態

`完了 / 相手が対応 / できなかった / 今回は不要 / 中止 / 再予定 / 不明`

**これはDBとSQLテストに深く埋まっています**（`not_needed_this_occurrence` は11ファイル）。
表示層だけ2択にして、詳細は必要なときだけ聞く形が現実的。
**正本（`docs/design/current/`）を先に直さないと、次のレビューで戻されます。**

### 未着手 D: 初期設定8ステップのゲート

`app/HouseholdGate.tsx`。送迎の14セルグリッドを含む6つの必須ステップ。
アプリを1度も見ないうちに全部埋めないと `ready` にならない。

ステップ表示も `2 / 8` と `4 / 7` `5 / 7` で**不整合**。

**提案**: ゲートを外し、使いながら後払いで設定する形へ。

### 未着手 E: LINE無料枠200通と定例通知の衝突 ★構造的リスク

平日最大8通/日 × 22日 + 休日4通/日 × 8日 ≒ **月165〜210通**。
`soft_budget=180` に定例通知だけで到達します。

枠が尽きると in-app フォールバックですが、
**PWAにWeb Pushは実装されていません**（`PushManager` / VAPID がリポジトリに存在しない）。
＝ 何も届かない。

**提案**: `08:30 / 20:30 / 22:00` のリマインダーを既定オフ（設計04 §7 が既に
「残件がなければ短くしてよい」と言っているので思想とは矛盾しない）。

### 未着手 F: LINEリッチメニューが未公開

`lineUxBuilders.ts` にコメントで
`source/builder-only until provider menu publication is explicitly approved` と明記。
richmenu API の呼び出しがリポジトリ全体に存在しません。

ユーザーが6入口に到達するには「メニュー」と打つ必要があります。
LINE最大の資産（常駐するリッチメニュー）が未使用。

### 未着手 G: 設定が物置になっている

11項目のうち本当の設定は4つ。
`LINE / PWA 入力対応表` と `削除・中止・結果の違い` は**アプリの概念の説明ページ**で、
これが必要になっている事実そのものが症状です。A と C が通れば不要になります。

`Google予定の変更確認` は**未処理の作業キュー**なので、設定ではなく Today に出すべきです。

---

## 6. 作業を続ける人へのルール

1. **スクリーンショットを見てから直す。** このリポジトリのテストは画面を検証していません。
   実機の画面なしでは、ここで直した5件は1件も見つかりませんでした。
2. **足す前に、消せないか考える。** 207マイグレーション中 drop を含むのは3ファイルだけです。
3. **テストが古い仕様を守っていることがある。** 消さず、新しい意図に付け替える。
4. **正本（`docs/design/current/`）を直さずに実装だけ簡素化しない。** 次のレビューで戻されます。
5. **DB・マイグレーション・SQLテストには最後に触る。** 表示層で直せることを先に全部やる。

---

## 7. この変更を revert したい場合

コミット単位で独立しています。

```bash
git revert da245cb   # 買い物・設定
git revert aee0115   # Today（KPIタイル・相手の採点）
git revert 6eb4d29   # バグ5件 ← これは戻さないことを強く推奨
```

`6eb4d29` は**実バグの修正**です（履歴が未来を表示する / アプリが自己矛盾する）。
思想や好みの問題ではないので、戻す理由は無いはずです。

`aee0115` の 2-2（相手の採点）は判断が入っているので、
覆す場合は §2-2 に挙げた4つの出典を確認してください。
