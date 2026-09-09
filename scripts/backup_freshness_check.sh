#!/usr/bin/env bash
# WP10 backup freshness alert.
#
# Reads the `latest-backup.txt` marker object that
# .github/workflows/backup.yml writes to the R2 bucket after every
# successful daily backup, and fails (non-zero exit) if the recorded
# timestamp is more than MAX_BACKUP_AGE_HOURS (default 26h — one day plus
# slack for the backup job's own runtime/retry window).
#
# Freshness means both:
#   1. the marker timestamp is within policy; and
#   2. the encrypted object named by that marker still exists in R2 and is
#      non-empty.
# A fresh marker pointing at a missing object is therefore RED, not GREEN.
#
# This script only ever reads from R2 with the same read/write access-key
# credentials the backup job uses to write there. It never touches age keys
# and never decrypts anything — recoverability is proven separately by the
# owner-operated restore drill.
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

if ! [[ "$MAX_BACKUP_AGE_HOURS" =~ ^[0-9]+$ ]] || [ "$MAX_BACKUP_AGE_HOURS" -le 0 ]; then
  echo "ERROR: MAX_BACKUP_AGE_HOURS must be a positive integer" >&2
  exit 2
fi

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

if ! [[ "$BACKUP_FILENAME" =~ ^family-ops-backup-[0-9]{4}-[0-9]{2}-[0-9]{2}\.tar\.age$ ]]; then
  echo "ALERT: latest-backup.txt marker is malformed (invalid backup filename)." >&2
  exit 1
fi

if [ -z "$BACKUP_TIMESTAMP" ]; then
  echo "ALERT: latest-backup.txt marker is malformed (missing timestamp line)." >&2
  exit 1
fi

BACKUP_EPOCH="$(date -u -d "$BACKUP_TIMESTAMP" +%s 2>/dev/null || true)"
if [ -z "$BACKUP_EPOCH" ]; then
  echo "ALERT: could not parse the timestamp from latest-backup.txt." >&2
  exit 1
fi

NOW_EPOCH="$(date -u +%s)"
# Allow at most five minutes of clock skew. A marker far in the future would
# otherwise produce a negative age and incorrectly pass the freshness gate.
if [ "$BACKUP_EPOCH" -gt $((NOW_EPOCH + 300)) ]; then
  echo "ALERT: latest-backup.txt timestamp is unexpectedly in the future." >&2
  exit 1
fi

AGE_SECONDS=$((NOW_EPOCH - BACKUP_EPOCH))
# Small accepted future skew is operationally equivalent to age zero.
if [ "$AGE_SECONDS" -lt 0 ]; then
  AGE_SECONDS=0
fi
MAX_AGE_SECONDS=$((MAX_BACKUP_AGE_HOURS * 3600))
AGE_HOURS=$((AGE_SECONDS / 3600))
AGE_MINUTES=$(((AGE_SECONDS % 3600) / 60))
echo "Latest backup: $BACKUP_FILENAME (age: ${AGE_HOURS}h ${AGE_MINUTES}m, threshold: ${MAX_BACKUP_AGE_HOURS}h)"

# Compare exact elapsed seconds, not floor-truncated hours. Otherwise a backup
# 26h59m old would incorrectly report age=26h and pass a 26-hour policy.
if [ "$AGE_SECONDS" -gt "$MAX_AGE_SECONDS" ]; then
  echo "ALERT: latest backup exceeds the ${MAX_BACKUP_AGE_HOURS}h freshness threshold." >&2
  exit 1
fi

OBJECT_SIZE="$(aws s3api head-object \
  --bucket "$R2_BUCKET_NAME" \
  --key "$BACKUP_FILENAME" \
  --endpoint-url "$ENDPOINT_URL" \
  --query ContentLength \
  --output text 2>/dev/null || true)"
if ! [[ "$OBJECT_SIZE" =~ ^[0-9]+$ ]] || [ "$OBJECT_SIZE" -le 0 ]; then
  echo "ALERT: marker points to a missing or empty encrypted backup object in R2." >&2
  exit 1
fi

echo "OK: backup is fresh and the referenced encrypted R2 object exists (${OBJECT_SIZE} bytes)."
