# Family Ops Requirements — Source of Truth

このディレクトリは、おうちノート / Family Ops の要求・UXに関するcanonical artifactsを置く。

## Canonical documents

- `FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md` — 要求・UXの唯一の正（Source of Truth）。
- `FAMILY-OPS-INDEPENDENT-REVIEW-REQUEST.md` — 上記Baselineを独立レビューするための標準依頼文。

## Maintenance policy

1. `main` 上の `FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md` を常に最新に保つ。
2. 新しい要求判断は、会話・Issue・PRコメントだけで確定させずBaselineへ統合する。
3. 要求に影響する実装PRは、必要なBaseline差分を同じPRまたは先行docs PRに含める。
4. `V2`, `FINAL`, `LATEST` 等の平行コピーを作らず、同じcanonical pathを更新する。履歴はGit historyで追跡する。
5. 独立レビュー結果は、採用するものをBaselineへ反映して初めて確定とする。レビュー本文そのものは要求の正ではない。
6. DOCX/PDF等は配布用exportであり、canonical Markdownから生成する。
7. 旧 `docs/design/v6/*` 等とBaselineが競合する場合、要求・UXについてはBaselineを優先し、詳細設計で差分を解消する。

## Review workflow

1. Baseline更新をdocs PRとして作成する。
2. `FAMILY-OPS-INDEPENDENT-REVIEW-REQUEST.md` を使い、CURRENT `main` とPR headを比較して独立レビューする。
3. BLOCKER/HIGH等の採用指摘をBaselineへ反映する。
4. レビュー条件を満たしたらPRをmergeし、`main` のBaselineを新しい正とする。
5. 以後の詳細設計・実装はその`main`版を入力として行う。
