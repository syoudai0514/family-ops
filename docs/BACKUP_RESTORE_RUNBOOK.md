# Backup / Restore Runbook

This is the operational runbook for WP10 (`docs/design/v6/10_WORK_PACKAGES.md`
"WP10 — Backup / recovery"). It is not part of the vendored v6 design
package — do not edit `docs/design/v6/`; if this runbook and v6 ever seem to
disagree, v6 wins and this file gets fixed.

## Product outcome first

The point of this control is not to produce a technically valid backup file.
It is to let the household resume using Family Ops after a severe data-loss
incident without changing the approved daily LINE/PWA experience beforehand.
A restore is therefore not PASS unless household data, Supabase Auth identity
linkage and the representative operational state needed to use the app are
coherent after restore.

Family Ops also depends on scheduled workers for LINE inbox processing,
notification delivery, pending actions, routines, recurrence and calendar
outbox processing. Recovery must not copy production worker commands blindly
into a new Supabase project: those commands are environment-specific and may
point at the old project or carry old worker authentication. A routine restore
drill therefore proves that **zero Family Ops cron jobs** were restored. A real
disaster cutover recreates the six reviewed jobs against the new target only
after the recovered data and target configuration have been validated.

## How the backup system works

1. `.github/workflows/backup.yml` runs daily (18:00 UTC / 03:00 JST).
2. It uses pinned Supabase CLI `2.115.0`, matching the version already proven
   by this repository's real Supabase integration CI, rather than raw
   `pg_dump`, to build a Supabase-compatible logical backup. The bundle
   contains exactly:
   - `roles.sql`
   - `schema.sql`
   - `data.sql`
   - `history_schema.sql`
   - `history_data.sql`
3. `schema.sql` uses Supabase CLI's managed-platform schema filtering. In the
   pinned CLI `2.115.0`, the generic **data** dump deliberately includes Auth
   and Storage database rows for migration to a new project. Family Ops relies
   on that behavior for `auth.users` / `auth.identities` recovery. The backup
   explicitly excludes environment-specific/transient worker data:
   - `cron.job`
   - `cron.job_run_details`
   - `net.http_request_queue`
   - `net._http_response`
   Migration history is dumped separately because the normal filtered schema
   dump does not by itself preserve
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

The target must already contain:

- Supabase-managed `auth` / `storage` schemas;
- standard roles `anon`, `authenticated`, `service_role`;
- `pg_cron` (`cron.job`);
- `pg_net` (`net.http_request_queue`);
- Supabase Vault (`vault.decrypted_secrets`).

It must contain no Family Ops `public` / `private` tables, no Family Ops
migration-history rows and no `family-ops-%` cron jobs.

Do **not** use a plain `postgres` Docker container. It lacks the managed
Supabase schemas/roles/extensions that the logical data and recovery workflow
expect. Do **not** run the drill against production or any existing Family Ops
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
2. proves `auth` / `storage`, standard Supabase roles, pg_cron, pg_net and
   Vault exist;
3. proves the target has zero `public` / `private` application tables, no
   existing migration-history rows and no existing Family Ops cron jobs;
4. resolves `latest-backup.txt` or a supplied `--backup-file`;
5. downloads a non-empty `*.tar.age` encrypted object;
6. decrypts locally using the owner-held private key;
7. requires the decrypted tar to contain **exactly** the five logical SQL
   members listed above;
8. restores in one transaction in this order:
   roles → application schema → migration-history schema →
   `session_replication_role=replica` → data → migration-history data;
9. proves **zero `family-ops-%` cron jobs** were restored, so the drill cannot
   accidentally invoke old-environment workers;
10. requires a populated `supabase_migrations.schema_migrations` table;
11. requires all six representative core tables to exist;
12. requires numeric row counts, with non-zero foundational household/task
    rows;
13. requires restored `auth.users`, `auth.identities` and `public.profiles`
    to be non-empty for the current household state;
14. rejects any restored `household_members` or `profiles` row whose `user_id`
    does not resolve to `auth.users`, and rejects a household member without a
    corresponding `auth.identities` row;
15. requires a representative `task_instances.updated_at` timestamp.

Only then does it print `RESULT: PASS`. These identity checks matter because
the restore data phase deliberately disables triggers/FK enforcement: without
the explicit post-restore checks, public household rows could look present
while the family could no longer authenticate into them.

### Backup naming / manual inspection

Backups are named `family-ops-backup-YYYY-MM-DD.tar.age`. The current object
name is line 1 of `latest-backup.txt`.

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

## Worker reconfiguration after disaster recovery

A normal restore drill stops with zero Family Ops cron jobs. It must **not**
activate workers or send LINE/notification/calendar traffic.

For a genuine recovery cutover, after the database restore is validated and
the CURRENT Family Ops Edge Functions have been deployed to the new Supabase
project, create a **new** recovery worker token. Do not reuse or export a token
from the failed project.

1. Set the new token as Edge Function secret `CRON_WORKER_TOKEN` on the target.
2. Store the new target project URL in Supabase Vault under the unique name
   `family_ops_project_url`.
3. Store the same new worker token in Vault under the unique name
   `family_ops_worker_token`.
4. Run:
   ```sh
   psql "<fresh-recovery-target-db-url>" \
     -v ON_ERROR_STOP=1 \
     -f scripts/reconfigure_recovery_workers.sql
   ```
5. Require exactly these six active jobs:

