# Backup / Restore Runbook

This is the operational runbook for WP10 (`docs/design/v6/10_WORK_PACKAGES.md`
"WP10 — Backup / recovery"). It is not part of the vendored v6 design
package — do not edit `docs/design/v6/`; if this runbook and v6 ever seem to
disagree, v6 wins and this file gets fixed.

## How the backup system works (summary)

1. `.github/workflows/backup.yml` runs daily (18:00 UTC / 03:00 JST) in
   GitHub Actions: `pg_dump`s the production Supabase Postgres database,
   encrypts the dump with [`age`](https://github.com/FiloSottile/age) using
   **only the public key**, uploads the encrypted file to a private
   Cloudflare R2 bucket, and then verifies the uploaded R2 object is present
   and non-empty with `head-object`. Only after that verification succeeds
   does it write/overwrite `latest-backup.txt` with the verified backup's
   filename and timestamp.
2. `.github/workflows/backup_freshness_alert.yml` runs a few hours later.
   `scripts/backup_freshness_check.sh` fails unless both of these are true:
   the marker timestamp is within the 26-hour policy and the encrypted R2
   object named by that marker still exists and is non-empty. A fresh marker
   pointing at a missing object is RED, not fresh.
3. Restoring a backup is a **manual, local, human-operated** procedure. It
   is intentionally never automatable from CI because decryption requires
   the owner's private age key.

Workflow YAML correctness alone is not operational proof. See **Operational
PASS evidence** below.

## The core security property — read this before touching backup.yml

CI holds the `age` **public** key (`BACKUP_AGE_PUBLIC_KEY`) only. A public
key can encrypt but cannot decrypt. Even if GitHub Actions secrets for this
repo were compromised, the backup decryption key must remain unavailable to
CI.

The `age` **private** key is held **only** by the household owner, in their
own password manager or offline storage. It is:

- **never** stored as a GitHub Actions secret (repo or org level),
- **never** committed to this repository in any form,
- **never** referenced by name in any workflow file,
- **never** accepted by `scripts/restore_drill.sh` via an environment
  variable — only via a local file path argument or an interactive prompt.

If a future change proposes adding the private key to CI "to automate
restores," that is a regression of this design — stop and re-read this
section and WP10 in `docs/design/v6/10_WORK_PACKAGES.md`.

## One-time setup (human, not automatable)

1. **Generate the age keypair** on the owner's own machine, once:
   ```sh
   age-keygen -o family-ops-backup-key.txt
   ```
   The command prints a public recipient (`age1...`) and writes the private
   identity to the file.
2. **Store the private key file** in the owner's password manager or another
   offline location the owner controls. Do not leave a bare copy on a
   machine/location that syncs to the repo or CI. Delete unnecessary local
   plaintext copies.
3. **Add only the public key** as the GitHub Actions repository secret
   `BACKUP_AGE_PUBLIC_KEY`.
4. **Create the private R2 bucket** `family-ops-backups` (Standard storage,
   no public access) in Cloudflare R2.
5. **Create a bucket-scoped R2 API token** with read+write access. Add these
   GitHub Actions repository secrets:
   - `R2_ACCOUNT_ID`
   - `R2_ACCESS_KEY_ID`
   - `R2_SECRET_ACCESS_KEY`
   - `R2_BUCKET_NAME` (normally `family-ops-backups`; the value is not
     sensitive, but the current workflows read it from repository secrets)
6. **Add the production DB connection string** as the repository secret
   `SUPABASE_DB_URL`, from Supabase project Database connection settings.
   Use a direct/session connection suitable for `pg_dump`, not a
   transaction-mode pooler connection.
7. Trigger `backup.yml` manually once and require the workflow to complete
   successfully. A successful run proves the dump was non-empty, encryption
   produced a non-empty artifact, the encrypted object reached R2 and was
   confirmed by R2, and the marker was advanced only afterward.
8. Trigger `backup_freshness_alert.yml` and require it to complete
   successfully. This separately proves the marker age is within policy and
   the marker still resolves to a non-empty encrypted R2 object.
9. Run the full local restore drill below against an empty disposable
   database. Do not rely on the backup until this passes.

## Restoring a backup

### Default: use the fail-closed restore drill

Use a fresh local Postgres database or a disposable hosted database created
specifically for the drill. `scripts/restore_drill.sh` mechanically refuses
any target database that already contains non-system tables, which prevents
a routine drill from being aimed at an existing application database.

Example local scratch database:

```sh
docker run --rm --name family-ops-restore-drill \
  -e POSTGRES_PASSWORD=postgres -p 5433:5432 postgres:17
```

Set the R2 read credentials in the local shell, retrieve the private age key
from the owner's password manager, and run:

```sh
scripts/restore_drill.sh \
  --key-file /path/to/family-ops-backup-key.txt \
  --scratch-db-url "postgresql://postgres:postgres@localhost:5433/postgres"
```

The script:

1. refuses to run when `CI` is set;
2. confirms the scratch database has zero non-system tables before writing;
3. resolves `latest-backup.txt` (or a named `--backup-file`);
4. downloads and requires a non-empty encrypted object;
5. decrypts locally with the owner-held key and requires non-empty SQL;
6. restores with `psql -v ON_ERROR_STOP=1`;
7. requires a populated `supabase_migrations.schema_migrations` table;
8. requires all six core tables to exist;
9. requires numeric row counts for all six, and non-zero rows for the
   foundational tables `households`, `household_members`,
   `task_definitions`, and `task_instances`;
10. requires a representative `task_instances.updated_at` timestamp.

Only after every hard check passes does it print `RESULT: PASS`. It prints
counts/timestamps only; it does not dump representative household/user row
contents into logs.

### Locating/downloading manually

Backups are named `family-ops-backup-YYYY-MM-DD.sql.age`. The current object
name is line 1 of `latest-backup.txt`.

```sh
aws s3 cp s3://<bucket>/family-ops-backup-2026-08-18.sql.age . \
  --endpoint-url https://<R2_ACCOUNT_ID>.r2.cloudflarestorage.com
```

### Decrypting manually — always local, never in CI

```sh
age -d -i /path/to/family-ops-backup-key.txt \
  -o family-ops-backup-2026-08-18.sql \
  family-ops-backup-2026-08-18.sql.age
```

Do not paste the private key into a shared terminal, CI log, chat tool, or
script that transmits it. Delete plaintext SQL after the drill; it contains
production data.

### Disaster-recovery case

A routine drill must never restore directly over production. If production
data is genuinely lost/corrupted:

- obtain a second person's confirmation when possible;
- preserve evidence/current broken state first;
- restore to a **new** Supabase project or temporary side database first;
- run the same fail-closed sanity checks there;
- only then perform a deliberate cutover/recovery action;
- after cutover, smoke-test sign-in, household loading and recent task data
  before declaring recovery complete.

## Operational PASS evidence

CF-11 / WP10 is PASS only when all four evidence groups exist for the
CURRENT release state. Do not substitute source review or a green unit test
for these runtime proofs.

1. **Actual backup SUCCESS**
   - a current `backup.yml` run completed successfully;
   - the log reached the R2 `head-object` verification step;
   - the verified encrypted object is non-empty;
   - the marker update happened after object verification.
2. **Actual freshness SUCCESS**
   - a current `backup_freshness_alert.yml` run completed successfully;
   - the computed age is within `MAX_BACKUP_AGE_HOURS` (default 26);
   - the referenced encrypted object exists and is non-empty.
3. **Recoverable encrypted object evidenced**
   - the restore drill downloads the object named by the marker and age can
     decrypt it using the owner-held private key locally.
4. **Isolated restore drill PASS**
   - restore targets an empty disposable database;
   - migration tracking, core schema, foundational rows and representative
     task timestamp checks all pass;
   - the script exits 0 and prints `RESULT: PASS`.

Record workflow run IDs/results and the restore-drill date/result in the
release evidence. Never record secret values, the private key, production
connection strings, or decrypted data in GitHub/CI evidence.

## Release / monthly restore drill

Per WP10 and the release gate, repeat at least monthly and for release
readiness:

- [ ] Current `backup.yml` run is successful and includes R2 object
      verification before marker update.
- [ ] Current `backup_freshness_alert.yml` run is successful; marker age is
      within policy and points at a non-empty encrypted object.
- [ ] Run `scripts/restore_drill.sh` against an empty disposable database
      using the owner-held private key locally.
- [ ] Require exit 0 and `RESULT: PASS`.
- [ ] Compare the restored latest migration with the expected migration for
      the backup/release being exercised.
- [ ] Record only non-secret evidence (run IDs, timestamps, PASS/FAIL,
      restored migration version and aggregate counts if appropriate).
- [ ] Any failure is release-blocking until a fresh backup plus restore drill
      passes.

## Regression checks

`tests/operations/backup_controls_test.sh`, run by
`.github/workflows/operational-safety-ci.yml`, protects the repository-side
control logic. It tests missing configuration, stale/future/malformed
markers, missing/empty R2 objects, the success path, and the restore script's
CI refusal. These tests are necessary but **do not** prove CF-11 operational
PASS; only the runtime evidence above does.

## Secrets reference

| Secret name | Purpose | Where it is used |
| --- | --- | --- |
| `SUPABASE_DB_URL` | Production Postgres connection for `pg_dump` | `backup.yml` only |
| `BACKUP_AGE_PUBLIC_KEY` | age public recipient used to encrypt | `backup.yml` only |
| `R2_ACCOUNT_ID` | R2 endpoint account ID | backup/freshness workflows; local restore shell |
| `R2_ACCESS_KEY_ID` | Bucket-scoped R2 API access key | same |
| `R2_SECRET_ACCESS_KEY` | Bucket-scoped R2 API secret | same |
| `R2_BUCKET_NAME` | Private backup bucket (`family-ops-backups`) | same |

The age **private** key is deliberately absent: it is never a CI secret.
