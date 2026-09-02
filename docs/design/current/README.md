# Family Ops Detailed Design — Proposed Canonical

- **Status:** Proposed / Independent Re-Review Required / NO IMPLEMENTATION
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
   - task `待ち` attention state
   - common Domain ActorRef
   - semantic cutover/rollback boundary
2. `02_DATA_MODEL_AND_MIGRATION.md`
   - proposed schema semantics
   - Domain ActorRef persistence model
   - waiting/outcome snapshot
   - existing table evolution
   - compatibility/backfill/cutover strategy
   - legacy mismatch audit
3. `03_STATE_MACHINES_AND_COMMANDS.md`
   - task/assignment/claim/waiting
   - request negotiation
   - actual/reconciliation/outcome reason
   - share/handover/event commands
   - idempotency/concurrency
4. `04_LINE_PWA_DAILY_UX_AND_NOTIFICATIONS.md`
   - shared Daily Brief read model
   - waiting next-check/deadline UX
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
   - persistent Domain ActorRef identity
   - external side-effect sandbox
   - stale/duplicate/concurrent mutations
   - audit/observability/security invariants
7. `07_ACCEPTANCE_ROLLOUT_WORK_PACKAGES.md`
   - acceptance scenarios
   - test sandbox dependency ordering
   - implementation work packages
   - semantic R0/R1/P1 rollout/rollback gates
   - production-safety constraints
8. `FAMILY-OPS-DETAILED-DESIGN-INDEPENDENT-REVIEW-REQUEST.md`
   - original independent review instructions
9. `FAMILY-OPS-DETAILED-DESIGN-ROUND1-REREVIEW-REQUEST.md`
   - Round 1 NO-GO remediation re-review gate

## Non-negotiable design constraints

- Requestは**合意まで**、了承後のexecutionはlinked ToDoを正とする。
- `大体やった` はgroup-level reconciliation evidenceであり、子task statusを増やさない。
- `待ち` は第6statusにせず、`attention_state=waiting` + note/next-check + original dueとしてcurrent truthを持つ。
- planned assignee / anyone claim / actual performer / recorderを混同しない。
- real/simulated/system actor identityは`domain_actor_refs`へ一元化し、simulated actorをoperator real userで代用しない。
- recurrence rule変更でindividual agreementや過去実績をsilent rewriteしない。
- `今回は不要`と`できなかった`を`outcome_reason`で区別し、audit replayをcurrent truthの代替にしない。
- human-confirmed値をGoogle/image/AIがsilent overwriteしない。
- LINE/PWAは別ロジックを持たず、同じserver-side command/read modelを利用する。
- duplicate webhook / stale postback / concurrent mutationで状態を逆戻りさせない。
- one-user testのsimulated actorはproduction recipient delivery、Google write、production outbox、real-user consentを発生させない。
- 既存production dataを削除せず、additive migration + compatibility phaseで移行する。
- new-only semantic state発生後はlegacy current-truth read/writeへrollbackしない。feature-offはmutation pause + canonical projection/forward-fixを意味する。

## Requirements Final GO review carryover

Requirements independent reviewで残った以下3件を、詳細設計acceptance criteriaとして閉じている。

1. **`大体やった` + carryover UX noise**
   - carryover-sensitive taskだけを弱い`結果未確認`として扱い、通常の未完了警告と混ぜない。
   - 必要な場合のみ最小確認を行う。
2. **duplicate-sensitive task completion**
   - 薬、送り迎え、購入、申込み等はactor praiseではなくneutralな`対応済み` stateを必要な相手へ即時提示できる。
3. **one-user test delivery boundary**
   - operator向け`🧪 synthetic test delivery`は許可する。
   - production recipient LINE/outbox/Google/real-user consentはsimulated actorから禁止する。

Round 1 independent reviewではこの3件は**3/3 PASS**判定だった。今回の修正で後退させない。

## Round 1 detailed-design NO-GO remediation

Independent review result:

- `BLOCKER 0`
- `HIGH 3`
- `MEDIUM 3`
- `LOW 0`
- Verdict: `NO-GO`

全6件を今回の同じfixed pathへ反映した。

### HIGH-1 `待ち` current truth

Closed across 01/02/03/04/07:

- small operational statusは維持
- orthogonal `attention_state=active|waiting`
- waiting_note / next_check_at / original due_at
- set/update/resume commands
- normal nag suppression
- next-check DailyBrief resurfacing
- hard-deadline risk
- event prep reuse

### HIGH-2 simulated actor persistence

Closed across 01/02/03/06/07:

- common `domain_actor_refs`
- real_user / simulated_member / system
- assignee/claimant/performer/recorder/request/confirmation/reconciliation/auditへ一貫適用
- no fake auth/member
- no operator-ID substitution
- production/test scope hard constraints

### HIGH-3 semantic rollback

Closed across 01/02/03/07:

- R0 / R1 / P1 phase contract
- P1 = first new-only semantic state
- P1後のlegacy current-truth read/write rollback禁止
- incident response = mutation pause + canonical compatibility/degraded projection or forward-fix
- feature gate is not a truth rollback switch

### MEDIUM-1 outcome reason

- `outcome_reason` is current task snapshot for new skipped writes
- `not_needed_this_occurrence` / `could_not_do` / `expired_occurrence`
- legacy reason unknown is not guessed

### MEDIUM-2 legacy Request mismatch audit

Cutover report now covers:

- missing link
- duplicate/invalid link
- request terminal vs linked task state mismatch
- deterministically detectable timestamp inconsistency

No guessed repair; anomalous rows block semantic cutover until explicitly resolved/classified.

### MEDIUM-3 test-mode dependency order

- test ActorRef/execution context/side-effect hard guard split into `WP-DD3A`
- actual-household one-user test cannot start before DD3A
- later DD10 is UX/transition polish, not safety foundation

## Review gate

詳細設計はfresh independent re-reviewで `GO` が出るまでcanonical確定しない。`BLOCKER` または `HIGH` が残る場合は実装開始禁止。

レビュー後、採用指摘はこの固定pathへ統合し、`FINAL` / `V2` / `LATEST` の並行コピーを作らない。