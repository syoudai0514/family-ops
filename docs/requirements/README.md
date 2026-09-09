# Family Ops Requirements — Source of Truth

このディレクトリは、おうちノート / Family Ops の要求・UXに関するcanonical artifactsを置く。

## Canonical documents

- `FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md` — 要求・UXの唯一の正（Source of Truth）。
- `FAMILY-OPS-INDEPENDENT-REVIEW-REQUEST.md` — 上記Baselineを独立レビューするための標準依頼文。

`main`上のBaselineだけがmerge済みCURRENTである。feature/docs branchで次versionを編集中の場合、そのbranch版を`main`のCURRENTとして扱わない。

## Approved UX governance references

以下はBaselineを置き換える第二の要求文書ではなく、CURRENT main governanceから承認済みUX実体・channel責務・acceptance gateへ迷わず到達するための従属参照である。

- `../design/current/11_APPROVED_FINAL_UX_CANONICALIZATION.md` — 承認済みfinal UXのexact source commit/path/blob/render hash、Q mapping、V3/V4/V5 supersession、後続canonical acceptance guardとの関係を固定するcanonical reference registry。
- `../design/current/10_LINE_PWA_RESPONSIBILITY_MATRIX.md` — CF-09のscenario-level LINE/PWA責務表。**product-owner final approvalまではPROPOSED / REVIEW-READY**であり、既存product behaviorを変更する根拠にはしない。
- `../design/current/07_ACCEPTANCE_ROLLOUT_WORK_PACKAGES.md` — Requirements Baseline §2.1を実装/release gateへ落とし、finding closed / CI GREENだけではproduct PASSにしないacceptance contract。

参照先とBaselineがrequirements / UXの意味で競合する場合はBaselineを優先し、競合を明示的に解消する。prototype名や`FINAL`/`LATEST`というファイル名だけをauthority判定に使わない。

## Top-level success criterion

Family Opsの最終成功条件は技術的完全性単独ではない。Baseline §2.1に従い、少なくとも以下を一続きに照合する。

`Family Ops purpose → Requirement → approved UX / CURRENT design → CURRENT implementation → test/evidence → real-use scenario`

個別finding、CI、test、schema、architectureがすべてGREENでも、修正によって家族の通常利用体験が悪化する場合は完了扱いにしない。技術的改善を理由に既存purpose/Requirement/approved UXを暗黙変更しない。

## Maintenance policy

1. `main` 上の `FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md` を常に最新に保つ。
2. 新しい要求判断は、会話・Issue・PRコメントだけで確定させずBaselineへ統合する。
3. 要求に影響する実装PRは、必要なBaseline差分を同じPRまたは先行docs PRに含める。
4. `V2`, `FINAL`, `LATEST` 等の平行コピーを作らず、同じcanonical pathを更新する。履歴はGit historyで追跡する。
5. 独立レビュー結果は、採用するものをBaselineへ反映して初めて確定とする。レビュー本文そのものは要求の正ではない。
6. DOCX/PDF等は配布用exportであり、canonical Markdownから生成する。
7. normative sourceのscopeは `docs/adr/0012-requirements-ux-canonical-governance.md` に従う。Baselineはrequirements/UXの正、`docs/design/v6/*` と既存ADRはBaselineと非競合なarchitecture/implementation判断で引き続き有効。競合をREADMEだけで黙って上書きしない。
8. finding remediation / implementation / review completionではBaseline §2.1を必ず適用し、技術的GREENだけをproduct PASS根拠にしない。
9. product behaviorを変えた方がよいと判断した場合、実装で先行変更せず、理由・具体案・影響を提示してBaselineを先に更新する。

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
- Result: Baseline v1.1 became the active requirements/UX Source of Truth under ADR 0012

### 2026-09-09 — Baseline v1.2 candidate

- Product Owner directive: technical completeness is not the top-level success condition; Family Ops purpose, Requirements, approved UX, and real-use UX are.
- Integrated into Baseline §2.1 and UX principle 11 on `impl/lane-e-ux-governance`.
- This candidate does not become CURRENT main until reviewed/merged under the normal governance path.
- No `Q113` was invented; the criterion is a cross-cutting acceptance rule over all existing Requirements/Q decisions.

## Detailed-design carryover from final review

The following three `MEDIUM` findings do **not** change the Requirements Baseline and did not block the v1.1 merge. They must be carried into detailed-design acceptance criteria without adding unnecessary domain states.

1. **`大体やった` + carryover UX** — carryover-sensitive tasks must not make `大体やった` feel punitive. Prefer weak `結果未確認` presentation or a minimal follow-up only for tasks where carryover matters.
2. **Duplicate-sensitive completion notification** — suppress scorekeeping/actor praise, but for medication, pickup, purchase, submission, etc. where duplicate execution is unsafe or costly, surface a neutral `対応済み` state promptly enough to change behavior.
3. **One-user test delivery boundary** — operator-facing `🧪 synthetic test delivery` is allowed, while production-recipient LINE delivery, production notification outbox, Google writes, and real-user consent effects remain prohibited for simulated actors.

These are detailed-design obligations, not new child-task statuses or new top-level requirements. If detailed design discovers that satisfying them requires changing product behavior, update the canonical Baseline first through the normal review workflow.
