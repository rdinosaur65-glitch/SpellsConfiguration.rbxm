#!/usr/bin/env bash
# Runs the PULSE SQL suites against the *real* local Supabase stack (supabase start),
# instead of the plain-Postgres shim. Resets the local database first (local only!).
# Usage: scripts/test-supabase-local.sh        (needs Docker + `npm install` at repo root)
set -euo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"
DB_URL="${SUPABASE_DB_URL:-postgresql://postgres:postgres@127.0.0.1:54322/postgres}"
case "$DB_URL" in *127.0.0.1*|*localhost*) ;; *) echo "refusing: not a local database"; exit 2;; esac

if [ -z "${SKIP_RESET:-}" ]; then
  echo "== supabase db reset (re-applies every migration)"
  npx supabase db reset --local >/dev/null
fi

PSQL=(psql "$DB_URL" -v ON_ERROR_STOP=1 -q -X)
export PGOPTIONS='-c client_min_messages=warning'
PASS=0; FAIL=0
for t in "$ROOT"/supabase/tests/[1-9]*.sql; do
  name="$(basename "$t")"
  if out="$("${PSQL[@]}" -f "$ROOT/supabase/tests/helpers.sql" -f "$t" 2>&1)"; then
    echo "PASS $name"; PASS=$((PASS+1))
  else
    echo "FAIL $name"; echo "$out" | sed 's/^/     /'; FAIL=$((FAIL+1))
  fi
done
if PSQL_CMD="psql $DB_URL -v ON_ERROR_STOP=1 -q -X" PULSE_TEST_DB="" "$ROOT/supabase/tests/concurrency.sh"; then
  echo "PASS concurrency.sh"; PASS=$((PASS+1))
else
  echo "FAIL concurrency.sh"; FAIL=$((FAIL+1))
fi
# Registration gate against the real Supabase Auth server (no functions needed).
if (set -a; eval "$(npx supabase status -o env 2>/dev/null)"; set +a; SUPABASE_URL="$API_URL" DB_URL="$DB_URL" \
    node --test "$ROOT/supabase/tests/registration.test.mjs") > /tmp/pulse-registration-test.log 2>&1; then
  echo "PASS registration.test.mjs"; PASS=$((PASS+1))
else
  echo "FAIL registration.test.mjs"; sed 's/^/     /' /tmp/pulse-registration-test.log | tail -40; FAIL=$((FAIL+1))
fi
# Edge Functions (media-url, storage-janitor), when they are being served:
#   npx supabase functions serve --env-file supabase/functions/.env
code=$(curl -s -o /dev/null -w '%{http_code}' -X POST http://127.0.0.1:54321/functions/v1/storage-janitor || true)
if [ "$code" = "401" ]; then
  if (set -a; eval "$(npx supabase status -o env 2>/dev/null)"; set +a; SUPABASE_URL="$API_URL" DB_URL="$DB_URL" \
      node --test "$ROOT/supabase/tests/functions.test.mjs") > /tmp/pulse-functions-test.log 2>&1; then
    echo "PASS functions.test.mjs"; PASS=$((PASS+1))
  else
    echo "FAIL functions.test.mjs"; sed 's/^/     /' /tmp/pulse-functions-test.log | tail -40; FAIL=$((FAIL+1))
  fi
else
  echo "SKIP functions.test.mjs (functions not served: npx supabase functions serve --env-file supabase/functions/.env)"
fi
echo "== $PASS passed, $FAIL failed (real Supabase local stack)"
[ "$FAIL" = "0" ]
