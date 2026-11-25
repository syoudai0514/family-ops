# 関係改善の実装設計（Issue #196〜#207）

`RELATIONSHIP_DESIGN.md` が「何を守るか」、このページは「どう作るか」です。
12本のIssueを、**2つの共通部品＋5つのPR** に組み直します。実装者（Opus / Sonnet）はこのページの順に進めてください。

## 0. 要点

- **共通部品A：配信モード**。誰に何を送るかを1つの関数で決める。今は送る処理が5か所に散らばり、それぞれ独自の条件を持っている。
- **共通部品B：ノートをブロックの並びにする**。朝夜ノートの描画関数（`fn_render_daily_brief_text_v4`）は、モードごとの分岐が積み重なっている。ブロックの並びを作ってから文章にし、配信モードは「出してよいブロックの一覧」で表す。
- Issueの中身を4つ変える：#199 のきっかけ、#200 の合意の単位、#201 は他に統合、#204 は範囲を縮める（§5）。

## 1. 設計の前提になった事実（本番 2026-11-17）

| 事実 | 設計への影響 |
|---|---|
| ママ担当の200件は、すべて送迎の週テンプレート（火・水の迎え、木の送り迎え）から派生している。朝の家事は `dropoff_assignee`、夜の家事は `pickup_assignee` で付く | 合意の単位は、くり返しルール1本ずつではなく **週テンプレート（7曜日×送り／迎え）**。決めることは10マス程度 |
| 「未記録で閉じる」状態は既にある：`status='skipped'`＋`outcome_reason='expired_occurrence'`。制約・読みモデル・`fn_command_skip_task_v1` が対応済み。`carryover_policy` 列もあるが全件 null | 新しい状態は作らない |
| `household_members.user_id` は `auth.users` 必須。ママのアカウントは既にある。世帯は1つだけ | LINEだけの会員作成（認証基盤の変更）は今は不要 |
| 送る処理：朝夜ノート（SQL）、朝のまだのもの（SQL）、コドモン（SQL）、予定の通知（SQL）、前日フォロー（TS, `send-notifications/previousDayReminder.ts`） | 条件を1か所に集める |
| 前日フォローは TS 側で `planned_assignee_id` の todo を直接読む | 判定は SQL 側に移し、TS は表示だけにする |

## 2. 共通部品A：配信モード

### データ（`notification_preferences` に追加）
| 列 | 値 | 既定 |
|---|---|---|
| `member_stage` | `not_invited` / `trial` / `active` | `active` |
| `trial_started_at` | timestamptz | null |
| `delivery_pref` | `auto` / `quiet` / `normal` | `auto` |
| `paused_until` | timestamptz（「止めて」= infinity、「今日は静かに」= 翌日 04:00） | null |

### 関数
`private.fn_delivery_mode_v1(household_id, user_id, at timestamptz) returns text` → `none` / `quiet` / `normal`

判定順:
1. `paused_until > at` → `none`
2. `member_stage='not_invited'` → `none`
3. `member_stage='trial'` かつ開始から7日以内 → `quiet`
4. `delivery_pref` が `quiet` / `normal` → そのまま
5. `auto` → 直近7日に操作があれば `normal`、無ければ `quiet`

操作の有無は `private.fn_last_activity_at_v1(user_id)`。LINE受信（`webhook_inbox` を `line_user_links` で引く）、`task_events.actor_id`、`mutation_receipts.actor_id` のうち最も新しいもの。

### モードごとに届くもの
| 連絡 | normal | quiet | none |
|---|---|---|---|
| 朝ノート | 全体（当番形式） | 短い朝1通（送り迎え・今日だけの予定・お願い）。中身が無い日は送らない | × |
| 夜ノート | ○ | × | × |
| 朝のまだのもの（7:30） | ○ | × | × |
| 前日フォロー | ○（1行） | × | × |
| コドモン 9:00 | ○ | × | × |
| 予定の通知 | ○ | ○ | × |
| お願い・お願いの返事 | ○ | ○ | × |
| ありがとう | ○ | ○ | × |

5か所の送る処理は、すべて最初に `fn_delivery_mode_v1` を呼ぶ。個別の「7日間」判定を各所に書かない。

### 初期データ
- パパ：`active` / `auto`
- ママ：`not_invited`（招くまで何も届かない）。※オーナー確認後に適用

## 3. 共通部品B：ブロック

```
server_read_daily_brief(…)  →  fn_brief_blocks_v1(brief, recipient, mode, daypart)  →  fn_render_blocks_v1(blocks)
```

- `fn_brief_blocks_v1` は `[{kind, heading, lines[]}]` を返す。
- `kind`: `logistics`（送り迎え）/ `special_today` / `request` / `thanks` / `duty`（当番）/ `own_tasks` / `shared_tasks` / `schedule` / `handover` / `previous_day` / `tomorrow` / `shopping` / `weekly_preview`
- 配信モードと時間帯ごとに、出してよい `kind` の一覧を定数で持つ。quiet の朝は `logistics, special_today, request, thanks`（日曜は `weekly_preview` も）。
- 消す `kind`：相手の担当（#197）、夜の「朝の残り／日中の残り」（#198）。
- `logistics` は新しく作る。週次プレビュー（`fn_render_weekly_preview_v1`）の送り迎え算出を `private.fn_day_transport_v1(household, date)` に切り出し、両方で使う（#202 の修正もここに入る）。

最初のPRは**見た目を変えない作り替え**にする。現在の2人ぶんの出力を固定テストに取り、作り替え後も一致することを確認してから、次のPRで中身を変える。

