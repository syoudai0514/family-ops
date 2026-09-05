# おうちノート UX Contract v4

## Product objective

おうちノートの最上位目的は、家族の毎日で「今、誰が何をすればいいか」を考えなくても分かるようにし、終わったら最小操作で実績まで残せること。

優先順位:
1. 何をすべきか分かる
2. その場で実行・確認できる
3. 終わった結果を最小操作で残せる
4. 例外だけ詳しく扱う

## Today first-screen contract

Today の最初の1画面に、クリック可能な「今日の状況」サマリーを置く。

例:
- 今日やること 残り2 → Today内の該当セクションへジャンプ
- お願い未回答 1 → Requests の未回答対象へdeep link
- 明日に影響する準備 1 → Today内の明日準備へジャンプ
- 今日の予定 3 → Today内の予定へジャンプ

重要情報を下までスクロールしないと発見できない設計は禁止。

## Actual-input / reconciliation contract

`全部やった` の前に必ず対象を表示する。

悪い例:
- 全部やった

良い例:
- 今回の入力対象: 洗濯 / お風呂掃除
- `この2件を全部やった`

通常ケース:
- Today上で個別項目を1タップ完了可能
- 夜は完了済み朝タスクを `朝 4/4 完了` のように畳む
- 夜の残りだけをまとめ入力対象にする

個別入力:
- 通常は `完了` を最上位
- 例外は `その他の結果` 内に置く
- 相手が対応 / できなかった / 今回不要 / 中止 / 再予定を区別

`大体やった` は group-level reconciliation evidence であり、子タスクを勝手に完了/未達へ変更しない。

実績時刻はユーザー管理しない。翌朝入力でも元タスク対象日に紐づける。登録時刻は監査情報として通常UIから退避する。

## Navigation / back contract

### Root navigation
Bottom nav の Today / Week / Month / Shopping / History は root view として扱う。

### Back behavior
- Today summary → Requests → Back: Today の summary 位置へ戻す
- Today todo → Check-in → Back: Today の元 scroll anchor へ戻す
- Check-in → Individual → Back: Check-in の選択状態を保持して戻す
- Month → DayAgendaSheet → Close/Back: 同じ月・選択日・scroll位置を保持
- Requests list → detail → Back: 同じtab/filter/scroll位置を保持
- History → correction → Back: 同じentry/filter/scroll位置を保持
- Concierge from Today → Back: Todayへ戻り入力テキストを保持
- Concierge from QuickAdd → Back: QuickAddを開いた元画面へ戻す
- LINE deep link等でアプリ内originがない場合: logical parentへ。解決不能なら Today

Browser/System Back と画面内 Back は同じ結果にする。

未保存編集がある場合のみ破棄確認を出す。閲覧/通常遷移で不要な確認を出さない。

Mutation後は全画面reloadやscroll先頭戻りを禁止し、元のcontextを維持してinline feedback/toastを出す。

## Concierge position

おうちコンシェルジュは主導線ではなく、予定外入力の万能入口。
Todayの行動理解を邪魔しない位置に置き、QuickAdd最上段とToday shortcutから利用可能にする。

## Implementation direction

このcontractは参考イメージではなく UI/interaction contract として扱う。
ただし backend/state/security は prototype の静的実装をコピーせず CURRENT canonical implementation を利用する。

実装時に必須:
- existing canonical commands/state machine reuse
- household/user/conversation isolation
- revision/CAS/idempotency preservation
- LINE/PWA semantic parity for natural-language input
- no production/provider mutation during review remediation
