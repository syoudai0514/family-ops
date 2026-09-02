# Family Ops Detailed Design — Proposed Canonical

- **Status:** Proposed / Independent Re-Review Required / NO IMPLEMENTATION
- **Date:** 2026-09-02
- **Repository baseline:** `main` @ `7729c93ee10db29b145592763886cfa5f9a019e0`
- **Requirements Source of Truth:** `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`
- **Governance:** ADR 0012 (Accepted), ADR 0013 (Proposed in this change)

このディレクトリは、accepted RequirementsをCURRENT implementationへ安全に落とすための**詳細設計候補**である。独立レビューで `GO` を得てmergeされた時点で、requirements/UXと競合しない範囲のcurrent detailed-design canonical pathとなる。`docs/design/v6/` はADR 0012/0013に従い、非競合な既存architecture/security/provider制約の参照元として維持する。

このPRではコード、migration、Supabase、LINE runtime、Google Calendar、Vercel、production dataを変更しない。

## Normative scope inside `docs/design/current`

- `01`–`07`：truth ownership、commands、UX、Authority、security、rolloutのconceptual current design。
- `08_ACTORREF_LEGACY_IDENTITY_COMPATIBILITY.md`：CURRENTのreal-user-only identity列/FKとActorRefの具体的互換境界。
- `08_CURRENT_MAIN_PHYSICAL_SCHEMA_ALIGNMENT.md`：**CURRENT mainのphysical schema、CHECK/FK、46-table disposition、direct-reader compatibility、aggregate cutoverのnormative alignment**。これが`02/04/05/06/07`の古いphysical assumptionを明示的に修正する場合、physical detailはこの文書を優先する。
- product requirementsの正は引き続きcanonical Requirements Baselineであり、上記08文書は別のrequirements sourceではない。
- review採用内容はこの固定pathへ更新し、`FINAL` / `V2` / `LATEST` の並行コピーを作らない。

## Documents

1. `01_ARCHITECTURE_AND_DOMAIN_BOUNDARIES.md`
   - Source of Truth hierarchy / command-read model / truth ownership
   - task `待ち` attention state
   - common Domain ActorRef
   - semantic cutover/rollback boundary
2. `02_DATA_MODEL_AND_MIGRATION.md`
   - schema semantics / ActorRef / waiting/outcome
   - participant / Request Attempt / reconciliation / Family Event
   - backfill / mismatch audit / R0-R1-P1 migration strategy
3. `03_STATE_MACHINES_AND_COMMANDS.md`
   - task/assignment/claim/waiting
   - Request negotiation / actual/reconciliation
   - idempotency/concurrency
4. `04_LINE_PWA_DAILY_UX_AND_NOTIFICATIONS.md`
   - shared DailyBrief
   - 06:30 / 09:00 / 20:30 anchors
   - carryover / duplicate-sensitive neutral notification
5. `05_GOOGLE_IMAGE_AI_AUTHORITY_PRIVACY.md`
   - unified Authority/candidate model
   - Google/provider observation vs Family Event truth
   - nursery/Codmon intake / privacy
6. `06_TEST_MODE_CONCURRENCY_OBSERVABILITY.md`
   - one-user synthetic test
   - ActorRef/test context / side-effect sandbox
   - stale/duplicate/concurrency / observability
7. `07_ACCEPTANCE_ROLLOUT_WORK_PACKAGES.md`
   - acceptance / WP dependency order
   - R0/R1/P1 cutover / production safety
8. `08_ACTORREF_LEGACY_IDENTITY_COMPATIBILITY.md`
   - exact compatibility for CURRENT `requests`, `task_events`, handover/read receipts, mutation receipts, legacy user-ID columns
9. `08_CURRENT_MAIN_PHYSICAL_SCHEMA_ALIGNMENT.md`
   - fresh CURRENT migration/table inventory
   - public 26 / private 20 = 46 table disposition
   - task completion CHECK replacement + compatibility-primary mirror
   - Request Attempt → legacy status/direct-reader compatibility
   - aggregate-level atomic read/write cutover
   - direct test scoping and production-read leakage gate
   - shopping claim/actual/duplicate-safety model
   - DailyBrief schedule persistence + one-day override
   - all-day display vs timed conflict separation
10. `FAMILY-OPS-DETAILED-DESIGN-INDEPENDENT-REVIEW-REQUEST.md`
11. `FAMILY-OPS-DETAILED-DESIGN-ROUND1-REREVIEW-REQUEST.md`
12. `FAMILY-OPS-DETAILED-DESIGN-ROUND2-REREVIEW-REQUEST.md`

## Non-negotiable design constraints

