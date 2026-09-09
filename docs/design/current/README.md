# Family Ops Detailed Design — Canonical

- **Status:** Accepted / Canonical Detailed Design, with review-candidate governance updates on this branch
- **Accepted:** 2026-09-02
- **Requirements Source of Truth:** `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`
- **Governance:** ADR 0012 Accepted / ADR 0013 Accepted
- **Review:** Independent Round 5 Final Verification = `GO` for the accepted 2026-09-02 detailed-design baseline
- **Reviewed head:** `5c85bd1468a624b831493e198b0f88b4ef7c574e`

このディレクトリは、accepted RequirementsをCURRENT implementationへ安全に落とすための**canonical detailed design**である。PR #41は独立Round 5最終検証で `GO` を得たexact reviewed headをmergeし、ADR 0013のAccepted化により本ディレクトリのarchitecture/schema/API evolutionが正式に承認された。

以後、実装者はこの固定pathを正として使用する。`FINAL` / `V2` / `LATEST` の並行設計コピーは作らない。設計変更はこのpathを更新し、product behavior変更ならRequirements Baseline、architecture scope変更ならADRも同時に更新・レビューする。

**CURRENT mainとbranch candidateを混同しない。** 2026-09-09の`impl/lane-e-ux-governance`ではchannel responsibility / approved UX governance / product-outcome acceptanceをこの固定pathへ統合しているが、mergeされるまではmainのaccepted designと区別して扱う。

---

## Normative hierarchy

For **product requirements and UX meaning**, authority is:

1. `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`
2. accepted ADRs only within their explicit governance / architecture scope; they do not silently redefine product meaning
3. `docs/design/current/`
4. `docs/design/v6/` for non-conflicting legacy architecture/provider/security mechanics
5. code/tests

For an **architecture-specific decision that does not change product requirements/UX**, the accepted ADR governing that exact architecture scope controls the detailed-design realization, subject to the Baseline above. A product-meaning change must update the Baseline through ADR 0012 governance rather than being introduced by a design or ADR side door.

Product/release success is additionally governed by Requirements Baseline §2.1: technical correctness is necessary evidence where applicable but cannot override Family Ops purpose, Requirements, approved UX, or real-use family experience.

Physical schema/cutover detail:

- `08_ACTORREF_LEGACY_IDENTITY_COMPATIBILITY.md`
- `08_CURRENT_MAIN_PHYSICAL_SCHEMA_ALIGNMENT.md`

`08_CURRENT_MAIN_PHYSICAL_SCHEMA_ALIGNMENT.md` がolder conceptual documentのphysical schema/cutover assumptionを明示的に修正する場合、physical detailは08を正とする。ただしproduct meaningを変更する権限はない。

---

## Accepted physical baseline at design review

Reviewed CURRENT main baseline:

- SHA: `7729c93ee10db29b145592763886cfa5f9a019e0`
- migration files: 78
- public tables: **27**
- private tables: **23**
- total: **50**

Table enumeration includes `CREATE TABLE` and `CREATE TABLE IF NOT EXISTS` case-insensitively.

Google provider-lifecycle tables that remain explicit implementation scope:

- `private.family_ops_calendar_mirrors`
- `private.family_ops_calendar_target_deletions`
- `private.family_ops_calendar_orphaned_mirrors`

The first two can mutate Google provider state; the orphan table is observation/audit only. Binding ownership/transfer rules are in `08_CURRENT_MAIN_PHYSICAL_SCHEMA_ALIGNMENT.md` §10 and are synchronized into `02_DATA_MODEL_AND_MIGRATION.md` and `07_ACCEPTANCE_ROLLOUT_WORK_PACKAGES.md`.

Before Phase 1 migration work, implementation must fresh-read the actual production/current schema and stop for review if it differs materially from the accepted physical assumptions.

---

## Canonical documents

1. `01_ARCHITECTURE_AND_DOMAIN_BOUNDARIES.md`
2. `02_DATA_MODEL_AND_MIGRATION.md`
3. `03_STATE_MACHINES_AND_COMMANDS.md`
4. `04_LINE_PWA_DAILY_UX_AND_NOTIFICATIONS.md`
5. `05_GOOGLE_IMAGE_AI_AUTHORITY_PRIVACY.md`
6. `06_TEST_MODE_CONCURRENCY_OBSERVABILITY.md`
7. `07_ACCEPTANCE_ROLLOUT_WORK_PACKAGES.md` — implementation/release gates, including the Baseline §2.1 product-outcome / real-use acceptance gate
8. `08_ACTORREF_LEGACY_IDENTITY_COMPATIBILITY.md`
9. `08_CURRENT_MAIN_PHYSICAL_SCHEMA_ALIGNMENT.md`
10. `09_TRANSPORT_PERIOD_TEMPLATE_AND_MONTH_UX.md` — approved transport/Month refinement realization; subordinate to Requirements Baseline
11. `10_LINE_PWA_RESPONSIBILITY_MATRIX.md` — scenario-level channel responsibility matrix; **PROPOSED / REVIEW-READY until product-owner final approval**
12. `11_APPROVED_FINAL_UX_CANONICALIZATION.md` — canonical registry for the exact approved final UX source snapshot, Q mapping, historical supersession, and later cross-cutting acceptance guards

`10_LINE_PWA_RESPONSIBILITY_MATRIX.md` being stored at the stable current-design path does not by itself make its pending product-owner classification approval complete. Until that explicit approval, it must not be used to change application behavior. `11_APPROVED_FINAL_UX_CANONICALIZATION.md` is a governance/provenance registry and does not outrank or alter the Requirements Baseline.

