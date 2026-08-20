#!/usr/bin/env bash
# WP10 backup freshness alert.
#
# Reads the `latest-backup.txt` marker object that
# .github/workflows/backup.yml writes to the R2 bucket after every
# successful daily backup, and fails (non-zero exit) if the recorded
# timestamp is older than MAX_BACKUP_AGE_HOURS (default 26h — one day plus
# slack for the backup job's own runtime/retry window).
#
# This script only ever reads from R2 with the same read/write access-key
# credentials the backup job uses to write there. It never touches age keys
# and never decrypts anything — freshness is checked from the marker's
# plaintext timestamp only.
#
# Required env:
#   R2_ACCOUNT_ID, R2_BUCKET_NAME, AWS_ACCESS_KEY_ID, AWS_SECRET_ACCESS_KEY
# Optional env:
#   MAX_BACKUP_AGE_HOURS (default 26)
#
# Usage: bash scripts/backup_freshness_check.sh

set -euo pipefail

MAX_BACKUP_AGE_HOURS="${MAX_BACKUP_AGE_HOURS:-26}"

for v in R2_ACCOUNT_ID R2_BUCKET_NAME AWS_ACCESS_KEY_ID AWS_SECRET_ACCESS_KEY; do
  if [ -z "${!v:-}" ]; then
    echo "ERROR: required env var $v is not set" >&2
    exit 2
  fi
done

if ! command -v aws >/dev/null 2>&1; then
  echo "ERROR: aws CLI not found (pip install awscli, or use the R2 dashboard/rclone equivalent)" >&2
  exit 2
fi

ENDPOINT_URL="https://${R2_ACCOUNT_ID}.r2.cloudflarestorage.com"
MARKER_FILE="$(mktemp)"
trap 'rm -f "$MARKER_FILE"' EXIT

if ! aws s3 cp "s3://${R2_BUCKET_NAME}/latest-backup.txt" "$MARKER_FILE" \
    --endpoint-url "$ENDPOINT_URL" >/dev/null 2>&1; then
  echo "ALERT: could not fetch latest-backup.txt from R2 bucket '${R2_BUCKET_NAME}' — no backup marker found, or bucket/credentials misconfigured." >&2
  exit 1
fi

BACKUP_FILENAME="$(sed -n '1p' "$MARKER_FILE")"
BACKUP_TIMESTAMP="$(sed -n '2p' "$MARKER_FILE")"

if [ -z "$BACKUP_TIMESTAMP" ]; then
  echo "ALERT: latest-backup.txt marker is malformed (missing timestamp line)." >&2
  exit 1
fi

BACKUP_EPOCH="$(date -u -d "$BACKUP_TIMESTAMP" +%s 2>/dev/null || true)"
if [ -z "$BACKUP_EPOCH" ]; then
  echo "ALERT: could not parse timestamp '$BACKUP_TIMESTAMP' from latest-backup.txt." >&2
  exit 1
fi

NOW_EPOCH="$(date -u +%s)"
AGE_HOURS=$(( (NOW_EPOCH - BACKUP_EPOCH) / 3600 ))

echo "Latest backup: $BACKUP_FILENAME (timestamp: $BACKUP_TIMESTAMP, age: ${AGE_HOURS}h, threshold: ${MAX_BACKUP_AGE_HOURS}h)"

if [ "$AGE_HOURS" -gt "$MAX_BACKUP_AGE_HOURS" ]; then
  echo "ALERT: latest backup is ${AGE_HOURS}h old, exceeding the ${MAX_BACKUP_AGE_HOURS}h freshness threshold." >&2
  exit 1
fi

echo "OK: backup is fresh."
