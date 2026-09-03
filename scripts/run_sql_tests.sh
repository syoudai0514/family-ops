#!/usr/bin/env bash
# Applies supabase/migrations against a scratch database (plus the test-only
# auth shim) and runs every tests/sql/*.sql assertion file. Used both by
# `npm run test:sql` locally and by CI's `db` job.
set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
export PGHOST="${PGHOST:-127.0.0.1}"
export PGPORT="${PGPORT:-5544}"
export PGUSER="${PGUSER:-postgres}"
export PGPASSWORD="${PGPASSWORD:-}"
TEST_DB="family_ops_sql_test"
SQL_TEST_STOP_AFTER="${SQL_TEST_STOP_AFTER:-99}"

psql -v ON_ERROR_STOP=1 -d postgres -c "drop database if exists ${TEST_DB};" >/dev/null
psql -v ON_ERROR_STOP=1 -d postgres -c "create database ${TEST_DB};" >/dev/null

echo "== applying auth shim =="
psql -v ON_ERROR_STOP=1 -d "$TEST_DB" -f "$REPO_ROOT/tests/sql/00_local_auth_shim.sql"

echo "== applying migrations =="
for f in "$REPO_ROOT"/supabase/migrations/*.sql; do
  echo "  -> $(basename "$f")"
  psql -v ON_ERROR_STOP=1 -d "$TEST_DB" -f "$f"
done

echo "== seeding jp_holidays fixture =="
node "$REPO_ROOT/scripts/seed_jp_holidays.mjs" "$TEST_DB"

echo "== running SQL test suite through prefix ${SQL_TEST_STOP_AFTER} =="
shopt -s nullglob
for f in "$REPO_ROOT"/tests/sql/[0-9][0-9]_*.sql; do
  base="$(basename "$f")"
  if [ "$base" = "00_local_auth_shim.sql" ]; then
    continue
  fi
  prefix="${base%%_*}"
  if (( 10#$prefix > 10#$SQL_TEST_STOP_AFTER )); then
    continue
  fi
  echo "  -> $base"
  psql -v ON_ERROR_STOP=1 -d "$TEST_DB" -f "$f"
done

if (( 10#$SQL_TEST_STOP_AFTER >= 99 )); then
  echo "== running true-parallel concurrency tests =="
  bash "$REPO_ROOT/scripts/run_concurrency_tests.sh" "$TEST_DB"
fi

echo "== SQL tests through prefix ${SQL_TEST_STOP_AFTER} passed =="
