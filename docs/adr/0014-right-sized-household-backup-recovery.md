# ADR 0014 — Right-sized household backup and recovery

- **Status:** Accepted
- **Date:** 2026-09-09
- **Decision owner:** Product Owner
- **Scope:** CF-11 backup/recovery only

## Governance state

The Product Owner approved this decision on 2026-09-09. PR #73 merged to protected
`main` on 2026-09-09 at `06a4e6b1a5aefccb8f9353fad294dd895582bc53`.
Under ADR 0012, this ADR is therefore Accepted/canonical within its CF-11 scope.
This acceptance does not approve deployment or merging later candidate changes.

## Context

Family Ops is currently a two-person household product. Its canonical
Requirements Baseline defines product/UX intent and deliberately does not pin a
backup vendor or encryption product. Legacy v6 WP10 and
`docs/design/v6/12_OBSERVABILITY_BACKUP_COST.md` later chose a much stronger
operational implementation: daily logical dump, age encryption, private
Cloudflare R2, owner-held private key, freshness alert, and release/monthly
restore drill.

That design is technically defensible for a commercial/multi-user service, but
it creates a new storage provider, a new cryptographic key lifecycle and
manual recovery-key custody for a household currently used by two people. The
Product Owner explicitly approved right-sizing CF-11 rather than treating the
unconfigured R2/age design as a failed mandatory requirement.

The minimum product outcome is:

> 端末故障ではなく、Supabase側の誤操作・障害等で家庭データを失った場合にも、
> 現利用規模に対して合理的な方法で復旧できること。

## Authority resolution

ADR 0012 and ADR 0013 govern this conflict:

1. Accepted ADRs govern the exact architecture decision.
2. The Requirements Baseline governs requirements/UX and remains
   implementation-technology neutral here.
3. `docs/design/current/` is canonical detailed design for CURRENT accepted
   architecture.
4. `docs/design/v6/` remains historical/normative only where it does not
   conflict with newer accepted authority.

This Accepted ADR **supersedes only the CF-11
backup/recovery implementation mechanics** in v6 WP10, v6 observability/backup
§5-7, and the v6 WP12 `restore drill pass` interpretation. The v6 files remain
read-only historical records and are not rewritten.

This does not weaken unrelated security, provider-state, queue, idempotency,
privacy, release-safety or main-protection requirements.

## Decision

For the current two-person operating scale:

1. **Recovery source** — Family Ops production remains Supabase project
   `dnlqxjpjpkxnfgculzip`.
2. **Separate recovery store** — reuse the already existing Supabase project
   `app-save-hub` (`wdwbmvpipbdpomqulsrj`), which is already used for ManaEvo
   save/history. It is a separate project fault domain from Family Ops, while
   intentionally remaining on the existing Supabase service/account.
3. **Namespace separation** — Family Ops uses the reserved tuple
   `app_id='family-ops-recovery-v1'`, `slot_id='household-durable-v1'`, scoped
   to the single reviewed app-save-hub owner `user_id`. Revision lookup,
   current-save upsert, retention pruning, read-back and freshness checks all
   use that exact owner/app/slot tuple. ManaEvo uses `mana-evo/main`; Family Ops
   retention/deletion must never select another tuple.
4. **Transport/automation** — reuse GitHub Actions and the already configured
   `SUPABASE_ACCESS_TOKEN` through Supabase Management API. Do not introduce a
   production DB password solely for backup.
5. **Data scope** — back up only reviewed durable household/domain tables from
   `scripts/family_ops_recovery_tables.txt`, plus minimal old Auth UUID/email
   references needed to rebind restored ownership to newly authenticated users.
6. **Explicit exclusions** — never copy passwords, Auth sessions/identities,
   OAuth refresh tokens, LINE secrets/tokens, Google credentials, webhook or
   notification queues, cron/pg_net state, provider caches, test/simulation
   data, raw transient AI/image extraction state, or artifact-handoff evidence
   as CF-11 household recovery data.
7. **Cadence / RPO** — create one snapshot per day and require a latest snapshot
   no older than 26 hours. Keep the latest 30 Family Ops snapshots in the
   reserved namespace; do not add a monthly archive tier at current scale.
8. **Integrity** — a backup run is PASS only after the snapshot is inserted into
   `app-save-hub` and the complete JSONB payload is read back and matches the
   source payload. HTTP success alone is not evidence.
9. **Recovery proof** — after recovery implementation changes, and manually when
   needed, restore the latest snapshot into a disposable Supabase stack built
   from repository migrations. PASS requires typed insertion under normal
   FK/check constraints and exact per-table row-count equality.
10. **Usable identity recovery** — Auth/provider sessions are not backed up. On
    a new Supabase environment, each recovered household user signs in again or
    is safely recreated/reinvited with the same verified email identity. The
    recovery process maps the old snapshot user UUID to the new Auth UUID and
    rewrites only schema-declared user foreign-key columns before restore. PASS
    requires an actual new Auth sign-in and an authenticated RLS read of the
    recovered profile, household membership, household and household task data
    for every identity represented by the current snapshot.
11. **Provider recovery boundary** — LINE/Google credentials and worker state are
    separately reconfigured after household-domain recovery. Their absence does
    not permit declaring recovery complete if the household cannot sign in and
    reach its restored data.
12. **No R2/age obligation now** — Cloudflare R2, age encryption and an
    owner-local age private key are not CURRENT CF-11 acceptance conditions
    after this ADR becomes canonical.

## Risk accepted by Product Owner

This is intentionally not independent-vendor disaster recovery. Family Ops and
`app-save-hub` are both Supabase projects under the existing account. The
right-sized design protects primarily against Family Ops project/database
operator error and project-level data loss; it does not claim resilience to a
Supabase-wide or whole-account loss.

That residual risk is accepted for the current two-person household scale.
Independent offsite/encrypted DR must be reconsidered if the product is
commercialized, materially expands its user base, begins storing irreplaceable
binary household source material, or the Product Owner changes the recovery
risk posture.

## Acceptance

CF-11 may be marked PASS only when CURRENT evidence proves all of the following:

- this ADR has reached protected `main` and is therefore Accepted/canonical;
- daily snapshot workflow uses the reviewed allowlist and separate
  `app-save-hub` project;
- the Family Ops owner/app/slot namespace is isolated from ManaEvo/other apps,
  including revision, retention pruning, read-back and freshness operations;
- no R2/age/new backup secret is required;
- latest stored snapshot is read-back identical and structurally valid;
- freshness is within 26 hours;
- an actual disposable-Supabase restore completes with exact row counts and no
  foundational identity/task linkage orphans;
- every Auth identity represented by the current snapshot can sign in to the
  disposable recovery environment after old→new UUID rebinding and can read its
  restored profile/household/membership/task data through normal authenticated
  RLS/PostgREST access;
- provider credentials/queues/cron state are absent from the recovery payload;
- all repository changes reached `main` through the protected PR + five-check
  release path established by CF-15.

Only after those operational proofs may CF-11 = PASS and Lane C = COMPLETE.
