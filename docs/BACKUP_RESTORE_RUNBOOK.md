# Backup / Restore Runbook

This is the operational runbook for WP10 (`docs/design/v6/10_WORK_PACKAGES.md`
"WP10 — Backup / recovery"). It is not part of the vendored v6 design
package — do not edit `docs/design/v6/`; if this runbook and v6 ever seem to
disagree, v6 wins and this file gets fixed.

## How the backup system works (summary)

1. `.github/workflows/backup.yml` runs daily (18:00 UTC / 03:00 JST) in
   GitHub Actions: `pg_dump`s the production Supabase Postgres database,
   encrypts the dump with [`age`](https://github.com/FiloSottile/age) using
   **only the public key**, and uploads the encrypted file to a private
   Cloudflare R2 bucket. It also writes/overwrites a small `latest-backup.txt`
   marker object recording the newest backup's filename and timestamp.
2. `.github/workflows/backup_freshness_alert.yml` runs a few hours later and
   fails (red CI run = the MVP alert) if the marker's timestamp is more than
   26 hours old. `scripts/backup_freshness_check.sh` is the script it calls;
   it can also be run manually or from any other monitoring you set up.
3. Restoring a backup is a **manual, local, human-operated** procedure —
   see below. It is intentionally never automatable from CI.

## The core security property — read this before touching backup.yml

CI holds the `age` **public** key (`BACKUP_AGE_PUBLIC_KEY`) only. A public
key can encrypt but cannot decrypt. Even if GitHub Actions secrets for this
repo were ever fully compromised, an attacker could not decrypt a single
backup with what CI holds.

The `age` **private** key is held **only** by the household owner, in their
own password manager or offline storage (e.g. a printed/engraved backup, a
hardware-backed secrets manager). It is:

- **never** stored as a GitHub Actions secret (repo or org level),
- **never** committed to this repository in any form,
- **never** referenced by name in any workflow file,
- **never** accepted by `scripts/restore_drill.sh` via an environment
  variable — only via a local file path argument or an interactive prompt,
  specifically so it cannot be casually wired into a CI secret later.

If a future change proposes adding the private key to CI "to automate
restores," that is a regression of this design — stop and re-read this
section, and WP10 in `docs/design/v6/10_WORK_PACKAGES.md`.

## One-time setup (human, not automatable)

1. **Generate the age keypair**, on the owner's own machine, once:
   ```sh
   age-keygen -o family-ops-backup-key.txt
   ```
   This prints a line like `Public key: age1...` and writes the private key
   (`AGE-SECRET-KEY-1...`) into `family-ops-backup-key.txt`.
2. **Store the private key file** in the owner's password manager (e.g. as
   a secure note/attachment) or another offline location the owner
   controls. Do not leave a bare copy on a machine that syncs to this repo
   or to any CI-accessible location. Then delete the local plaintext file.
3. **Add the public key** as a GitHub Actions secret named
   `BACKUP_AGE_PUBLIC_KEY` (repo Settings -> Secrets and variables ->
   Actions). Value is just the `age1...` line.
4. **Create the R2 bucket** (`family-ops-backups`, Standard storage class,
   per v6 section 10), private/no public access, in the Cloudflare
   dashboard.
