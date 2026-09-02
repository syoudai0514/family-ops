# Family Ops Detailed Design — Proposed Canonical

- **Status:** Proposed / Independent Re-Review Required / NO IMPLEMENTATION
- **Date:** 2026-09-02
- **Repository baseline:** `main` @ `7729c93ee10db29b145592763886cfa5f9a019e0`
- **Requirements Source of Truth:** `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`
- **Governance:** ADR 0012 Accepted / ADR 0013 Proposed

このディレクトリは、accepted RequirementsをCURRENT implementationへ安全に落とすための詳細設計候補である。

独立レビューで `GO` を得るまでは:

- PR #41をmergeしない
- ADR 0013をAcceptedにしない
- implementation planning / implementationを開始しない

このPRはdocs-only。migration / Supabase / Edge / LINE / Google / Vercel / production dataは変更しない。

---

## Normative hierarchy

1. `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`
2. ADR 0012 / proposed ADR 0013
3. `docs/design/current/01`–`07`
4. CURRENT physical/cutover detail:
   - `08_ACTORREF_LEGACY_IDENTITY_COMPATIBILITY.md`
   - `08_CURRENT_MAIN_PHYSICAL_SCHEMA_ALIGNMENT.md`

`08_CURRENT_MAIN_PHYSICAL_SCHEMA_ALIGNMENT.md` が older conceptual document の物理schema/cutover assumptionを明示的に修正する場合、physical detailは08を正とする。ただしproduct meaningを変更する権限はない。

Review採用内容はこのfixed pathへ更新し、`FINAL` / `V2` / `LATEST` の並行設計コピーは作らない。

---

## CURRENT physical baseline

CURRENT main fresh read:

- SHA: `7729c93ee10db29b145592763886cfa5f9a019e0`
- migration files: 78
- CURRENT application-owned tables relevant to this program:
  - public 27
  - private 21
  - **total 48**

Earlier `46` count was incomplete because `20260822000001_calendar_projection_domain.sql` creates two tables with `CREATE TABLE IF NOT EXISTS` that were absent from the prior inventory:

- `public.household_task_categories`
- `private.family_ops_calendar_mirrors`

Both are now explicitly dispositioned in `08_CURRENT_MAIN_PHYSICAL_SCHEMA_ALIGNMENT.md`.

`private.family_ops_calendar_mirrors` is active Task/transport→Google projection infrastructure and has an explicit boundary/ownership-transfer contract with the new Family Event Authority layer.

---

## Documents

1. `01_ARCHITECTURE_AND_DOMAIN_BOUNDARIES.md`
   - truth hierarchy / command-read model / Authority boundary
2. `02_DATA_MODEL_AND_MIGRATION.md`
   - schema semantics
   - ActorRef / waiting / outcomes / participants
   - Request Attempt + full legacy status/timestamp compatibility
   - Family Event + CURRENT Task→Google mirror bridge
   - corrected atomic migration phases
3. `03_STATE_MACHINES_AND_COMMANDS.md`
   - Task/assignment/claim/waiting
   - Request negotiation
   - actual/reconciliation
   - idempotency/concurrency
4. `04_LINE_PWA_DAILY_UX_AND_NOTIFICATIONS.md`
   - shared DailyBrief
   - 06:30 / 09:00 / 20:30 anchors
   - carryover / neutral duplicate-sensitive behavior
5. `05_GOOGLE_IMAGE_AI_AUTHORITY_PRIVACY.md`
   - Human/Google/source/AI Authority
   - candidate model
   - nursery/Codmon privacy
6. `06_TEST_MODE_CONCURRENCY_OBSERVABILITY.md`
   - one-user simulation
   - test scope / side-effect sandbox
7. `07_ACCEPTANCE_ROLLOUT_WORK_PACKAGES.md`
   - implementation WPs / acceptance / R0-R1-P1
   - dedicated shopping package
   - Request physical CHECK acceptance
   - all-day + schedule override acceptance
   - Family Event / Task-mirror exactly-one-writer acceptance
8. `08_ACTORREF_LEGACY_IDENTITY_COMPATIBILITY.md`
   - CURRENT real-user-only identity/FK compatibility
9. `08_CURRENT_MAIN_PHYSICAL_SCHEMA_ALIGNMENT.md`
   - 48/48 CURRENT table disposition
   - task completion CHECK replacement
   - Request status+timestamp compatibility + multi-attempt composition
   - aggregate atomic cutover
   - direct test scoping
   - shopping
   - DailyBrief schedule persistence
   - all-day display vs conflict
   - CURRENT `family_ops_calendar_mirrors` bridge/transfer/reconciliation
