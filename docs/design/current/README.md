# Family Ops Detailed Design — Proposed Canonical

- **Status:** Proposed / Final Independent Verification Required / NO IMPLEMENTATION
- **Date:** 2026-09-02
- **Repository baseline:** `main` @ `7729c93ee10db29b145592763886cfa5f9a019e0`
- **Requirements Source of Truth:** `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`
- **Governance:** ADR 0012 Accepted / ADR 0013 Proposed

このディレクトリはaccepted RequirementsをCURRENT implementationへ安全に落とすための詳細設計候補である。actual current PR headに対する独立レビューで `GO` を得るまではPR #41をmergeせず、ADR 0013をAcceptedにせず、implementation planning / implementationを開始しない。

このPRはdocs-only。migration / Supabase / Edge / LINE / Google / Vercel / production dataは変更しない。

---

## Normative hierarchy

1. `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`
2. ADR 0012 / proposed ADR 0013
3. `docs/design/current/01`–`07`
4. CURRENT physical/cutover detail:
   - `08_ACTORREF_LEGACY_IDENTITY_COMPATIBILITY.md`
   - `08_CURRENT_MAIN_PHYSICAL_SCHEMA_ALIGNMENT.md`

`08_CURRENT_MAIN_PHYSICAL_SCHEMA_ALIGNMENT.md` がolder conceptual documentのphysical schema/cutover assumptionを明示的に修正する場合、physical detailは08を正とする。ただしproduct meaningを変更する権限はない。

Review採用内容はこのfixed pathへ更新し、`FINAL` / `V2` / `LATEST` の並行設計コピーは作らない。

---

## CURRENT physical baseline

CURRENT main fresh read:

- SHA: `7729c93ee10db29b145592763886cfa5f9a019e0`
- migration files: 78
- public tables: **27**
- private tables: **23**
- total: **50**

Table enumeration must match case-insensitive `CREATE TABLE` with optional `IF NOT EXISTS`.

The Google provider-lifecycle tables that must all remain in scope are:

- `private.family_ops_calendar_mirrors`
- `private.family_ops_calendar_target_deletions`
- `private.family_ops_calendar_orphaned_mirrors`

The first two can mutate Google provider state; the orphan table records provider identities that became unmanageable after permission/eligibility loss. Their ownership/transfer rules are binding in `08_CURRENT_MAIN_PHYSICAL_SCHEMA_ALIGNMENT.md` §10 and are now also synchronized into `02_DATA_MODEL_AND_MIGRATION.md`.

---

## Documents

1. `01_ARCHITECTURE_AND_DOMAIN_BOUNDARIES.md`
2. `02_DATA_MODEL_AND_MIGRATION.md`
3. `03_STATE_MACHINES_AND_COMMANDS.md`
4. `04_LINE_PWA_DAILY_UX_AND_NOTIFICATIONS.md`
5. `05_GOOGLE_IMAGE_AI_AUTHORITY_PRIVACY.md`
6. `06_TEST_MODE_CONCURRENCY_OBSERVABILITY.md`
7. `07_ACCEPTANCE_ROLLOUT_WORK_PACKAGES.md`
8. `08_ACTORREF_LEGACY_IDENTITY_COMPATIBILITY.md`
9. `08_CURRENT_MAIN_PHYSICAL_SCHEMA_ALIGNMENT.md`
10. `FAMILY-OPS-DETAILED-DESIGN-INDEPENDENT-REVIEW-REQUEST.md`
11. `FAMILY-OPS-DETAILED-DESIGN-ROUND1-REREVIEW-REQUEST.md`
12. `FAMILY-OPS-DETAILED-DESIGN-ROUND2-REREVIEW-REQUEST.md` — historical rubric
13. `FAMILY-OPS-DETAILED-DESIGN-ROUND3-REREVIEW-REQUEST.md` — historical rubric
14. `FAMILY-OPS-DETAILED-DESIGN-ROUND4-REREVIEW-REQUEST.md` — historical rubric
15. `FAMILY-OPS-DETAILED-DESIGN-ROUND5-FINAL-VERIFY-REQUEST.md` — **current final verification entry point**

---

## Non-negotiable constraints