5. **Create an R2 API token** (Cloudflare dashboard -> R2 -> Manage API
   tokens) scoped to that bucket only, with read+write permissions. Add its
   Account ID, Access Key ID, and Secret Access Key as GitHub Actions
   secrets: `R2_ACCOUNT_ID`, `R2_ACCESS_KEY_ID`, `R2_SECRET_ACCESS_KEY`.
   Add the bucket name as `R2_BUCKET_NAME` (a repo variable or secret,
   either works — value is not sensitive but isn't hardcoded so bucket
   renames don't require editing workflow YAML).
6. **Add the production DB connection string** as `SUPABASE_DB_URL` (repo
   secret) — from the Supabase dashboard, Project Settings -> Database ->
   Connection string (URI). Use the direct/session connection, not the
   transaction-mode pgbouncer pooler port, since `pg_dump` needs a plain
   session-level connection.
7. Trigger `backup.yml` manually once (`workflow_dispatch`) and confirm a
   `family-ops-backup-YYYY-MM-DD.sql.age` object and an updated
   `latest-backup.txt` appear in the R2 bucket.
8. Run a full restore drill (below) against a scratch database to confirm
   the whole pipeline actually works end to end, before relying on it.

## Restoring a backup

### Locating and downloading the backup

Backups live in the R2 bucket named by `R2_BUCKET_NAME`, as objects named
`family-ops-backup-YYYY-MM-DD.sql.age`. The most recent filename is also
recorded in `latest-backup.txt` in the same bucket. Download with the AWS
CLI pointed at R2's S3-compatible endpoint:

```sh
aws s3 cp s3://<bucket>/family-ops-backup-2026-08-18.sql.age . \
  --endpoint-url https://<R2_ACCOUNT_ID>.r2.cloudflarestorage.com
```

(Any S3-compatible client works — `rclone`, the Cloudflare dashboard's
object browser, etc. `aws s3` is what `backup.yml` and
`scripts/restore_drill.sh` use for consistency.)

### Decrypting — always local, never in CI

```sh
age -d -i /path/to/family-ops-backup-key.txt \
  -o family-ops-backup-2026-08-18.sql \
  family-ops-backup-2026-08-18.sql.age
```

Run this on the owner's own machine, with the private key file retrieved
from the owner's password manager for this purpose only. Do not paste the
private key into any shared terminal, CI log, chat tool, or script that
sends it anywhere. Delete the plaintext `.sql` file once you're done with
it (it contains full production data).

### Restoring into a database

**Default / drill case — restore into a scratch database.** Use a fresh
local Postgres (e.g. `docker run --rm -e POSTGRES_PASSWORD=postgres -p
5433:5432 postgres:16`) or a disposable Supabase/hosted instance created
specifically for the drill. Never point a routine drill at production.

```sh
psql "postgresql://postgres:postgres@localhost:5433/postgres" \
  -v ON_ERROR_STOP=1 -f family-ops-backup-2026-08-18.sql
```

`scripts/restore_drill.sh` automates the download + decrypt + restore +
sanity-check sequence above end to end — see its `--help` output. It
refuses to run under `CI=true` and never reads the private key from an
environment variable, by design.

**Disaster-recovery case — restoring into production.** Only do this when
production data is genuinely lost or corrupted and this is a deliberate
recovery action, not a drill. Extra caution required:

- Get a second person's confirmation before running anything against
  production, if at all possible.
- Take note of (or freeze) the current broken state first, in case partial
  data recovery from it is later useful — don't destroy evidence of what
  went wrong.
- Restore into a **new** Supabase project or a temporary side database
  first if you can, verify it there, and only then cut production over —
  restoring directly on top of a live production database is a last
  resort, not the default path.
- After restoring, re-run every sanity check below, then also manually spot
  check the app itself (sign in, load a household, check recent tasks)
  before declaring the incident resolved.

### Verifying the restore (sanity checks)

At minimum, after any restore:

1. **Migration version** — confirm `supabase_migrations.schema_migrations`
   (or your migration tracking table) shows the expected latest migration
   version, matching `supabase/migrations/` in this repo at the time the
   backup was taken.
2. **Row counts** on core tables — `households`, `household_members`,
   `task_definitions`, `task_instances`, `handovers`, `user_notifications`
   — sanity-check counts are non-zero and roughly in line with expectations
   (not a truncated/partial dump).
3. **Spot-check a recent row** in `task_instances` or `handovers` and
   confirm its timestamp is close to the backup's own date — confirms the
   dump wasn't stale or from the wrong database.

`scripts/restore_drill.sh` runs (1) and (2) automatically and prints the
results for review.

## Release / monthly restore drill (recurring checklist item)

Per v6 (`docs/design/v6/10_WORK_PACKAGES.md` WP10 "release/monthly restore
drill" and WP11's production checklist "backup/restore drill green"), this
must be **rehearsed periodically by a human** — no script can force this to
happen on its own. Add it to the release checklist and repeat it at least
monthly in production:

- [ ] Run `scripts/restore_drill.sh` against a scratch database (not
      production) using the current private key from the owner's password
      manager.
- [ ] Confirm the migration version sanity check matches the latest
      migration in `supabase/migrations/`.
- [ ] Confirm row counts on core tables look reasonable (non-zero, roughly
      consistent with known household/task volume).
- [ ] Confirm `backup_freshness_alert.yml`'s most recent scheduled run is
      green (backup pipeline is actually producing fresh backups, not just
      that a restore of an old backup worked).
- [ ] If anything in this drill fails or looks wrong, treat it as a P1: a
      backup system nobody has verified restores is not a backup system.

## Secrets reference

| Secret name | Purpose | Where it's used |
| --- | --- | --- |
| `SUPABASE_DB_URL` | Production Postgres connection string, for `pg_dump` | `backup.yml` only |
| `BACKUP_AGE_PUBLIC_KEY` | age public key (recipient) — encrypts backups | `backup.yml` only |
| `R2_ACCOUNT_ID` | Cloudflare account ID, used to build the R2 S3-compatible endpoint URL | `backup.yml`, `backup_freshness_alert.yml`, `scripts/restore_drill.sh` (local) |
| `R2_ACCESS_KEY_ID` | R2 API token access key (bucket-scoped) | same as above |
| `R2_SECRET_ACCESS_KEY` | R2 API token secret | same as above |
| `R2_BUCKET_NAME` | Target bucket name (`family-ops-backups`) | same as above |

The age **private** key is deliberately absent from this table — it is
never a CI secret. See "The core security property" above.