10. review instructions:
   - `FAMILY-OPS-DETAILED-DESIGN-INDEPENDENT-REVIEW-REQUEST.md`
   - `FAMILY-OPS-DETAILED-DESIGN-ROUND1-REREVIEW-REQUEST.md`
   - `FAMILY-OPS-DETAILED-DESIGN-ROUND2-REREVIEW-REQUEST.md`
   - `FAMILY-OPS-DETAILED-DESIGN-ROUND3-REREVIEW-REQUEST.md` ← next gate

---

## Non-negotiable constraints

- Request is agreement truth until accepted; linked Task owns execution after acceptance.
- Request Attempt may represent checking/consulting/change/cancel without forcing legacy Request lifecycle to become canonical.
- CURRENT `requests` status **and lifecycle timestamps** must remain CHECK-valid via one atomic compatibility projection.
- After an agreement is accepted, active post-agreement change/cancel Attempt does not reproject the legacy Request back to pending/cancelled; legacy row remains accepted compatibility while canonical reader shows negotiation.
- `大体やった` is group evidence, not child Task status.
- `待ち` is orthogonal Task attention state, not a sixth operational status.
- assignment / anyone claim / actual performer / recorder are separate dimensions.
- real/simulated/system actor uses one ActorRef model; simulated actor never uses operator ID/fake member.
- core test-capable rows have direct test_context and ordinary production reads exclude test.
- shopping remains a separate aggregate with anyone claim/participants/duplicate-safety.
- Google all-day events are visible but remain excluded from timed assignment conflict.
- Family Event human-protected/external-follow Authority is not silently overwritten by Google/image/AI.
- CURRENT Task→Google mirror and new Family Event writer obey **exactly one writer per provider event**.
- existing special Task mirror is never auto-converted into Family Event by title/date guessing.
- provider ID/ETag ownership transfer requires queue/lease reconciliation and disables Task re-enqueue before Family Event write ownership starts.
- LINE/PWA use same server command/read model.
- aggregate canonical reader+writer activates atomically.
- after P1, feature-off never restores legacy current truth.
- no existing migration rewrite / db reset / production data delete.

---

## Requirements Final-GO MEDIUM 3

These remain required as `PASS`:

1. `大体やった` + carryover noise
2. duplicate-sensitive neutral completion, including shopping and undo/correction
3. one-user synthetic delivery + domain/test-state isolation

---

## Review history

### Requirements

Final: `GO`.

### Detailed design Round 1

`NO-GO` / BLOCKER 0 / HIGH 3 / MEDIUM 3.

Closed:

- formal Task waiting current truth
- ActorRef simulated identity
- safe P1 rollback contract
- outcome reason
- broader Request/Task mismatch audit
- test sandbox dependency order

### CURRENT physical-alignment review

`NO-GO` / BLOCKER 1 / HIGH 7 / additional MEDIUM/LOW.

Closed in prior remediation:

- task completion CHECK
- Request new-state read cutover direction
- atomic aggregate cutover
- direct test scope
- shopping connection
- DailyBrief cadence storage
- all-day display separation
- outcome / compatibility-primary / consultation semantics

### Latest independent re-reviews supplied by user

Two reviewers disagreed on CURRENT table count:

- one found the inventory incomplete because `household_task_categories` and `family_ops_calendar_mirrors` were omitted;
- one reported 46/46 after mechanical extraction.

Fresh direct read of `20260822000001_calendar_projection_domain.sql` resolves the discrepancy: both omitted tables are physically created with `CREATE TABLE IF NOT EXISTS`; `family_ops_calendar_mirrors` is also actively evolved/used by later migrations. Canonical inventory is now **48/48**.

The other remaining merge-blocking finding was legacy Request status/timestamp compatibility for multi-attempt Requests. It is now explicitly closed in `02` and `08`:

- full lifecycle tuple projection
- expired compatibility handling
- post-accept change/cancel composition
- Request CHECK catalog verification
- WP-DD4 acceptance scenarios

Recommended non-blocking cleanup was also adopted:

- `02` migration phases now directly match atomic read/write activation
- participant direct test_context + compatibility-primary documented in `02`
- `07` now has dedicated shopping package
- DailyBrief package now includes date override + all-day scenarios
- Family Event package includes CURRENT Task-mirror queue/ownership migration

---

## Next review gate

Use:

`docs/design/current/FAMILY-OPS-DETAILED-DESIGN-ROUND3-REREVIEW-REQUEST.md`

Reviewer must fresh-read CURRENT main and actual PR head. Do not trust prior 46-table extraction; verify `CREATE TABLE IF NOT EXISTS` migrations explicitly.

GO condition:

- BLOCKER 0
- HIGH 0
- Requirements contradiction 0
- Request physical compatibility executable
- 48/48 table inventory accepted
- Task mirror / Family Event writer boundary executable
- no regression in earlier PASS items

Until that review returns GO: no merge, no ADR acceptance, no implementation.
