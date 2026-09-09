#!/usr/bin/env bash
# WP10 restore drill: download the latest (or a named) encrypted backup
# from R2, decrypt it LOCALLY, restore it into a scratch/disposable
# Postgres database, and run fail-closed schema/data sanity checks.
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
#                            e.g. family-ops-backup-2026-08-18.sql.age.
#                            Defaults to the latest one per latest-backup.txt.
#   --scratch-db-url <url>  Postgres connection string for an EMPTY,
#                            disposable database. REQUIRED. The script
#                            refuses a scratch DB that already contains
#                            non-system tables.
#   -h, --help              Show this help.
#
# Required env (R2 read access only — never age keys):
#   R2_ACCOUNT_ID, R2_BUCKET_NAME, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY

set -euo pipefail

KEY_FILE=""
BACKUP_FILE=""
SCRATCH_DB_URL=""

usage() {
  sed -n '2,38p' "$0" | sed 's/^# \{0,1\}//'
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
  echo "ERROR: --scratch-db-url is required. Point it at an empty disposable Postgres database." >&2
  exit 2
fi

for v in R2_ACCOUNT_ID R2_BUCKET_NAME AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
  if [ -z "${!v:-}" ]; then
    echo "ERROR: required env var $v is not set" >&2
    exit 2
  fi
done

for cmd in aws age psql; do
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

# --- 0. Prove the target is disposable before writing anything --------------
# A restore drill must never be pointed at an existing application database.
# Requiring zero non-system tables gives us a mechanical guardrail rather than
# relying on a warning in prose.
EXISTING_USER_TABLES="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c \
  "select count(*) from pg_catalog.pg_tables where schemaname not in ('pg_catalog','information_schema');")"
if ! [[ "$EXISTING_USER_TABLES" =~ ^[0-9]+$ ]]; then
  echo "ERROR: could not verify that the scratch database is empty." >&2
  exit 1
fi
if [ "$EXISTING_USER_TABLES" -ne 0 ]; then
  echo "ERROR: scratch database is not empty (${EXISTING_USER_TABLES} non-system tables found). Refusing restore." >&2
  exit 1
fi

echo "Scratch database verified empty."

# --- 1. Resolve which backup file to restore --------------------------------
if [ -z "$BACKUP_FILE" ]; then
  echo "No --backup-file given; looking up latest-backup.txt marker..."
  aws s3 cp "s3://${R2_BUCKET_NAME}/latest-backup.txt" "$WORKDIR/latest-backup.txt" \
    --endpoint-url "$ENDPOINT_URL"
  BACKUP_FILE="$(sed -n '1p' "$WORKDIR/latest-backup.txt")"
fi

if ! [[ "$BACKUP_FILE" =~ ^family-ops-backup-[0-9]{4}-[0-9]{2}-[0-9]{2}\.sql\.age$ ]]; then
  echo "ERROR: backup object name is malformed." >&2
  exit 1
fi
echo "Resolved encrypted backup object: $BACKUP_FILE"

# --- 2. Download the encrypted backup ---------------------------------------
echo "Downloading encrypted backup from R2..."
aws s3 cp "s3://${R2_BUCKET_NAME}/${BACKUP_FILE}" "$WORKDIR/backup.sql.age" \
  --endpoint-url "$ENDPOINT_URL"
test -s "$WORKDIR/backup.sql.age" || { echo "ERROR: downloaded encrypted backup is empty." >&2; exit 1; }

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

# --- 4. Decrypt locally ------------------------------------------------------
echo "Decrypting locally..."
age -d -i "$IDENTITY_FILE" -o "$WORKDIR/dump.sql" "$WORKDIR/backup.sql.age"
test -s "$WORKDIR/dump.sql" || { echo "ERROR: decrypted SQL dump is empty." >&2; exit 1; }

# --- 5. Restore into the scratch database -----------------------------------
echo "Restoring into disposable scratch database..."
psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -f "$WORKDIR/dump.sql" >/dev/null

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

# A representative non-secret data sanity check: current Family Ops task
# instances are expected to carry updated_at. We print only the timestamp,
# never a household/user row value.
LATEST_TASK_UPDATE="$(psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -Atq -c \
  "select max(updated_at) from public.task_instances;")"
if [ -z "$LATEST_TASK_UPDATE" ]; then
  echo "ERROR: representative task_instances.updated_at sanity check returned no value." >&2
  exit 1
fi
printf 'Representative task timestamp: %s\n' "$LATEST_TASK_UPDATE"

echo "RESULT: PASS — encrypted object decrypted, restored into an empty disposable database, and schema/data sanity checks passed."