- Request is agreement truth until accepted; linked Task owns execution after acceptance.
- Request legacy status + lifecycle timestamps remain CHECK-valid via one atomic compatibility projection.
- `大体やった` is group evidence, not child Task status.
- `待ち` is orthogonal Task attention state, not a sixth operational status.
- assignment / anyone claim / actual performer / recorder are separate dimensions.
- real/simulated/system actor uses one ActorRef model; simulated actor never uses operator ID/fake member.
- core test-capable rows have direct test_context and ordinary production reads exclude test.
- shopping remains a separate aggregate with anyone claim/participants/duplicate-safety.
- Google all-day events are visible but remain excluded from timed assignment conflict.
- Family Event human-protected/external-follow Authority is not silently overwritten by Google/image/AI.
- provider identityごとにTask mirror / old-target deletion / Family Event writerのmutation ownershipを重複させない。
- `family_ops_calendar_target_deletions`はDELETEもprovider writerとして扱い、ownership transfer後にstale deleteを実行しない。
- `family_ops_calendar_orphaned_mirrors`はwritable linkの証拠にせず、fresh provider revalidationなしでFamily Eventへ昇格しない。
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

Closed: formal Task waiting current truth, ActorRef simulated identity, safe P1 rollback contract, outcome reason, Request/Task mismatch audit, test sandbox dependency order。

### CURRENT physical-alignment / Round 2

Closed: task completion CHECK replacement, Request Attempt model/read cutover, atomic aggregate cutover, direct test scope, shopping connection, DailyBrief cadence storage, all-day display separation, compatibility-primary, consultation semantics, work-package gaps。

### Round 3

Two independent fresh reviews both returned `NO-GO / BLOCKER 0 / HIGH 1` and independently found that CURRENT physical inventory is 50, not 48, because `private.family_ops_calendar_target_deletions` and `private.family_ops_calendar_orphaned_mirrors` were missing from the provider-lifecycle design.

### Round 4

The current provider-lifecycle design closed that HIGH:

- `08` corrected to 50/50 disposition;
- target deletions = `BRIDGE`;
- orphaned mirrors = `KEEP` audit/observation;
- exactly-one-provider-mutation-owner includes Task mirror + target-deletion queue + Family Event writer;
- ownership transfer blocks/reconciles deletion job states including live lease and blocked state;
- completed deletion cannot be adopted as live link;
- unresolved orphan blocks adoption until provider access + exact identity/ETag are freshly revalidated;
- target-deletion worker must revalidate current provider ownership before destructive DELETE;
- `07 WP-DD2/WP-DD8/WP-DD11` inventory, acceptance and audit cover the full provider lifecycle.

Independent Round 4 results supplied by the user:

- reviewer A: **GO WITH CONDITIONS** — BLOCKER 0 / HIGH 0 / MEDIUM 1; only finding was stale Round 3 physical text in `02_DATA_MODEL_AND_MIGRATION.md`.
- reviewer B: **GO** — BLOCKER/HIGH/MEDIUM/LOW all 0.

The single Round 4 condition has now been applied directly to `02`:

- 50 tables = public 27 / private 23
- three provider lifecycle tables explicitly named
- `§13.2` three provider mutation paths + orphan blocker
- Phase 2 three-table reconciliation + 50-table audit
- `§21.6` mirror/deletion/orphan lifecycle inventory
- constraint/destructive-shortcut language synchronized to `08` / `07`

No product/domain redesign was made in this final synchronization.

---

## Current final verification gate

Use:

`docs/design/current/FAMILY-OPS-DETAILED-DESIGN-ROUND5-FINAL-VERIFY-REQUEST.md`

This is a focused verification of the single Round 4 condition plus regression checks. Reviewer must fresh-read CURRENT main and the **actual current PR head**; do not reuse the Round 4 head verdict after the `02` synchronization commit.

GO condition:

- BLOCKER 0
- HIGH 0
- Requirements contradiction 0
- `02` is synchronized to 50 tables / three Google provider-lifecycle tables
- Request physical compatibility remains executable
- provider mutation ownership across Task mirror / target deletion / Family Event remains executable without invention
- orphan handling remains safe
- no regression in earlier PASS items
- Requirements Final-GO MEDIUM 3 remain PASS

Until the actual current head receives independent `GO`: no merge, no ADR acceptance, no implementation.