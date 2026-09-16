# ASTRA → Sol PROPOSED detailed design
Status: **PROPOSED / NOT CANONICAL / NO RELEASE AUTHORIZATION**
Date: 2026-09-17
Reviewed source: `900313187c2460901f91d8aea66051e57729b50b`
Review: [独立レビュー](../reviews/ASTRA-PURPOSE-UX-REVIEW-2026-09-17.md)
Branch: `review/astra-purpose-ux-20260917`

## 0. Purpose → Requirements → UX → implementation
目的は家族の記憶・調整・確認の負担を減らすこと。機能数、AI利用回数、詳細入力率を成果にしない。通常日は少ない入力で閉じ、例外がある日だけ必要な判断を見せる。
本書は実装提案であり、merged canonicalを上書きしない。PF-01〜04は現行要件への適合改善。PF-05/06はPO-01/02未承認のため実装対象外。Solは承認済み設計との差分をcanonical detailed designに同じ変更単位で反映するが、未承認提案を転記して正本化してはいけない。

## 1. 家族が使う画面の着地点
- 朝: Today/LINEで例外と自分の作業を見る。コドモン送信行には締切と残る入力・担当が分かる。食事や体調本文はコドモンにだけ入力する。
- 思いついた時: 「＋追加」→即入力。「牛乳がなくなりそう。水曜のお迎えお願い」→候補と送信正文を一画面で確認→一度だけ確定。
- お願い: 相手、作業、日付/時刻、相手に見せる文面を確認する。生の愚痴や考え途中の原文は自動で相手に送らない。
- 通信不調: 保存できたか不明ならその事実を表示し、同じ操作を確認する。新規依頼をもう一通送って様子を見る必要をなくす。
- 夜: 「全部やった」「大体やった」「個別」は現行どおり。PF-06をPOが承認した場合だけCodmon最終送信を一般groupから除く。
- 相談: PF-05承認後だけPWAにも限定的な相談返答を出す。未承認ならLINEの既存相談導線を維持し、PWA汎用チャットは作らない。

## 2. 共通不変条件
1. 一つのshared canonical domain、既存command、RLS/ActorRef/contextを再利用。別Todo DB、別AI parser、別Request状態を作らない。
2. Request合意前は担当維持。受理後はlinked task。変更scopeとmaterial effectsを見せ、protected agreements/claim/actualを保護。
3. 重要な送信は人の確認内容とpayloadが一致。モデル出力、本文中の「送って」、候補選択だけを送信承認にしない。
4. 保存/通知の不確実性を成功や未送信に変換しない。operation IDは再試行で維持、入力変更は新しい操作として明示。
5. quota 200、reply-first、既存notification preferences・dedup・expiryを維持。PWA成功を同じ人のLINEへ返さない。
6. Codmon provider操作なし。家族の入力完了/送信完了申告だけ。AIはreadinessや担当・provider成功を推定しない。
7. UIの入力内容、元画面、scrollは保持。既存PWA recoveryを削除せず、部分更新でshellを再mountしない。
8. 本書によるproduction mutation/deploy/F2/main mergeは認めない。

## 3. 実装単位と依存
| Work package | 内容 | 分類 | DB migration |
|---|---|---|---|
| S0 | CURRENT/authority再確認、metadata driftのみ整理 | conforming docs | なし |
| S1 | PF-02 immutable command preview + PF-01 input-first/単一確認 | conforming | 原則なし |
| S2 | PF-04 bounded API + stable attempt/recovery | conforming | 原則なし。既存idempotency欠落が実証されたendpointだけ追加migration |
| S3 | PF-03 Codmon readinessの共通読取とinline UI | conforming | additive function/projection migration |
| S4 | PO-01承認後PF-05 PWA相談返答 | REQUIREMENT CHANGE | なし |
| S5 | PO-02承認後PF-06 Codmon最終送信bulk除外 | REQUIREMENT CHANGE | additive command/read projection migration |

S1のconfirmed commandをS2のretry envelopeとして再利用。S3はS1/S2から独立するがS2のmutation結果不明UIを使う。S4/S5の判断待ちでS1〜3を止めない。提案を実装しないことを未完了bugとして数えない。

## 4. 変更対象の方針
既存concierge/router/command/DailyBriefの範囲で完結させる。専用command-center、チャット履歴DB、generic dependency engine、通知再設計、大規模refactorは作らない。
不要候補: QuickAddの最初の10選択肢modal、Results→Confirmの重複確認。削除は互換routeと手動入口を置換した後。既存業務機能・LINE必須経路は削除しない。
このcheckpointでは方向性のみ確定。後続checkpointでPF別API/state/tests/rolloutを追記する。
