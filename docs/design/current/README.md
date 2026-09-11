# Family Ops Detailed Design — Canonical

- **Status:** Accepted / Canonical Detailed Design on CURRENT `main`, including CF-09/CF-10 governance and the 2026-09-11 physical-F2 approved clarifications
- **Accepted baseline:** 2026-09-02 (ADR 0013 package)
- **CF-11 recovery:** Accepted on CURRENT `main` after PR #73 merge, 2026-09-09
- **Requirements Source of Truth:** `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`
- **Governance:** ADR 0012 Accepted / ADR 0013 Accepted / ADR 0014 Accepted
- **Runtime rule:** always fresh-read CURRENT `main`; historical SHA values below are provenance only

このディレクトリは、accepted RequirementsをCURRENT implementationへ安全に落とすための**canonical detailed design**である。固定pathを正として使用し、`FINAL` / `V2` / `LATEST` の平行コピーを作らない。product behavior変更ならRequirements Baseline、architecture scope変更ならaccepted ADR / current designを同じ変更単位で更新する。

CURRENT `main` ではPR #73のmergeによりADR 0014 / `10_BACKUP_RECOVERY.md` がcanonicalとなり、CF-11のright-sized household recovery designが受理済みである。旧R2/age前提はこのscopeではsupersedeされる。provider credential/sessionまで復旧できると誤解してはならない。

CURRENT canonical pathには、Product Owner承認済みCF-09 channel responsibility matrix、CF-10 approved-final-UX canonicalization、Baseline v1.2 product-outcome acceptance guard、および2026-09-11 physical F2で明示承認された補足要求を統合する。Release GOやF2 PASSは、これらの文書が存在するだけでは成立せず、exact-HEADの実利用証跡で別途判定する。

---

## Normative hierarchy

For **product requirements and UX meaning**:

1. `docs/requirements/FAMILY-OPS-REQUIREMENTS-UX-BASELINE.md`
2. accepted ADRs within their explicit governance / architecture scope
3. `docs/design/current/`
4. `docs/design/v6/` for non-conflicting legacy architecture/provider/security mechanics
5. code/tests

For an architecture-specific decision that does not change product meaning, the accepted ADR governing that exact scope controls the detailed-design realization, subject to the Baseline above. Product meaning must not be changed through an ADR/design side door.

Product/release success is additionally governed by Requirements Baseline §2.1: technical correctness is necessary evidence where applicable but cannot override Family Ops purpose, Requirements, approved UX, or real-use family experience.

Physical schema/cutover detail:

- `08_ACTORREF_LEGACY_IDENTITY_COMPATIBILITY.md`
- `08_CURRENT_MAIN_PHYSICAL_SCHEMA_ALIGNMENT.md`

`08_CURRENT_MAIN_PHYSICAL_SCHEMA_ALIGNMENT.md` may correct older conceptual physical assumptions, but cannot change product meaning.

---

## Accepted physical baseline at design review

Reviewed baseline at the detailed-design acceptance point:

- SHA: `7729c93ee10db29b145592763886cfa5f9a019e0`
- public tables: **27**
- private tables: **23**
- total: **50**

Implementation/release work must still fresh-read CURRENT schema/runtime before material cutover decisions.

Google provider-lifecycle tables in scope include:

- `private.family_ops_calendar_mirrors`
- `private.family_ops_calendar_target_deletions`
- `private.family_ops_calendar_orphaned_mirrors`

Provider mutation ownership must remain singular; orphan evidence is not a writable provider link.

---

## Canonical documents and integration-candidate additions

1. `01_ARCHITECTURE_AND_DOMAIN_BOUNDARIES.md`
2. `02_DATA_MODEL_AND_MIGRATION.md`
3. `03_STATE_MACHINES_AND_COMMANDS.md`
4. `04_LINE_PWA_DAILY_UX_AND_NOTIFICATIONS.md` — §26に2026-09-11 physical-F2 LINE/PWA approved clarifications
5. `05_GOOGLE_IMAGE_AI_AUTHORITY_PRIVACY.md`
6. `06_TEST_MODE_CONCURRENCY_OBSERVABILITY.md`
7. `07_ACCEPTANCE_ROLLOUT_WORK_PACKAGES.md` — implementation/release gates, including product-outcome / real-use acceptance
8. `08_ACTORREF_LEGACY_IDENTITY_COMPATIBILITY.md`
9. `08_CURRENT_MAIN_PHYSICAL_SCHEMA_ALIGNMENT.md`
10. `09_TRANSPORT_PERIOD_TEMPLATE_AND_MONTH_UX.md` — §9にsame-start edit / transport-role dependent reassignment clarifications
11. `10_BACKUP_RECOVERY.md` — ADR 0014 accepted right-sized household recovery contract on CURRENT main
12. `10_LINE_PWA_RESPONSIBILITY_MATRIX.md` — CF-09 M01-M26 classifications Product Owner approved; integration candidate, not Release GO
13. `11_APPROVED_FINAL_UX_CANONICALIZATION.md` — exact approved UX snapshot/provenance/Q mapping registry; §4.2にphysical-F2 approved clarifications; subordinate to Baseline

