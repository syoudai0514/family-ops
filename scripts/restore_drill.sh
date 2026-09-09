#!/usr/bin/env bash
# WP10 restore drill: download the latest (or a named) encrypted logical
# backup bundle from R2, decrypt it LOCALLY, restore it into a fresh
# disposable Supabase-compatible Postgres target, and run fail-closed
# schema/data sanity checks.
# See docs/BACKUP_RESTORE_RUNBOOK.md for the release/monthly checklist.
#
# ============================================================================
# SECURITY: this script must NEVER run in CI, and must NEVER accept the age
# private key via an environment variable. The age private key is a secret
# CI is not allowed to hold. It only exists in the household owner's own
# password manager / offline storage. This script only accepts the private
# key as:
#   (a) a local file path argument (--key-file <path>), or
#   (b) an interactive terminal prompt if --key-file is omitted.
# It deliberately does NOT read private-key environment variables. Do not
# weaken that boundary to automate the restore in CI.
# ============================================================================
#
# Usage:
#   scripts/restore_drill.sh [options]
#
# Options:
#   --key-file <path>       Path to a local age private key file (identity).
#                            If omitted, you will be prompted to paste the
#                            key interactively (input is not echoed).
#   --backup-file <name>    Specific backup object name in R2 to restore,
#                            e.g. family-ops-backup-2026-09-09.tar.age.
#                            Defaults to the latest one per latest-backup.txt.
#   --scratch-db-url <url>  Postgres connection string for a FRESH,
#                            disposable Supabase project/local stack.
#                            REQUIRED. Managed auth/storage schemas + standard
#                            Supabase roles must already exist, while Family
#                            Ops public/private tables must not.
#   -h, --help              Show this help.
#
# Required env (R2 read access only — never age keys):
#   R2_ACCOUNT_ID, R2_BUCKET_NAME, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY

set -euo pipefail

KEY_FILE=""
BACKUP_FILE=""
SCRATCH_DB_URL=""