| Job | Schedule | Edge Function |
| --- | --- | --- |
| `family-ops-calendar-outbox-v1` | `* * * * *` | `process-family-ops-calendar-outbox` |
| `family-ops-line-delivery-v1` | `* * * * *` | `send-notifications` |
| `family-ops-line-inbox-v1` | `* * * * *` | `process-line-inbox` |
| `family-ops-materialize-recurring-v1` | `10 15 * * *` | `materialize-recurring` |
| `family-ops-pending-actions-v1` | `* * * * *` | `process-pending-actions` |
| `family-ops-routine-dispatch-v1` | `* * * * *` | `dispatch-routine-automation` |

The SQL file contains only this non-secret contract. At invocation time each
job reads the **target-local** URL/token from `vault.decrypted_secrets` and
sends the token as `X-Family-Ops-Worker-Token`, matching the worker
authentication contract in `supabase/functions/_shared/auth.ts`.

Before declaring household recovery complete, verify successful worker runs
against the **new** target and perform representative real-use smoke checks.
Do not enable a job merely because its name exists; a job pointed at the old
project is a recovery failure.

## Supabase Auth reconfiguration after disaster recovery

Database recovery preserves the user/authentication records that are part of
the logical database migration, but a newly created Supabase project still has
its own project-level Auth configuration/API keys. Before cutover:

- configure the same sign-in provider/redirect settings required by Family Ops;
- update application/provider configuration for the new Supabase project;
- do not assume an access token issued by the old project remains valid on the
  new project; require a normal sign-in again when the target uses a different
  JWT signing secret;
- smoke-test an actual sign-in, household load and recent task access before
  declaring household recovery complete.

This is not a new daily-user step. It is a disaster-recovery operator step so
that restored data is actually usable by the family.

## Supabase Storage object scope

This WP10 control is a **database logical backup**. Supabase database dumps
can preserve Storage database metadata, but database backups do not contain
the binary objects stored by the Storage service itself. If Family Ops stores
**irreplaceable household binaries** in Storage, an object-backup control must
be added explicitly; do not describe this database backup as recovering those
blobs.

Current runtime evidence inspected during CF-11 showed the household-facing
`nursery-source` bucket empty; the existing non-empty objects were in
handoff/evidence-oriented buckets. That observation is current-state evidence,
not a permanent exemption: if real nursery or other irreplaceable household
files begin accumulating, the backup requirement must be revisited.

## Disaster recovery

A routine drill must never restore directly over production. For a genuine
loss/corruption event:

- preserve evidence/current broken state first;
- obtain a second person's confirmation when practical;
- restore into a **new Supabase project** first;
- run the same fail-closed sanity checks, including Auth identity linkage and
  zero restored Family Ops cron jobs;
- deploy CURRENT Edge Functions to the new project;
- configure the target project's Auth/provider/API settings;
- create a NEW worker token, store target URL/token in Vault and run
  `scripts/reconfigure_recovery_workers.sql`;
- verify exactly six active Family Ops jobs on the target and successful target
  worker runs;
- only then perform a deliberate cutover/recovery action;
- after cutover, smoke-test sign-in, household loading and recent task data;
- smoke-test the daily operational paths that depend on workers: LINE intake,
  notification delivery and routine/recurrence processing as applicable.

## Operational PASS evidence

CF-11 / WP10 is PASS only when all four evidence groups exist for the CURRENT
release state. Source review or green unit tests are not substitutes.

1. **Actual backup SUCCESS**
   - current `backup.yml` completed successfully;
   - all five Supabase logical members were non-empty;
   - environment-specific cron/net operational tables were excluded;
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
   - migration history, core schema and foundational rows pass;
   - restored Auth users/identities and Family Ops member/profile linkage pass;
   - no Family Ops production cron job was restored;
   - representative task timestamp passes;
   - script exits 0 and prints `RESULT: PASS`.

For an actual disaster cutover, operational recovery additionally requires
target provider/Auth configuration, deployment of CURRENT Edge Functions, six
target-local worker jobs, and real-use smoke.

Record workflow run IDs/results and restore-drill date/result only. Never
record secret values, private keys, production connection strings or decrypted
data in GitHub/CI evidence.

## Release / monthly restore drill

Per WP10 and the release gate, repeat at least monthly and for release
readiness:

- [ ] Current `backup.yml` SUCCESS with all Supabase logical members, cron/net
      exclusions and R2 verification before marker update.
- [ ] Current `backup_freshness_alert.yml` SUCCESS within the exact 26-hour
      policy and referencing a non-empty encrypted object.
- [ ] Run `scripts/restore_drill.sh` against a fresh disposable Supabase
      target using the owner-held private key locally.
- [ ] Require exit 0 and `RESULT: PASS`, including Auth identity linkage and
      zero restored Family Ops cron jobs.
- [ ] Compare latest restored migration with the expected release migration.
- [ ] Do not run the worker-reconfiguration SQL in a routine drill.
- [ ] For disaster recovery only, deploy/configure the new target, create a new
      worker token, install the six target-local jobs and verify real-use smoke.
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
- mandatory exclusion of cron job/history and pg_net queue/response state;
- Supabase-compatible restore preflight and restore ordering;
- post-restore Auth user/identity and Family Ops linkage guards;
- zero old Family Ops cron jobs after routine restore;
- six-worker disaster-recovery SQL contract using Vault rather than embedded
  project URL/worker secret;
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

Disaster recovery also creates a **new target-local** `CRON_WORKER_TOKEN` and
stores the same value in target Vault as `family_ops_worker_token`; neither
value belongs in this repository, GitHub Actions backup secrets, chat, or logs.
The age **private** key is deliberately absent: it is never a CI secret.