### 共通テスト（新規 `tests/sql/1xx_relationship_invariants.sql`）
- モード×時間帯ごとに、出るブロックの種類を固定する。
- 受け取る人の文面に、相手の担当タスク名が出ないこと。
- LINE文面に禁止語が出ないこと：`残り` `未完了` `忘れずに` `できなかった` `まだ完了が記録されていません`。
  新しい文面を足すたびにこのテストが守る。

## 4. PRの順番

| PR | 中身 | 対応Issue |
|---|---|---|
| 1 | 共通部品B（見た目を変えない作り替え＋固定テスト）→ 相手の担当ブロックを削除 | #197 |
| 2 | 共通部品A（配信モード）＋quiet の朝1通＋ママを `not_invited` に | #196、#198の③、#206の条件 |
| 3 | 未記録の自動クローズ＋夜に朝の残りを出さない＋言葉の置き換え | #198 |
| 4 | 当番ブロック＋朝夜のボタン＋前日フォロー1行 | #205、#206、#201 |
| 5 | 招き直し＋週テンプレートの合意 | #204、#200 |
| 6 | ありがとう（お願いを引き受けた時だけ） | #199 |
| いつでも | 週次プレビュー修正、写真読み取り | #202、#207 |
| 保留 | 健康指標 | #203 |

1〜4は、あなた自身が続けられる量に戻すことと、奥さん側への配信を安全にすることを兼ねる。5以降は奥さんを招く段階。

## 5. Issueの中身の変更

### #198 未記録の自動クローズ
- 閉じるのは**翌日12:00**。前日フォロー（06:30）と「ぜんぶ済み」ボタンの後にする。
- 状態は `skipped`＋`expired_occurrence`。actor はシステム、`task_events.event_type='expired'`、`source='system'`。既存の `fn_command_skip_task_v1` は利用者の操作用なので、同じ更新をするシステム専用関数を別に作る。
- 対象：`origin='recurring'` かつ `calendar_visibility='hidden'`。お願い・手動・⭐特別な予定・買い物は対象外。
- 生成時に `carryover_policy='occurrence_ends'` を入れる。既存の null は、上の対象条件と同じ扱い。
- 閉じた後でも7日以内なら「昨日のは全部終わっている」で完了にできる。`expired_occurrence` → `completed` の遷移を、この経路だけ許す。

### #199 ありがとう：きっかけを変える
- **「相手があなたの担当を代わりにやった」はきっかけにしない。** 関係が悪い時に「パパがあなたの担当をやりました」と知らせるのは、貸し借りの通知として読まれる。
- きっかけは、自分が出したお願いを相手が引き受けた時（送迎の代わりを含む）だけ。お願いした本人に `引き受けてくれました [ありがとうを送る]` を出す。

### #200 担当の合意：単位を週テンプレートにする
- `transport_weekly_templates` に `agreed_at`, `agreed_by` を追加する。作った人と別の大人が「合ってる」と押したら合意済み。
- 聞き方は1問だけ：`送り迎えの曜日、この形で合ってる？ 火・水 迎えママ／木 送り迎えママ [合ってる] [違う]`。「違う」なら、作った人に `送り迎えの曜日を確認したいそうです。` を送る。
- **安全のため、送り迎えは合意前でも隠さない。** 子どもの迎えが誰か分からなくなる方が危ない。合意前は `迎え ママ（予定）` と出す。
- 当番の中身（夜当番の11件など）は2人とも同じものを見られるので、合意の対象にしない。
- 事前に片付けること：個人に固定されたルール（お迎え ママ×3本・パパ×2本、送り ママ×1本・パパ×4本）が、テンプレート由来の送迎と二重になっていないかを確認し、元を1つにする。

### #201 1タップの返事：他のIssueに統合して閉じる
- 「朝の当番 済み」「夜の当番 済み」ボタンは #205、「今日は静かに」は #196 の `paused_until`、「送り迎えを相談」は既存のお願いの流れ。

### #204 相手を招く：範囲を縮める
- LINEだけの会員作成はやらない。`auth.users` 必須の外部キーを崩す変更になり、世帯は1つで、ママのアカウントは既にある。
- 作るのは「招き直し」：
  1. あなたが書く最初の1通（必須、定型文なし）
  2. 相手に最初に届くもののプレビュー
  3. 送信すると `member_stage='trial'`
  4. 7日後に1回だけ `家のことの分担も、ここで見られるようにしますか？`
     - 「見てみる」→ `active`／`normal`
     - 「今のままでいい」→ `active`／`quiet`（固定）
- 「止めて」「再開」は全員に効くので、#196 に入れる。

### #205 当番ブロック
- 当番かどうかは `task_instances.recurrence_rule_id` → `recurrence_rules.assignee_strategy` で決める。朝当番は `dropoff_assignee` かつ朝、夜当番は `pickup_assignee` かつ夜。
- `codmon_*` は「済み」の一括から外し、9:15の期限行として別に出す。送信のガードがあるので、一括に入れると全体が失敗する。

### #206 前日フォロー
- 出すかどうかは SQL 側で決め、朝ノートの payload に `previous_day_followup: true` を載せる。TS は文面とボタンだけ。

### #203 健康指標
- 世帯が1つで、見るのはあなただけなので、今は保留（P3）。

## 6. 決めてもらうこと
1. ママを今すぐ `not_invited`（配信ゼロ）にしてよいか。PR2 を待たず、データだけで先に止めることもできる。
2. #204 の範囲縮小（LINEだけの会員作成はやらない）でよいか。
