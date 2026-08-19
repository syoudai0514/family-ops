#!/usr/bin/env bash
# WP10 restore drill: download the latest (or a named) encrypted backup
# from R2, decrypt it LOCALLY, restore it into a scratch/disposable
# Postgres database, and run basic sanity checks (row counts, migration
# version). See docs/BACKUP_RESTORE_RUNBOOK.md for the full narrative
# procedure this script automates, and for the release/monthly drill
# checklist.
#
# ============================================================================
# SECURITY: this script must NEVER run in CI, and must NEVER accept the age
# private key via an environment variable. The age private key is a secret
# CI is not allowed to hold (see .github/workflows/backup.yml's header
# comment and docs/BACKUP_RESTORE_RUNBOOK.md). It only exists in the
# household owner's own password manager / offline storage. This script
# only accepts the private key as:
#   (a) a local file path argument (--key-file <path>), or
#   (b) an interactive terminal prompt (paste the key, not echoed) if
#       --key-file is omitted.
# It deliberately does NOT read any AGE_PRIVATE_KEY / *_KEY environment
# variable, precisely so it cannot be wired into a CI secret by accident.
# Do not "fix" that — it is the point.
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
#   --scratch-db-url <url>  Postgres connection string for the scratch/local
#                            database to restore into. REQUIRED. This must
#                            point at a disposable database, never at
#                            production, unless you are knowingly performing
#                            a real disaster-recovery restore (see runbook).
#   -h, --help               Show this help.
#
# Required env (R2 read access only — never age keys):
#   R2_ACCOUNT_ID, R2_BUCKET_NAME, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY

set -euo pipefail

KEY_FILE=""
BACKUP_FILE=""
SCRATCH_DB_URL=""

usage() {
  sed -n '2,40p' "$0" | sed 's/^# \{0,1\}//'
}

while [ $# -gt 0 ]; do
  case "$1" in
    --key-file)
      KEY_FILE="$2"; shift 2 ;;
    --backup-file)
      BACKUP_FILE="$2"; shift 2 ;;
    --scratch-db-url)
      SCRATCH_DB_URL="$2"; shift 2 ;;
    -h|--help)
      usage; exit 0 ;;
    *)
      echo "Unknown argument: $1" >&2; usage; exit 2 ;;
  esac
done

if [ -n "${CI:-}" ]; then
  echo "ERROR: refusing to run in a CI environment (CI env var is set). This script decrypts backups with the owner's private key and must only be run by a human, locally." >&2
  exit 3
fi

if [ -z "$SCRATCH_DB_URL" ]; then
  echo "ERROR: --scratch-db-url is required. Point it at a disposable/local Postgres instance." >&2
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
  # Shred the plaintext dump and any staged key material as soon as we're
  # done; encrypted download is harmless to leave behind but we remove it
  # too for a clean drill.
  rm -rf "$WORKDIR"
}
trap cleanup EXIT

# --- 1. Resolve which backup file to restore -------------------------------

if [ -z "$BACKUP_FILE" ]; then
  echo "No --backup-file given; looking up latest-backup.txt marker..."
  aws s3 cp "s3://${R2_BUCKET_NAME}/latest-backup.txt" "$WORKDIR/latest-backup.txt" \
    --endpoint-url "$ENDPOINT_URL"
  BACKUP_FILE="$(sed -n '1p' "$WORKDIR/latest-backup.txt")"
  echo "Latest backup: $BACKUP_FILE"
fi

# --- 2. Download the encrypted backup ---------------------------------------

echo "Downloading $BACKUP_FILE from R2 bucket $R2_BUCKET_NAME..."
aws s3 cp "s3://${R2_BUCKET_NAME}/${BACKUP_FILE}" "$WORKDIR/backup.sql.age" \
  --endpoint-url "$ENDPOINT_URL"

# --- 3. Obtain the age private key (local only, never from env) -------------

if [ -n "$KEY_FILE" ]; then
  if [ ! -f "$KEY_FILE" ]; then
    echo "ERROR: --key-file '$KEY_FILE' does not exist" >&2
    exit 2
  fi
  IDENTITY_FILE="$KEY_FILE"
else
  echo "Paste the age private key (AGE-SECRET-KEY-1...) and press Enter. Input is not echoed."
  IDENTITY_FILE="$WORKDIR/identity.txt"
  # -s: silent (no echo). Written only to a tmpdir file that is shredded on exit.
  read -r -s PASTED_KEY
  echo
  printf '%s\n' "$PASTED_KEY" > "$IDENTITY_FILE"
  chmod 600 "$IDENTITY_FILE"
  unset PASTED_KEY
fi

# --- 4. Decrypt locally -------------------------------------------------------

echo "Decrypting..."
age -d -i "$IDENTITY_FILE" -o "$WORKDIR/dump.sql" "$WORKDIR/backup.sql.age"
echo "Decrypted to a local scratch file (removed automatically on exit)."

# --- 5. Restore into the scratch database -------------------------------------

echo "Restoring into scratch database..."
psql "$SCRATCH_DB_URL" -v ON_ERROR_STOP=1 -f "$WORKDIR/dump.sql"

# --- 6. Sanity checks -----------------------------------------------------

echo
echo "=== Sanity checks ==="

echo "-- Migration version (supabase_migrations.schema_migrations, latest rows):"
psql "$SCRATCH_DB_URL" -c \
  "select version from supabase_migrations.schema_migrations order by version desc limit 5;" \
  2>/dev/null || echo "(supabase_migrations.schema_migrations not found — check migration tracking table name)"

echo
echo "-- Row counts on core tables (adjust list if the schema has changed):"
for t in households household_members task_definitions task_instances handovers user_notifications; do
  psql "$SCRATCH_DB_URL" -c "select '$t' as table_name, count(*) from $t;" 2>/dev/null \
    || echo "  ($t: not found or query failed)"
done

echo
echo "Restore drill complete. Review the counts above against expectations"
echo "(see docs/BACKUP_RESTORE_RUNBOOK.md) before considering this drill green."