Review instruction/history documents remain for audit only:

- `FAMILY-OPS-DETAILED-DESIGN-INDEPENDENT-REVIEW-REQUEST.md`
- `FAMILY-OPS-DETAILED-DESIGN-ROUND1-REREVIEW-REQUEST.md`
- `FAMILY-OPS-DETAILED-DESIGN-ROUND2-REREVIEW-REQUEST.md`
- `FAMILY-OPS-DETAILED-DESIGN-ROUND3-REREVIEW-REQUEST.md`
- `FAMILY-OPS-DETAILED-DESIGN-ROUND4-REREVIEW-REQUEST.md`
- `FAMILY-OPS-DETAILED-DESIGN-ROUND5-FINAL-VERIFY-REQUEST.md`

---

## UX contract navigation

For requirements/UX implementation or review, do not select a prototype by filename. Start from the Requirements Baseline, then this README, then `11_APPROVED_FINAL_UX_CANONICALIZATION.md` for the exact pinned approved UX commit/path/blob/render hashes, and `07_ACCEPTANCE_ROLLOUT_WORK_PACKAGES.md` for completion/release judgment. V3/V4/V5 and older prototype assets are historical/superseded for CURRENT UX implementation.

---

## Non-negotiable constraints

- **technical GREEN is not product PASS**: a finding/CI/test/schema/architecture improvement is not complete if it materially worsens Family Ops purpose fulfillment, Requirements conformance, approved UX, or real-use family flow.
- final completion must reconcile `purpose → Requirement → approved UX/CURRENT design → CURRENT implementation → tests/evidence → real-use scenario`.
- Request is agreement truth until accepted; linked Task owns execution after acceptance.
- Request legacy status + lifecycle timestamps remain CHECK-valid via one atomic compatibility projection.
- `大体やった` is group evidence, not child Task status.
- `待ち` is orthogonal Task attention state, not a sixth operational status.
- assignment / anyone claim / actual performer / recorder are separate dimensions.
- real/simulated/system actor uses one ActorRef model; simulated actor never uses operator ID/fake member.
- core test-capable rows have direct `test_context_id`; ordinary production reads/analytics exclude test.
- shopping remains a separate aggregate with anyone claim/participants/duplicate-safety.
- Google all-day events are visible but remain excluded from timed assignment conflict.
- Family Event human-protected/external-follow Authority is not silently overwritten by Google/image/AI.
- provider identityごとにTask mirror / old-target deletion / Family Event writerのprovider mutation ownershipを重複させない。
- `family_ops_calendar_target_deletions`のDELETEもprovider mutationであり、ownership transfer後のstale DELETEは禁止。
- `family_ops_calendar_orphaned_mirrors`はwritable linkの証拠にならず、fresh provider access/identity/ETag revalidationなしでFamily Eventへ昇格しない。
- aggregate canonical reader+writer activates atomically.
- after P1, feature-off never restores legacy current truth.
- no existing migration rewrite / `supabase db reset` / production data delete.
- technical redesign may not silently alter product behavior; if a Requirement/approved UX change is genuinely needed, update and approve the canonical product source first.

---

## Requirements Final-GO MEDIUM 3

The following remain permanent implementation acceptance expectations:

1. `大体やった` + carryover noise — PASS design retained
2. duplicate-sensitive neutral completion, including shopping and undo/correction — PASS design retained
3. one-user synthetic delivery + domain/test-state isolation — PASS design retained

---

## Review record

### Requirements

- CURRENT main Baseline v1.1: final independent re-review `GO`, merged under ADR 0012.
- Branch candidate v1.2 (2026-09-09): Product Owner success criterion integrated; pending normal review/merge and must not be called CURRENT main before merge.

### Detailed design progression

- Round 1: `NO-GO` — BLOCKER 0 / HIGH 3 / MEDIUM 3
- CURRENT physical alignment / Round 2: major migration/read-path gaps closed
- Round 3: `NO-GO` — BLOCKER 0 / HIGH 1
- Round 4: reviewer A `GO WITH CONDITIONS` with one MEDIUM; reviewer B `GO`; no BLOCKER/HIGH
- Round 5: **`GO` — BLOCKER 0 / HIGH 0 / MEDIUM 0 / LOW 0 / Requirements contradiction 0**

Round 5 reviewed head:

`5c85bd1468a624b831493e198b0f88b4ef7c574e`

PR #41 merged that exact head as merge commit `c272b0a1e00491c749e8cc2d76b90b20be8196ae`.

---

## Implementation gate

Detailed-design review of the accepted 2026-09-02 baseline is complete. Any later candidate requirement/design update must pass its own governance/review before being treated as CURRENT main.

Implementation must follow the work-package ordering and gates in `07_ACCEPTANCE_ROLLOUT_WORK_PACKAGES.md`. In particular:

- schema/catalog constraints are freshly measured before migration;
- additive/backfill phases precede new-only semantic writes;
- test ActorRef/side-effect sandbox foundation precedes actual-household simulation;
- each aggregate read+write cutover is atomic;
- provider lifecycle overlap/orphan audits must pass before Family Event P1;
- P1 rollback never restores legacy semantic truth;
- destructive cleanup remains separately reviewed and deferred;
- no work package/release is product-PASS until Baseline §2.1's purpose/Requirement/approved-UX/real-use gate passes; CI GREEN or finding closure alone is insufficient.
