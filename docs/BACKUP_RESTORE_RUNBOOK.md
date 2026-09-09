# Backup / Restore Runbook

This is the operational runbook for WP10 (`docs/design/v6/10_WORK_PACKAGES.md`
"WP10 — Backup / recovery"). It is not part of the vendored v6 design
package — do not edit `docs/design/v6/`; if this runbook and v6 ever seem to
disagree, v6 wins and this file gets fixed.

## How the backup system works

1. `.github/workflows/backup.yml` runs daily (18:00 UTC / 03:00 JST).
2. It uses pinned Supabase CLI `2.117.0`, rather than raw `pg_dump`, to build
   a Supabase-compatible logical backup. The bundle contains exactly:
   - `roles.sql`
   - `schema.sql`
   - `data.sql`
   - `history_schema.sql`
   - `history_data.sql`
3. `schema.sql` / `data.sql` use Supabase CLI's managed-schema filtering;
   migration history is deliberately dumped separately because the normal
   filtered schema dump does not by itself preserve
   `supabase_migrations.schema_migrations`.
4. The five SQL members are packed into `logical-backup.tar`, encrypted with
   `age` using **only the public recipient**, and uploaded as
   `family-ops-backup-YYYY-MM-DD.tar.age` to the private R2 bucket.
5. R2 `head-object` must prove the encrypted object exists and is non-empty
   before `latest-backup.txt` is advanced.
6. `.github/workflows/backup_freshness_alert.yml` independently verifies that
   the marker is no older than the exact 26-hour policy and still references
   a non-empty encrypted R2 object.
7. Restore/decryption is manual and local only. The private age key never
   enters GitHub or CI.

### Why raw `pg_dump` is not used

Supabase's managed Postgres database contains platform-owned schemas and
reserved roles. Supabase documents that raw `pg_dump` can include those
internals and cause permission/compatibility failures on restore. The
Supabase CLI still uses pg_dump underneath, but applies Supabase-specific
filtering and is the supported logical migration/restore path.

The restore target must therefore also be a **fresh Supabase-compatible
Postgres environment**, not an arbitrary vanilla PostgreSQL database.

Workflow YAML correctness alone is not operational proof. See **Operational
PASS evidence** below.

## Security boundary — age private key never enters CI

CI holds the `age` **public** key (`BACKUP_AGE_PUBLIC_KEY`) only. A public key
can encrypt but cannot decrypt.

The `age` **private** key is held **only** by the household owner, in their
password manager or offline storage. It is:

- never stored as a GitHub Actions secret;
- never committed to this repository;
- never referenced by name in workflow files;
- never accepted by `scripts/restore_drill.sh` via an environment variable;
- supplied only as a local key-file path or through the script's hidden
  interactive prompt.

If a future change proposes adding the private key to CI to automate restore,
that is a security regression.

## One-time setup

1. Generate the age keypair on the owner's own machine:
   ```sh
   age-keygen -o family-ops-backup-key.txt
   ```
2. Store the private key in the owner's password manager/offline storage and
   remove unnecessary plaintext copies.
3. Add only the public `age1...` recipient as GitHub Actions repository secret
   `BACKUP_AGE_PUBLIC_KEY`.
4. Create private Cloudflare R2 bucket `family-ops-backups` with no public
   access.
5. Create a bucket-scoped R2 token with read/write access and add:
   - `R2_ACCOUNT_ID`
   - `R2_ACCESS_KEY_ID`
   - `R2_SECRET_ACCESS_KEY`
   - `R2_BUCKET_NAME` (normally `family-ops-backups`)
6. Add production DB connection string as `SUPABASE_DB_URL`.
   - obtain it from Supabase Database connection settings;
   - use a direct connection or session-mode pooler suitable for database
     dump operations;
   - do not use transaction-mode pooling;
   - percent-encode password characters as required for a URI passed to
     `supabase db dump --db-url`.
7. Trigger `backup.yml` once and require SUCCESS through R2 object
   verification and marker update.
8. Trigger `backup_freshness_alert.yml` and require SUCCESS.
9. Perform the full disposable Supabase restore drill below.

## Restore drill

### Valid restore target

Use one of these, created specifically for the drill:

- a brand-new temporary Supabase project; or
- a fresh local Supabase stack initialized from an **empty project
  directory**, not from the Family Ops repository migrations.

The target must already contain Supabase-managed `auth` / `storage` schemas
and standard roles `anon`, `authenticated`, `service_role`, while containing
no Family Ops `public` / `private` tables and no Family Ops migration-history
rows.

Do **not** use a plain `postgres` Docker container. It lacks the managed
Supabase schemas/roles that the logical data and application grants expect.
Do **not** run the drill against production or any existing Family Ops
project.

Example local target:

```sh
mkdir -p /tmp/family-ops-restore-target
cd /tmp/family-ops-restore-target
supabase init
supabase start
supabase status
```

Use the local database URL reported by `supabase status` as
`--scratch-db-url`. Run `restore_drill.sh` from the Family Ops checkout.

### Running the drill

Set R2 read credentials in the local shell, retrieve the owner-held age key,
and run:

```sh
scripts/restore_drill.sh \
  --key-file /path/to/family-ops-backup-key.txt \
  --scratch-db-url "postgresql://...fresh-disposable-supabase-target..."
```

The script fails closed unless all of the following succeed:

1. refuses execution whenever `CI` is set;
2. proves `auth` / `storage` schemas and the three standard Supabase roles
   exist;
3. proves the target has zero `public` / `private` application tables and no
   existing migration-history rows;
