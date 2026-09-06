# Issue #48 — 妻向けPDF用スクリーンショット取得チェックリスト

このチェックリストは、独立reviewが完了し、reviewed production UIが確定してから使う。開発中・テストモード・個人情報を含む画面はPDF素材にしない。

## 取得条件

- iPhone viewport: **375×667** と **393×852**。両方でsafe-area、下部ナビ、modal内scroll、横はみ出し、文字コントラスト、44px以上のタップ領域を確認する。
- 実在の氏名、LINE token、住所、電話番号、園の他児童情報、Google予定の私的詳細はマスクする。
- 本物のLINEへテスト送信しない。必要なら明示的に`🧪`表示の1人テストを使い、PDF素材には採用しない。
- 全画像に取得日・production SHA・画面名を台帳として残す。

## 必須画面

| # | 画面 / 状態 | 確認すること |
| --- | --- | --- |
| 1 | Today — 朝 | `まず確認 → 確認日 → いつもと違う → 引き継ぎ → 今日やること`の順序 |
| 2 | Today — 夜 | `今夜の入力`と、朝が`朝 n/n完了`へ畳まれること |
| 3 | Today shortcuts | `入力 / お願い / 共有`が押しやすいこと |
| 4 | LINE→PWA check-in | 同じ対象・同じ残件へ戻ること |
| 5 | Check-in subtasks | 行全体タップで任意サブタスクを完了/未完了にできること |
| 6 | 夜の入力 | `全部やった / 大体やった / 個別で答える`と各結果 |
| 7 | Request受信 | `やる / 難しい / その他の返答` |
| 8 | Requestその他 | `確認してみる / 相談する`、担当が即時に変わらないこと |
| 9 | 待ち | 待ち理由、確認日、継続、再開、確認日変更 |
| 10 | Shopping | `誰でもOK → 自分がやる → 手放す / 引き継ぐ`の主操作が一つであること |
| 11 | 引き継ぎ | 通常共有と要確認情報の区別、既読操作 |
| 12 | History | 予定と実績、実績訂正後も履歴が残ること |
| 13 | 明日の準備 | 読めるsubtitle、追加後の重複防止 / `追加済み`表示 |
| 14 | stale / double tap | 現在状態の安全な表示、二重完了/二重通知がないこと |
| 15 | Quick Add / LINE Flex | 旧#20/#21 acceptanceを維持していること |

## PDFへ反映する前の判定

1. 上の必須画面が実機または同等のbrowser device evidenceで揃っている。
2. 画面の文言と `OUCHI_NOTE_PARTNER_QUICKSTART.md` / `OUCHI_NOTE_USE_CASE_PLAYBOOK.md` が一致する。
3. `INTENTIONALLY_GATED`機能（園画像・Google writer等）を、使える画面のように記載していない。
4. Issue #48のexact PR head・CI・review verdictをPDF作成記録に紐づける。
