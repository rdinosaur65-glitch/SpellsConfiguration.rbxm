#!/usr/bin/env bash
# Real concurrency: separate connections race against the same rows.
#  1. Two devices open the same Snap at once  -> exactly one viewing session.
#  2. Two devices race for the single replay  -> exactly one succeeds; views never exceed 2.
#  3. Two retries of one message (same client id) at once -> exactly one row.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
read -r -a PSQL <<< "$PSQL_CMD"
DB=(); if [ -n "${PULSE_TEST_DB-pulse_test}" ]; then DB=(-d "${PULSE_TEST_DB-pulse_test}"); fi

setup=$("${PSQL[@]}" "${DB[@]}" -At -f "$ROOT/supabase/tests/helpers.sql" -f - 2>&1 <<'SQL' | grep -E '^SETUP|ERROR' | tail -1
create temp table race as select test.new_user('race_a_' || floor(random()*1e6)::int) a,
                                 test.new_user('race_b_' || floor(random()*1e6)::int) b;
select test.befriend(a, b) from race;
alter table race add column asset uuid, add column snap uuid;
grant all on race to authenticated;
update race set asset = test.upload(a, 'snap', 'image/jpeg', 1000);
select test.as_user(a) from race;
update race set snap = public.send_snap(asset, array[b], null, 3::smallint, false, gen_random_uuid());
select 'SETUP ' || snap || ' ' || b || ' x ' || a from race;
SQL
)
setup="${setup#SETUP }"
read -r SNAP RECIP _ SENDER <<< "$setup"
if [ -z "${SNAP:-}" ] || [ -z "${SENDER:-}" ]; then echo "setup failed: $setup"; exit 1; fi

as_user() { echo "select set_config('request.jwt.claims', '{\"sub\":\"$1\",\"role\":\"authenticated\"}', false); set role authenticated;"; }

race_open() {  # $1 = hold seconds
  "${PSQL[@]}" "${DB[@]}" -At -c "$(as_user "$RECIP")" -c "begin; select 'OK ' || session_id from public.open_snap('$SNAP'); select pg_sleep($1); commit;" 2>&1 | grep -E "OK|ERROR" | sed 's/.*ERROR: *//'
}

# --- 1. simultaneous first open
race_open 1 > /tmp/race1a & P1=$!
sleep 0.3
race_open 0 > /tmp/race1b & P2=$!
wait $P1 $P2
ok=$(cat /tmp/race1a /tmp/race1b | grep -c '^OK')
denied=$(cat /tmp/race1a /tmp/race1b | grep -c 'session_active')
echo "  first-open race: $ok succeeded, $denied refused"
[ "$ok" = "1" ] && [ "$denied" = "1" ] || { cat /tmp/race1a /tmp/race1b; exit 1; }

# End that session server-side (as if its timer elapsed and the client closed it).
"${PSQL[@]}" "${DB[@]}" -q -c "update public.snap_recipients set session_id = null, session_deadline = null where snap_id = '$SNAP'"

# --- 2. simultaneous replay
race_open 1 > /tmp/race2a & P1=$!
sleep 0.3
race_open 0 > /tmp/race2b & P2=$!
wait $P1 $P2
ok=$(cat /tmp/race2a /tmp/race2b | grep -c '^OK')
echo "  replay race: $ok succeeded"
[ "$ok" = "1" ] || { cat /tmp/race2a /tmp/race2b; exit 1; }
views=$("${PSQL[@]}" "${DB[@]}" -At -c "select views_used from public.snap_recipients where snap_id = '$SNAP'")
"${PSQL[@]}" "${DB[@]}" -q -c "update public.snap_recipients set session_id = null, session_deadline = null where snap_id = '$SNAP'"
third=$(race_open 0)
echo "  views_used=$views, third open -> $third"
[ "$views" = "2" ] && [ "$third" = "snap_expired" ] || exit 1

# --- 3. duplicate message retries racing
CONV=$("${PSQL[@]}" "${DB[@]}" -At -c "$(as_user "$SENDER")" -c "select public.create_direct_conversation('$RECIP')" | tail -1)
CID=$(cat /proc/sys/kernel/random/uuid)
send() { "${PSQL[@]}" "${DB[@]}" -At -c "$(as_user "$SENDER")" -c "begin; select 'ID ' || public.send_message('$CONV', 'text', 'retry', '$CID'); select pg_sleep($1); commit;" 2>&1 | grep -E "ID|ERROR"; }
send 1 > /tmp/race3a & P1=$!
sleep 0.3
send 0 > /tmp/race3b & P2=$!
wait $P1 $P2
rows=$("${PSQL[@]}" "${DB[@]}" -At -c "select count(*) from public.messages where client_msg_id = '$CID'")
same=$(cat /tmp/race3a /tmp/race3b | grep '^ID' | sort -u | wc -l)
echo "  message retry race: rows=$rows, distinct ids returned=$same"
[ "$rows" = "1" ] && [ "$same" = "1" ] || { cat /tmp/race3a /tmp/race3b; exit 1; }
rm -f /tmp/race[123][ab]