4. resolves `latest-backup.txt` or a supplied `--backup-file`;
5. downloads a non-empty `*.tar.age` encrypted object;
6. decrypts locally using the owner-held private key;
7. requires the decrypted tar to contain **exactly** the five logical SQL
   members listed above;
8. restores in one transaction in this order:
   roles → application schema → migration-history schema →
   `session_replication_role=replica` → data → migration-history data;
9. requires a populated `supabase_migrations.schema_migrations` table;
10. requires all six representative core tables to exist;
11. requires numeric row counts, with non-zero foundational household/task
    rows;
12. requires a representative `task_instances.updated_at` timestamp.

Only then does it print `RESULT: PASS`.

### Backup naming / manual inspection

Backups are named:

```text
family-ops-backup-YYYY-MM-DD.tar.age
```

The current object name is line 1 of `latest-backup.txt`.

Manual download example:

```sh
aws s3 cp \
  s3://<bucket>/family-ops-backup-2026-09-09.tar.age . \
  --endpoint-url https://<R2_ACCOUNT_ID>.r2.cloudflarestorage.com
```

Manual local decryption example:

```sh
age -d -i /path/to/family-ops-backup-key.txt \
  -o family-ops-backup-2026-09-09.tar \
  family-ops-backup-2026-09-09.tar.age
```

Do not paste the private key into a shared terminal, CI log, chat, or script
that transmits it. Delete decrypted SQL/tar files after the drill because they
contain production data.

## Supabase Storage object scope

This WP10 control is a **database logical backup**. Supabase database dumps
can preserve Storage database metadata, but database backups do not contain
the binary objects stored by the Storage service itself. If Family Ops starts
using Supabase Storage for irreplaceable binary files, an object-backup control
must be added explicitly; do not describe this database backup as recovering
those blobs.

## Disaster recovery

A routine drill must never restore directly over production. For a genuine
loss/corruption event:

- preserve evidence/current broken state first;
- obtain a second person's confirmation when practical;
- restore into a **new Supabase project** first;
- run the same fail-closed sanity checks;
- verify Auth/application data and required provider configuration;
- only then perform a deliberate cutover/recovery action;
- after cutover, smoke-test sign-in, household loading and recent task data.

## Operational PASS evidence

CF-11 / WP10 is PASS only when all four evidence groups exist for the CURRENT
release state. Source review or green unit tests are not substitutes.

1. **Actual backup SUCCESS**
   - current `backup.yml` completed successfully;
   - all five Supabase logical members were non-empty;
   - age encryption produced a non-empty bundle;
   - R2 `head-object` verified the encrypted object;
   - marker update occurred only afterward.
2. **Actual freshness SUCCESS**
   - current `backup_freshness_alert.yml` completed successfully;
   - age is within the exact `MAX_BACKUP_AGE_HOURS` policy (default 26);
   - referenced encrypted object exists and is non-empty.
3. **Recoverable encrypted bundle evidenced**
   - restore drill downloads the marker-selected object;
   - owner-held age private key decrypts it locally;
   - bundle member contract validates.
4. **Isolated Supabase restore drill PASS**
   - target is a fresh disposable Supabase-compatible environment;
   - migration history, core schema, foundational rows and representative
     timestamp checks all pass;
   - script exits 0 and prints `RESULT: PASS`.

Record workflow run IDs/results and restore-drill date/result only. Never
record secret values, private keys, production connection strings or decrypted
data in GitHub/CI evidence.

## Release / monthly restore drill

Per WP10 and the release gate, repeat at least monthly and for release
readiness:

- [ ] Current `backup.yml` SUCCESS with all Supabase logical members and R2
      verification before marker update.
- [ ] Current `backup_freshness_alert.yml` SUCCESS within the exact 26-hour
      policy and referencing a non-empty encrypted object.
- [ ] Run `scripts/restore_drill.sh` against a fresh disposable Supabase
      target using the owner-held private key locally.
- [ ] Require exit 0 and `RESULT: PASS`.
- [ ] Compare latest restored migration with the expected release migration.
- [ ] Record only non-secret evidence.
- [ ] Treat any failure as release-blocking until a new backup + restore drill
      passes.

## Regression checks

`tests/operations/backup_controls_test.sh`, run by
`.github/workflows/operational-safety-ci.yml`, protects the repository-side
control logic. It verifies, among other things:

- exact freshness boundary behavior;
- missing/empty R2 objects;
- encrypted bundle naming;
- R2 verification before marker advancement;
- no raw production `pg_dump` path;
- pinned Supabase CLI + schema/data/migration-history dump contract;
- Supabase-compatible restore preflight and restore ordering;
- private age key exclusion from CI;
- restore refusal in CI.

These tests are necessary but do **not** prove CF-11 operational PASS; only
the runtime evidence above does.

## Secrets reference

| Secret name | Purpose | Where it is used |
| --- | --- | --- |
| `SUPABASE_DB_URL` | Production DB URI for pinned `supabase db dump` | `backup.yml` only |
| `BACKUP_AGE_PUBLIC_KEY` | age public recipient used to encrypt | `backup.yml` only |
| `R2_ACCOUNT_ID` | R2 endpoint account ID | backup/freshness workflows; local restore shell |
| `R2_ACCESS_KEY_ID` | Bucket-scoped R2 API access key | same |
| `R2_SECRET_ACCESS_KEY` | Bucket-scoped R2 API secret | same |
| `R2_BUCKET_NAME` | Private backup bucket (`family-ops-backups`) | same |

The age **private** key is deliberately absent: it is never a CI secret.