Review instruction/history documents remain audit-only and are not CURRENT requirements/design authorities.

---

## UX contract navigation

For requirements/UX implementation or review, start from the Requirements Baseline, then this README, then `10_LINE_PWA_RESPONSIBILITY_MATRIX.md` for channel responsibility and `11_APPROVED_FINAL_UX_CANONICALIZATION.md` for the pinned approved UX source. Do not select V3/V4/V5/FINAL/LATEST artifacts by filename heuristics.

---

## Non-negotiable constraints

- **technical GREEN is not product PASS**; final completion reconciles `purpose → Requirement → approved UX/CURRENT design → CURRENT implementation → tests/evidence → real-use scenario`.
- Request is agreement truth until accepted; linked Task owns execution after acceptance.
- Request legacy status + lifecycle timestamps remain CHECK-valid via one atomic compatibility projection.
- `大体やった` is group evidence, not child Task status.
- `待ち` is orthogonal Task attention state, not a sixth operational status.
- assignment / anyone claim / actual performer / recorder are separate dimensions.
- real/simulated/system actor uses one ActorRef model; simulated actor never uses operator ID/fake member.
- core test-capable rows have direct `test_context_id`; ordinary production reads/analytics exclude test.
- shopping remains a separate aggregate with anyone claim/participants/duplicate-safety.
- Google all-day events are visible but excluded from timed assignment conflict.
- Family Event human-protected/external-follow Authority is not silently overwritten by Google/image/AI.
- provider identityごとにTask mirror / old-target deletion / Family Event writerのprovider mutation ownershipを重複させない。
- `family_ops_calendar_target_deletions`のDELETEもprovider mutationであり、ownership transfer後のstale DELETEは禁止。
- `family_ops_calendar_orphaned_mirrors`はwritable linkの証拠にならない。
- aggregate canonical reader+writer activates atomically.
- after P1, feature-off never restores legacy current truth.
- no existing migration rewrite / production reset / production data delete as an implementation shortcut.
- ADR 0014 recovery uses an explicit household-domain allowlist and excludes provider credentials/sessions/queues/test state; it does not claim provider-session recovery.
- technical redesign may not silently alter product behavior; genuine product changes require explicit canonical Requirements/design update first.

---

## Requirements Final-GO MEDIUM 3

Permanent implementation acceptance expectations:

1. `大体やった` + carryover noise
2. duplicate-sensitive neutral completion, including shopping and undo/correction
3. one-user synthetic delivery + domain/test-state isolation

---

## Review record

### Requirements

- Baseline v1.1: final independent re-review `GO`, merged under ADR 0012.
- Baseline v1.2 success criterion is canonical on CURRENT main; 2026-09-11 physical-F2 Product Owner clarifications are integrated through Baseline §28 in the accompanying canonical docs update.

### Detailed design

- Round 5: **GO — BLOCKER 0 / HIGH 0 / MEDIUM 0 / LOW 0 / Requirements contradiction 0**
- Round 5 reviewed head: `5c85bd1468a624b831493e198b0f88b4ef7c574e`
- PR #41 merge commit: `c272b0a1e00491c749e8cc2d76b90b20be8196ae`

### CF-11 / ADR 0014

- Product Owner approved: 2026-09-09
- PR #73 merged to CURRENT main as `06a4e6b1a5aefccb8f9353fad294dd895582bc53`
- backup/freshness/disposable restore/authenticated-use evidence: PASS per reviewed PR #73
- CF-11 is canonical on CURRENT main and must not be rolled back by older lane branches.

### CF-09 channel responsibility

- Product Owner approved all 26 M01-M26 classifications on 2026-09-09; they are now part of the canonical current-design path.
- Approval scope is classification semantics only; not implementation-wide approval or Release/F2 GO.

---

## Implementation gate

Implementation and integration must preserve the established work-package ordering/gates and the CURRENT accepted operational-safety baseline. In particular:

- fresh-read actual schema/runtime before material migration/cutover decisions;
- additive/backfill phases precede new-only semantic writes;
- test ActorRef/side-effect sandbox foundation precedes actual-household simulation;
- each aggregate read+write cutover is atomic;
- provider lifecycle overlap/orphan audits pass before Family Event P1;
- P1 rollback never restores legacy semantic truth;
- destructive cleanup remains separately reviewed and deferred;
- no work package/release is product-PASS until Baseline §2.1's purpose/Requirement/approved-UX/real-use gate passes;
- CURRENT main CF-11/CF-15 operational safety and repository protection must not be weakened by integration of older branches.
