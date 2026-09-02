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
7. normative sourceのscopeは `docs/adr/0012-requirements-ux-canonical-governance.md` に従う。Baselineはrequirements/UXの正、`docs/design/v6/*` と既存ADRはBaselineと非競合なarchitecture/implementation判断で引き続き有効。競合をREADMEだけで黙って上書きしない。

## Review workflow

1. Baseline更新をdocs PRとして作成する。
2. `FAMILY-OPS-INDEPENDENT-REVIEW-REQUEST.md` を使い、CURRENT `main` とPR headを比較して独立レビューする。
3. BLOCKER/HIGH等の採用指摘をBaselineへ反映し、normative governance変更が必要ならADRも同じPRで更新する。
4. 採用条件を反映後、独立再レビューでmerge gateを確認する。
5. レビュー条件を満たしたらPRをmergeし、`main` のBaselineを新しい正とする。
6. 以後の詳細設計・実装はその`main`版を入力として行う。

## Review history

### PR #39 — Round 1

- Verdict: `GO WITH CONDITIONS`
- Findings: `BLOCKER 1 / HIGH 5 / MEDIUM 4`
- Resolution: Baseline v1.1 + ADR 0012で採用条件を反映

### PR #39 — Round 2

- Verdict: `NO-GO`
- BLOCKER: canonical Baseline / review-request Git blobs were physically truncated mid-UTF-8
- Design/governance evaluation: ADR 0012 / ADR 0001 scope remediation was PASS; Authority rule was PASS where readable
- Resolution: canonical Baseline and independent review request were restored from verified local UTF-8 sources; repaired Git blobs were re-read from GitHub before re-review

### PR #39 — Final independent re-review

- Verdict: `GO`
- Round 1 conditions: `9/9 PASS`
- Findings: `BLOCKER 0 / HIGH 0 / MEDIUM 3 / LOW 0`
- Merge: PR #39 merged to `main` as commit `c7e274e6e886e5688f1b2b7675f44fdae26fb1db`
- Result: `FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md` is now the active requirements/UX Source of Truth under ADR 0012

## Detailed-design carryover from final review

The following three `MEDIUM` findings do **not** change the Requirements Baseline and did not block the merge. They must be carried into detailed-design acceptance criteria without adding unnecessary domain states.

1. **`大体やった` + carryover UX** — carryover-sensitive tasks must not make `大体やった` feel punitive. Prefer weak `結果未確認` presentation or a minimal follow-up only for tasks where carryover matters.
2. **Duplicate-sensitive completion notification** — suppress scorekeeping/actor praise, but for medication, pickup, purchase, submission, etc. where duplicate execution is unsafe or costly, surface a neutral `対応済み` state promptly enough to change behavior.
3. **One-user test delivery boundary** — operator-facing `🧪 synthetic test delivery` is allowed, while production-recipient LINE delivery, production notification outbox, Google writes, and real-user consent effects remain prohibited for simulated actors.

These are detailed-design obligations, not new child-task statuses or new top-level requirements. If detailed design discovers that satisfying them requires changing product behavior, update the canonical Baseline first through the normal review workflow.
