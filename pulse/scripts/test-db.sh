#!/usr/bin/env bash
# Spins up a throwaway local Postgres 16 cluster, applies the Supabase shim and every
# PULSE migration, then runs the SQL test suites and the concurrency test.
# Usage: scripts/test-db.sh            (exit code 0 = all passed)
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PGBIN="${PGBIN:-/usr/lib/postgresql/16/bin}"
DATA="$(mktemp -d /tmp/pulse-pg-XXXXXX)"
PORT="${PULSE_PG_PORT:-54329}"
RUN_AS=()
if [ "$(id -u)" = "0" ]; then RUN_AS=(runuser -u postgres --); chown postgres "$DATA"; fi

cleanup() { "${RUN_AS[@]}" "$PGBIN/pg_ctl" -D "$DATA" -m immediate stop >/dev/null 2>&1 || true; rm -rf "$DATA"; }
trap cleanup EXIT

"${RUN_AS[@]}" "$PGBIN/initdb" -D "$DATA" -U postgres -A trust -E UTF8 --locale=C.UTF-8 >/dev/null
"${RUN_AS[@]}" "$PGBIN/pg_ctl" -D "$DATA" -o "-p $PORT -k /tmp -c listen_addresses='' -c wal_level=logical" -w start >/dev/null

PSQL=(psql -h /tmp -p "$PORT" -U postgres -v ON_ERROR_STOP=1 -q -X)
"${PSQL[@]}" -d postgres -c "create database pulse_test" >/dev/null

echo "== applying shim"
"${PSQL[@]}" -d pulse_test -f "$ROOT/supabase/tests/00_supabase_shim.sql" >/dev/null
export PGOPTIONS='-c client_min_messages=warning'
for f in "$ROOT"/supabase/migrations/*.sql; do
  echo "== migration $(basename "$f")"
  "${PSQL[@]}" -d pulse_test -1 -f "$f"      # each migration atomic; aborts script on error
done

PASS=0; FAIL=0
shopt -s nullglob
for t in "$ROOT"/supabase/tests/[1-9]*.sql; do
  name="$(basename "$t")"
  if out="$("${PSQL[@]}" -d pulse_test -f "$ROOT/supabase/tests/helpers.sql" -f "$t" 2>&1)"; then
    echo "PASS $name"; PASS=$((PASS+1))
    [ -n "${VERBOSE:-}" ] && echo "$out"
  else
    echo "FAIL $name"; echo "$out" | sed 's/^/     /'; FAIL=$((FAIL+1))
  fi
done

if [ -x "$ROOT/supabase/tests/concurrency.sh" ]; then
  if PSQL_CMD="${PSQL[*]}" "$ROOT/supabase/tests/concurrency.sh"; then
    echo "PASS concurrency.sh"; PASS=$((PASS+1))
  else
    echo "FAIL concurrency.sh"; FAIL=$((FAIL+1))
  fi
fi

echo "== $PASS passed, $FAIL failed"
[ "$FAIL" = "0" ]
