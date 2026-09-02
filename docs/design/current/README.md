# Family Ops Detailed Design — Proposed Canonical

- **Status:** Proposed / Independent Review Required / NO IMPLEMENTATION
- **Date:** 2026-09-02
- **Repository baseline:** `main` @ `7729c93ee10db29b145592763886cfa5f9a019e0`
- **Requirements Source of Truth:** `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`
- **Governance:** ADR 0012 (Accepted), ADR 0013 (Proposed in this change)

このディレクトリは、要求Baselineを実装可能な状態へ落とすための**詳細設計候補**である。独立レビューを通過してmergeされた時点で、requirements/UXと競合しない範囲の次期詳細設計のcanonical pathとして扱う。`docs/design/v6/` はADR 0012に従い、非競合な既存architecture/security/API制約の参照元として維持する。

このPRではコード、migration、Supabase、LINE runtime、Google Calendar、Vercel、production dataを変更しない。

## Documents

1. `01_ARCHITECTURE_AND_DOMAIN_BOUNDARIES.md`
   - Source of Truth hierarchy
   - current implementation reuse boundary
   - command/read-model architecture
   - domain truth ownership
2. `02_DATA_MODEL_AND_MIGRATION.md`
   - proposed schema semantics
   - existing table evolution
   - compatibility/backfill/cutover strategy
3. `03_STATE_MACHINES_AND_COMMANDS.md`
   - task/assignment/claim
   - request negotiation
   - actual/reconciliation
   - share/handover/event commands
   - idempotency/concurrency
4. `04_LINE_PWA_DAILY_UX_AND_NOTIFICATIONS.md`
   - shared Daily Brief read model
   - morning/evening LINE
   - PWA deep links
   - notification policy
   - three Final-GO MEDIUM carryovers
5. `05_GOOGLE_IMAGE_AI_AUTHORITY_PRIVACY.md`
   - unified Authority/candidate model
   - Google synchronization conflict handling
   - nursery/Codmon image intake
   - child/school isolation and raw-image privacy
6. `06_TEST_MODE_CONCURRENCY_OBSERVABILITY.md`
   - one-user synthetic test mode
   - external side-effect sandbox
   - stale/duplicate/concurrent mutations
   - audit/observability/security invariants
7. `07_ACCEPTANCE_ROLLOUT_WORK_PACKAGES.md`
   - acceptance scenarios
   - implementation work packages
   - rollout/rollback gates
   - production-safety constraints
8. `FAMILY-OPS-DETAILED-DESIGN-INDEPENDENT-REVIEW-REQUEST.md`
   - independent review instructions

## Non-negotiable design constraints

- Requestは**合意まで**、了承後のexecutionはlinked ToDoを正とする。
- `大体やった` はgroup-level reconciliation evidenceであり、子task statusを増やさない。
- planned assignee / anyone claim / actual performer / recorderを混同しない。
- recurrence rule変更でindividual agreementや過去実績をsilent rewriteしない。
- human-confirmed値をGoogle/image/AIがsilent overwriteしない。
- LINE/PWAは別ロジックを持たず、同じserver-side command/read modelを利用する。
- duplicate webhook / stale postback / concurrent mutationで状態を逆戻りさせない。
- one-user testのsimulated actorはproduction recipient delivery、Google write、production outbox、real-user consentを発生させない。
- 既存production dataを削除せず、additive migration + compatibility phaseで移行する。

## Final GO review carryover

Requirements independent reviewで残った以下3件を、詳細設計acceptance criteriaとして必ず閉じる。

1. **`大体やった` + carryover UX noise**
   - carryover-sensitive taskだけを弱い`結果未確認`として扱い、通常の未完了警告と混ぜない。
   - 必要な場合のみ最小確認を行う。
2. **duplicate-sensitive task completion**
   - 薬、送り迎え、購入、申込み等はactor praiseではなくneutralな`対応済み` stateを必要な相手へ即時提示できる。
3. **one-user test delivery boundary**
   - operator向け`🧪 synthetic test delivery`は許可する。
   - production recipient LINE/outbox/Google/real-user consentはsimulated actorから禁止する。

## Review gate

詳細設計は独立レビューで `GO` が出るまでcanonical確定しない。`BLOCKER` または `HIGH` が残る場合は実装開始禁止。

レビュー後、採用指摘はこの固定pathへ統合し、`FINAL` / `V2` / `LATEST` の並行コピーを作らない。
