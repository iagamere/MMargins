#!/usr/bin/env bash
# Runs the privacy test-suite against a THROWAWAY database on a plain local Postgres (>= 15).
#   PGHOST=/tmp/pgtest PGPORT=54329 PGUSER=postgres ./supabase/tests/run.sh
set -euo pipefail
here="$(cd "$(dirname "$0")" && pwd)"
db="margins_test_$$"
psql="psql -X -q -v ON_ERROR_STOP=1"
$psql -d postgres -c "create database $db" >/dev/null
trap '$psql -d postgres -c "drop database if exists $db" >/dev/null' EXIT
$psql -d "$db" -f "$here/00_mock_supabase.sql"
for f in "$here"/../migrations/*.sql; do $psql -d "$db" -f "$f"; done
$psql -d "$db" -f "$here/10_helpers.sql"
for f in "$here"/[2-9]*_tests.sql; do
  out="$(psql -X -d "$db" -v ON_ERROR_STOP=1 -f "$f")"
  echo "== $(basename "$f")"; echo "$out"
  echo "$out" | grep -Eq ' 0 +\| +[0-9]+$' || { echo "TESTS FAILED"; exit 1; }
done
