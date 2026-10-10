# おうちノート Product Guide Index

家族向け利用資料の入口です。

## 家族に最初に見せる

- `OUCHI_NOTE_PARTNER_QUICKSTART.md`
  - 3分で目的と毎日の使い方を説明する短縮版
  - 妻・パートナーへの最初の説明用

## 利用ガイド正本

- `OUCHI_NOTE_GUIDE_SOURCE.md`
  - おうちノートの利用思想、毎日の流れ、LINE/PWA、お願い、実績、Shopping、Google、園画像、1人テストまでの家族向け正本
  - 最終画面モック/PDF/HTMLを生成する際のsource

## ユースケース別の詳しい操作

- `OUCHI_NOTE_USE_CASE_PLAYBOOK.md`
  - 35ユースケース
  - 「こんな時 → 手順 → こうなる → 注意」の形式
  - 受入確認・妻への説明・操作QAにも利用

## PDF用の画面取得

- `ISSUE-48-SCREENSHOT-CHECKLIST.md`
  - reviewed production UIで妻向けPDFを作る前の画面取得・個人情報マスク・iPhone確認の正本

## 技術仕様の正本

Product Guideは技術設計の正本ではありません。仕様判断は次を優先します。

1. `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`
2. `docs/design/current/`
3. Accepted ADR
4. CURRENT source

## リリース前後の更新

利用ガイドと3分ガイドは2026年10月10日の改善ブランチに合わせています。[変更と確認結果](../changes/2026-10-10-daily-ux.md)を参照してください。本番反映前は実画面と異なる場合があります。ユースケース手順書には、以前の設計目標を説明した項目も残っています。
production activation後に:

1. CURRENT iPhone/PWA/LINE実画面で全ユースケース確認
2. 正式なボタン名・画面位置を反映
3. スクリーンショット取得
4. 妻向けPDF/HTML版生成
5. ガイドと実装の差分QA

を行って完成版とします。
