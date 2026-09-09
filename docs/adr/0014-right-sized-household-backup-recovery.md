# ADR 0014 — Right-sized household backup and recovery

- **Status:** Accepted
- **Date:** 2026-09-09
- **Decision owner:** Product Owner
- **Scope:** CF-11 backup/recovery only

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

Therefore this ADR **supersedes only the CF-11 backup/recovery implementation
mechanics** in v6 WP10, v6 observability/backup §5-7, and the v6 WP12
`restore drill pass` interpretation. The v6 files remain read-only historical
records and are not rewritten.

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
3. **Transport/automation** — reuse GitHub Actions and the already configured
   `SUPABASE_ACCESS_TOKEN` through Supabase Management API. Do not introduce a
   production DB password solely for backup.
4. **Data scope** — back up only reviewed durable household/domain tables from
   `scripts/family_ops_recovery_tables.txt`, plus minimal old Auth UUID/email
   references needed to understand user ownership during operator-assisted
   recovery.
5. **Explicit exclusions** — never copy passwords, Auth sessions/identities,
   OAuth refresh tokens, LINE secrets/tokens, Google credentials, webhook or
   notification queues, cron/pg_net state, provider caches, test/simulation
   data, raw transient AI/image extraction state, or artifact-handoff evidence
   as CF-11 household recovery data.
6. **Cadence / RPO** — create one snapshot per day and require a latest snapshot
   no older than 26 hours. Keep the latest 30 Family Ops snapshots in
   `app-save-hub`; do not add a monthly archive tier at current scale.
7. **Integrity** — a backup run is PASS only after the snapshot is inserted into
   `app-save-hub` and the complete JSONB payload is read back and matches the
   source payload. HTTP success alone is not evidence.
8. **Recovery proof** — after recovery implementation changes, and manually when
   needed, restore the latest snapshot into a disposable Supabase stack built
   from repository migrations. PASS requires typed insertion under normal
   FK/check constraints and exact per-table row-count equality.
9. **Auth/provider recovery boundary** — the drill proves household data
   recoverability, not preservation of provider sessions. In a full project
   rebuild, users reconnect/sign in and external LINE/Google/worker state is
   reconfigured after household data validation.
10. **No R2/age obligation now** — Cloudflare R2, age encryption and an
    owner-local age private key are not CURRENT CF-11 acceptance conditions.

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

- daily snapshot workflow uses the reviewed allowlist and separate
  `app-save-hub` project;
- no R2/age/new backup secret is required;
- latest stored snapshot is read-back identical and structurally valid;
- freshness is within 26 hours;
- an actual disposable-Supabase restore completes with exact row counts and no
  foundational identity/task linkage orphans;
- provider credentials/queues/cron state are absent from the recovery payload;
- all repository changes reached `main` through the protected PR + five-check
  release path established by CF-15.

Only after those operational proofs may CF-11 = PASS and Lane C = COMPLETE.