- Requestは**合意まで**、了承後のexecutionはlinked ToDoを正とする。
- `大体やった`はgroup-level evidenceであり、子task statusを増やさない。
- `待ち`は第6statusにせず、`attention_state=waiting` + note/next-check + original dueをcurrent truthとする。
- assignment / anyone claim / actual performer / recorderを混同しない。
- real/simulated/system actorは`domain_actor_refs`へ一元化し、simulated actorをoperator IDやfake auth/memberで代用しない。
- CURRENT real-user-only legacy identity列はproduction compatibility mirrorに限定する。
- core test-capable business rowsはdirect `test_context_id`で常時識別可能にし、ordinary production readsから既定で除外する。
- `今回は不要` / `できなかった` / occurrence expiry / cancel / replanをcurrent semanticsで区別する。
- human-confirmed値をGoogle/image/AIがsilent overwriteしない。
- Google all-day eventは**表示から除外しない**。timed conflictからは従来どおり除外する。
- shoppingは独立aggregateのまま、`誰でもOK` claim / participants / duplicate-safetyを持つ。
- LINE/PWAは同じserver command/read modelを使う。
- CURRENT physical CHECK/FK/direct readersを無視したconceptual-only migrationは禁止。
- aggregate cutoverではcanonical read + writeを同時に切替え、new-only stateをold current-truth UIへ露出させない。
- P1後はlegacy current-truth read/writeへrollbackしない。feature-offはmutation pause + canonical/degraded projectionまたはforward-fixを意味する。
- existing migration rewrite、production reset/data deleteは禁止。

## Requirements Final-GO MEDIUM carryover

1. **`大体やった` + carryover UX noise**
   - weak `結果未確認`、carryover-sensitive subsetのみ最小確認。通常の未達/失敗と混ぜない。
2. **duplicate-sensitive neutral completion**
   - 薬・送迎・購入・申込み等はactor praiseでなくneutral `対応済み`。
   - shopping接続と、undo/correctionで再びactionableになった場合のneutral correctionもcurrent physical alignmentで明記。
3. **one-user synthetic delivery boundary**
   - operator向け`🧪` synthetic deliveryは許可。
   - production recipient/outbox/Google/real consentは禁止。
   - domain rowsもdirect test scope + ordinary-read exclusionで隔離する。

次回re-reviewでは3件を再度 `PASS / PARTIAL / FAIL` 判定する。

## Detailed-design review history

### Round 1 — conceptual/domain completeness

Verdict: `NO-GO` / BLOCKER 0 / HIGH 3 / MEDIUM 3 / LOW 0。

Remediated on the same fixed path:

- HIGH: formal `待ち` current truth → `attention_state` + waiting note/next-check/deadline behavior across 01/02/03/04/07。
- HIGH: simulated actor identity → ActorRef + legacy identity compatibility + no fake/member/operator substitution。
- HIGH: unsafe semantic rollback → R0/R1/P1; P1後old read/write復帰禁止。
- MEDIUM: current outcome reason。
- MEDIUM: legacy Request↔Task mismatch audit。
- MEDIUM: test sandbox WP dependency → `WP-DD3A` before actual-household test。

### Round 2 input — CURRENT-main physical schema alignment

External review verdict supplied by the user:

- `NO-GO`
- `BLOCKER 1`
- `HIGH 7`
- `MEDIUM 8`
- `LOW 4`

The reviewer explicitly judged **Requirements contradiction = 0** and found the Authority model, truth separation, and ADR 0013 scope directionally valid. Findings concentrated on insufficient cross-check against CURRENT physical schema/runtime.

Fresh read confirmed CURRENT main `7729c93...` has migration files through `20260825000001...` and the physical constraints/subsystems cited by the review.

Remediation is recorded in `08_CURRENT_MAIN_PHYSICAL_SCHEMA_ALIGNMENT.md`:

- BLOCKER: CURRENT `task_instances` completion CHECKs → Phase 1 new migration must replace those CHECKs before participant-based completion; no old migration rewrite/legacy column drop。
- HIGH: Request canonical Attempt state → explicit legacy `requests.status` projection + current Requests/Today/Edge/LINE reader cutover inventory。
- HIGH: Phase ordering → deploy inactive reader+writer, reconcile, then **aggregate atomic canonical read/write activation** before first new-only state。
- HIGH: test-domain leakage → direct test context on core business rows + production read exclusion + leakage audit。
- HIGH: all CURRENT tables → 46/46 disposition (`KEEP/EVOLVE/SUPERSEDE/OUT-OF-SCOPE`) including assignment-change scope, schedules, pending actions, preferences, raw inputs, dispatch receipts。
- HIGH: shopping → independent aggregate evolved with assignment mode/claim/participants/revision/duplicate safety/test scope + neutral undo correction。
- HIGH: DailyBrief cadence → new schedule kinds + date-specific override + existing settings/RPC/dispatcher/receipts disposition。
- HIGH: all-day → visible in DailyBrief, still excluded from timed assignment conflict。
- MEDIUM implementation-defining gaps → compatibility-primary performer rule, outcome/disposition mapping, consultation proposer confirmation, broader legacy reconciliation。

## Review gate

Detailed design remains **NO IMPLEMENTATION** until fresh independent review of the actual current PR head returns `GO`.

Next review instruction:

`docs/design/current/FAMILY-OPS-DETAILED-DESIGN-ROUND2-REREVIEW-REQUEST.md`

The reviewer must fresh-read CURRENT `main`, actual PR head, both 08 alignment documents, relevant migrations/code/readers, and verify no regression in Round 1 findings or Requirements Final-GO MEDIUMs.

If `BLOCKER` or `HIGH` remains:

- do not merge PR #41
- do not accept ADR 0013
- do not begin implementation planning/implementation

After eventual `GO`, adopted content remains on this fixed path.