usage() {
  sed -n '2,41p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --key-file)
      [ $# -ge 2 ] || { echo "ERROR: --key-file requires a value" >&2; exit 2; }
      KEY_FILE="$2"; shift 2 ;;
    --backup-file)
      [ $# -ge 2 ] || { echo "ERROR: --backup-file requires a value" >&2; exit 2; }
      BACKUP_FILE="$2"; shift 2 ;;
    --scratch-db-url)
      [ $# -ge 2 ] || { echo "ERROR: --scratch-db-url requires a value" >&2; exit 2; }
      SCRATCH_DB_URL="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -n "${CI:-}" ]; then
  echo "ERROR: refusing to run in a CI environment. This script decrypts backups with the owner's private key and must only be run by a human, locally." >&2
  exit 3
fi

if [ -z "$SCRATCH_DB_URL" ]; then
  echo "ERROR: --scratch-db-url is required. Point it at a fresh disposable Supabase-compatible database." >&2
  exit 2
fi

for v in R2_ACCOUNT_ID R2_BUCKET_NAME AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
  if [ -z "${!v:-}" ]; then
    echo "ERROR: required env var $v is not set" >&2
    exit 2
  fi
done

for cmd in aws age psql tar; do
  if ! command -v "$cmd" >/dev/null 2>&1; then
    echo "ERROR: required command '$cmd' not found on PATH" >&2
    exit 2
  fi
done

ENDPOINT_URL="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
WORKDIR="$(mktemp -d)"
cleanup() {
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

# --- 0. Prove the target is a fresh disposable Supabase environment ---------
# The backup contains Supabase Auth/Storage data and application SQL that
# references the standard Supabase roles. A vanilla PostgreSQL database is
# therefore not a valid recovery target. Conversely, a routine drill must
# never be aimed at an existing Family Ops environment.
SUPABASE_PREREQS="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c \
  "select
     to_regnamespace('auth') is not null
     and to_regnamespace('storage') is not null
     and to_regrole('anon') is not null
     and to_regrole('authenticated') is not null
     and to_regrole('service_role') is not null;")"
if [ "$SUPABASE_PREREQS" != "t" ]; then
  echo "ERROR: scratch target is not Supabase-compatible (auth/storage schemas and standard Supabase roles are required)." >&2
  exit 1
fi

EXISTING_APP_TABLES="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c \
  "select count(*) from pg_catalog.pg_tables where schemaname in ('public','private');")"
if ! [[ "$EXISTING_APP_TABLES" =~ ^[0-9]+$ ]]; then
  echo "ERROR: could not verify that Family Ops application schemas are empty." >&2
  exit 1
fi
if [ "$EXISTING_APP_TABLES" -ne 0 ]; then
  echo "ERROR: scratch target already has ${EXISTING_APP_TABLES} public/private tables. Refusing restore." >&2
  exit 1
fi

MIGRATION_TABLE_EXISTS="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c \
  "select to_regclass('supabase_migrations.schema_migrations') is not null;")"
if [ "$MIGRATION_TABLE_EXISTS" = "t" ]; then
  EXISTING_MIGRATIONS="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c \
    "select count(*) from supabase_migrations.schema_migrations;")"
  if ! [[ "$EXISTING_MIGRATIONS" =~ ^[0-9]+$ ]]; then
    echo "ERROR: could not verify migration-history emptiness." >&2
    exit 1
  fi
  if [ "$EXISTING_MIGRATIONS" -ne 0 ]; then
    echo "ERROR: scratch target already has ${EXISTING_MIGRATIONS} migration-history rows. Refusing restore." >&2
    exit 1
  fi
fi

echo "Scratch Supabase environment verified fresh for Family Ops restore."

# --- 1. Resolve which backup file to restore --------------------------------
if [ -z "$BACKUP_FILE" ]; then
  echo "No --backup-file given; looking up latest-backup.txt marker..."
  aws s3 cp "s3://${R2_BUCKET_NAME}/latest-backup.txt" "$WORKDIR/latest-backup.txt" \
    --endpoint-url "$ENDPOINT_URL"
  BACKUP_FILE="$(sed -n '1p' "$WORKDIR/latest-backup.txt")"
fi

if ! [[ "$BACKUP_FILE" =~ ^family-ops-backup-[0-9]{4}-[0-9]{2}-[0-9]{2}\.tar\.age$ ]]; then
  echo "ERROR: backup object name is malformed." >&2
  exit 1
fi
echo "Resolved encrypted backup object: $BACKUP_FILE"

# --- 2. Download the encrypted backup ---------------------------------------
echo "Downloading encrypted backup from R2..."
aws s3 cp "s3://${R2_BUCKET_NAME}/${BACKUP_FILE}" "$WORKDIR/backup.tar.age" \
  --endpoint-url "$ENDPOINT_URL"
test -s "$WORKDIR/backup.tar.age" || { echo "ERROR: downloaded encrypted backup is empty." >&2; exit 1; }

# --- 3. Obtain the age private key (local only, never from env) -------------
if [ -n "$KEY_FILE" ]; then
  if [ ! -f "$KEY_FILE" ]; then
    echo "ERROR: --key-file does not exist" >&2
    exit 2
  fi
  IDENTITY_FILE="$KEY_FILE"
else
  echo "Paste the age private key and press Enter. Input is not echoed."
  IDENTITY_FILE="$WORKDIR/identity.txt"
  read -r -s PASTED_KEY
  echo
  printf '%s\n' "$PASTED_KEY" > "$IDENTITY_FILE"
  chmod 600 "$IDENTITY_FILE"
  unset PASTED_KEY
fi

# --- 4. Decrypt and validate the logical bundle -----------------------------
echo "Decrypting locally..."
age -d -i "$IDENTITY_FILE" -o "$WORKDIR/backup.tar" "$WORKDIR/backup.tar.age"
test -s "$WORKDIR/backup.tar" || { echo "ERROR: decrypted backup bundle is empty." >&2; exit 1; }

EXPECTED_MEMBERS="$(printf '%s\n' data.sql history_data.sql history_schema.sql roles.sql schema.sql | sort)"
ACTUAL_MEMBERS="$(tar -tf "$WORKDIR/backup.tar" | sed 's#^\./##' | sort)"
if [ "$ACTUAL_MEMBERS" != "$EXPECTED_MEMBERS" ]; then
  echo "ERROR: decrypted backup bundle members do not match the required logical-backup contract." >&2
  exit 1
fi

mkdir "$WORKDIR/sql"
tar -xf "$WORKDIR/backup.tar" -C "$WORKDIR/sql"
for file in roles.sql schema.sql data.sql history_schema.sql history_data.sql; do
  test -s "$WORKDIR/sql/$file" || { echo "ERROR: logical backup member $file is empty." >&2; exit 1; }
done

# --- 5. Restore in Supabase's documented logical order ----------------------
echo "Restoring into disposable Supabase environment..."
psql "$SCRATCH_DB_URL" \
  --single-transaction \
  --variable ON_ERROR_STOP=1 \
  --file "$WORKDIR/sql/roles.sql" \
  --file "$WORKDIR/sql/schema.sql" \
  --file "$WORKDIR/sql/history_schema.sql" \
  --command 'SET session_replication_role = replica' \
  --file "$WORKDIR/sql/data.sql" \
  --file "$WORKDIR/sql/history_data.sql" \
  --command 'SET session_replication_role = origin' \
  >/dev/null

# --- 6. Fail-closed sanity checks -------------------------------------------
echo "Running restore sanity checks..."

MIGRATION_TABLE="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c \
  "select to_regclass('supabase_migrations.schema_migrations') is not null;")"
if [ "$MIGRATION_TABLE" != "t" ]; then
  echo "ERROR: restored migration tracking table is missing." >&2
  exit 1
fi

LATEST_MIGRATION="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c \
  "select version from supabase_migrations.schema_migrations order by version desc limit 1;")"
if [ -z "$LATEST_MIGRATION" ]; then
  echo "ERROR: restored migration tracking table has no version rows." >&2
  exit 1
fi
printf 'Latest restored migration: %s\n' "$LATEST_MIGRATION"

CORE_TABLES=(households household_members task_definitions task_instances handovers user_notifications)
for table in "${CORE_TABLES[@]}"; do
  EXISTS="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c \
    "select to_regclass('public.${table}') is not null;")"
  if [ "$EXISTS" != "t" ]; then
    echo "ERROR: restored core table public.${table} is missing." >&2
    exit 1
  fi

  COUNT="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c \
    "select count(*) from public.${table};")"
  if ! [[ "$COUNT" =~ ^[0-9]+$ ]]; then
    echo "ERROR: could not obtain a numeric row count for public.${table}." >&2
    exit 1
  fi
  printf 'Restored row count %-24s %s\n' "${table}:" "$COUNT"

  case "$table" in
    households|household_members|task_definitions|task_instances)
      if [ "$COUNT" -le 0 ]; then
        echo "ERROR: foundational table public.${table} unexpectedly has zero rows." >&2
        exit 1
      fi
      ;;
  esac
done

LATEST_TASK_UPDATE="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c \
  "select max(updated_at) from public.task_instances;")"
if [ -z "$LATEST_TASK_UPDATE" ]; then
  echo "ERROR: representative task_instances.updated_at sanity check returned no value." >&2
  exit 1
fi
printf 'Representative task timestamp: %s\n' "$LATEST_TASK_UPDATE"

echo "RESULT: PASS — encrypted Supabase logical bundle decrypted, restored into a fresh disposable Supabase environment, and schema/data sanity checks passed."
