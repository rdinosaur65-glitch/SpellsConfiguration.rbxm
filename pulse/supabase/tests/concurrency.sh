#!/usr/bin/env bash
# Real concurrency: separate connections race against the same rows.
#  1. Two devices open the same Snap at once  -> exactly one viewing session.
#  2. Two devices race for the single replay  -> exactly one succeeds; views never exceed 2.
#  3. Two retries of one message (same client id) at once -> exactly one row, both
#     callers get its id.
#  4. Two group members read at the same moment -> the disappearing message still starts
#     expiring (neither reader may miss the other's read).
#  5. A read races a member leaving -> the same guarantee.
#  6. A Snap view authorisation races its close -> never served AND refunded.
#  7. A member removal races their read -> no deadlock, the removal happens.
#  8. Blocking someone while they leave a shared group -> no deadlock.
set -uo pipefail
TMP="$(mktemp -d)"; trap 'rm -rf "$TMP"' EXIT
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
race_open 1 > $TMP/race1a & P1=$!
sleep 0.3
race_open 0 > $TMP/race1b & P2=$!
wait $P1 $P2
ok=$(cat $TMP/race1a $TMP/race1b | grep -c '^OK')
denied=$(cat $TMP/race1a $TMP/race1b | grep -c 'session_active')
echo "  first-open race: $ok succeeded, $denied refused"
[ "$ok" = "1" ] && [ "$denied" = "1" ] || { cat $TMP/race1a $TMP/race1b; exit 1; }

# End that session server-side (as if its timer elapsed and the client closed it).
"${PSQL[@]}" "${DB[@]}" -q -c "update public.snap_recipients set session_id = null, session_deadline = null where snap_id = '$SNAP'"

# --- 2. simultaneous replay
race_open 1 > $TMP/race2a & P1=$!
sleep 0.3
race_open 0 > $TMP/race2b & P2=$!
wait $P1 $P2
ok=$(cat $TMP/race2a $TMP/race2b | grep -c '^OK')
denied=$(cat $TMP/race2a $TMP/race2b | grep -c 'session_active')
echo "  replay race: $ok succeeded, $denied refused"
[ "$ok" = "1" ] && [ "$denied" = "1" ] || { cat $TMP/race2a $TMP/race2b; exit 1; }
views=$("${PSQL[@]}" "${DB[@]}" -At -c "select views_used from public.snap_recipients where snap_id = '$SNAP'")
"${PSQL[@]}" "${DB[@]}" -q -c "update public.snap_recipients set session_id = null, session_deadline = null where snap_id = '$SNAP'"
third=$(race_open 0)
echo "  views_used=$views, third open -> $third"
[ "$views" = "2" ] && [ "$third" = "snap_expired" ] || exit 1

# --- 3. duplicate message retries racing
CONV=$("${PSQL[@]}" "${DB[@]}" -At -c "$(as_user "$SENDER")" -c "select public.create_direct_conversation('$RECIP')" | tail -1)
CID=$(cat /proc/sys/kernel/random/uuid)
send() { "${PSQL[@]}" "${DB[@]}" -At -c "$(as_user "$SENDER")" -c "begin; select 'ID ' || public.send_message('$CONV', 'text', 'retry', '$CID'); select pg_sleep($1); commit;" 2>&1 | grep -E "ID|ERROR"; }
send 1 > $TMP/race3a & P1=$!
sleep 0.3
send 0 > $TMP/race3b & P2=$!
wait $P1 $P2
rows=$("${PSQL[@]}" "${DB[@]}" -At -c "select count(*) from public.messages where client_msg_id = '$CID'")
ids=$(cat $TMP/race3a $TMP/race3b | grep -c '^ID')
same=$(cat $TMP/race3a $TMP/race3b | grep '^ID' | sort -u | wc -l)
echo "  message retry race: rows=$rows, callers with an id=$ids, distinct ids=$same"
[ "$rows" = "1" ] && [ "$ids" = "2" ] && [ "$same" = "1" ] || { cat $TMP/race3a $TMP/race3b; exit 1; }

# --- 4. concurrent group reads
g=$("${PSQL[@]}" "${DB[@]}" -At -f "$ROOT/supabase/tests/helpers.sql" -f - 2>&1 <<SQL | grep -E '^GROUP|ERROR' | tail -1
create temp table g4 as select test.new_user('race_c_' || floor(random()*1e6)::int) c;
select test.befriend('$SENDER', c) from g4;
alter table g4 add column conv uuid, add column msg uuid;
grant all on g4 to authenticated;
select test.as_user('$SENDER');
update g4 set conv = public.create_group('race', array['$RECIP'::uuid, c]);
update g4 set msg = public.send_message(conv, 'text', 'read me together', gen_random_uuid());
select 'GROUP ' || conv || ' ' || msg || ' ' || c from g4;
SQL
)
g="${g#GROUP }"
read -r GCONV GMSG THIRD <<< "$g"
if [ -z "${THIRD:-}" ]; then echo "group setup failed: $g"; exit 1; fi
read_hold() { "${PSQL[@]}" "${DB[@]}" -At -c "$(as_user "$1")" -c "begin; select 'READ ' || public.mark_conversation_read('$GCONV'); select pg_sleep($2); commit;" 2>&1 | grep -E "READ|ERROR"; }
read_hold "$RECIP" 1 > $TMP/race4a & P1=$!
sleep 0.3
read_hold "$THIRD" 0 > $TMP/race4b & P2=$!
wait $P1 $P2
expiring=$("${PSQL[@]}" "${DB[@]}" -At -c "select expires_at is not null from public.messages where id = '$GMSG'")
echo "  concurrent group reads: expiry started=$expiring"
[ "$expiring" = "t" ] || { cat $TMP/race4a $TMP/race4b; exit 1; }

# --- 5. a read races a member leaving -> the disappearing message still starts expiring
g5=$("${PSQL[@]}" "${DB[@]}" -At -f "$ROOT/supabase/tests/helpers.sql" -f - 2>&1 <<SQL | grep -E '^G5|ERROR' | tail -1
create temp table g5 as select test.new_user('race_d_' || floor(random()*1e6)::int) d;
select test.befriend('$SENDER', d) from g5;
alter table g5 add column conv uuid, add column msg uuid;
grant all on g5 to authenticated;
select test.as_user('$SENDER');
update g5 set conv = public.create_group('race5', array['$RECIP'::uuid, d]);
update g5 set msg = public.send_message(conv, 'text', 'read while d leaves', gen_random_uuid());
select 'G5 ' || conv || ' ' || msg || ' ' || d from g5;
SQL
)
g5="${g5#G5 }"
read -r G5CONV G5MSG LEAVER <<< "$g5"
if [ -z "${LEAVER:-}" ]; then echo "race 5 setup failed: $g5"; exit 1; fi
"${PSQL[@]}" "${DB[@]}" -At -c "$(as_user "$RECIP")" -c "begin; select 'READ ' || public.mark_conversation_read('$G5CONV'); select pg_sleep(1); commit;" > $TMP/race5a 2>&1 & P1=$!
sleep 0.3
"${PSQL[@]}" "${DB[@]}" -At -c "$(as_user "$LEAVER")" -c "begin; select public.leave_group('$G5CONV'); commit;" > $TMP/race5b 2>&1 & P2=$!
wait $P1 $P2
expiring=$("${PSQL[@]}" "${DB[@]}" -At -c "select expires_at is not null from public.messages where id = '$G5MSG'")
echo "  read vs leave race: expiry started=$expiring"
[ "$expiring" = "t" ] || { cat $TMP/race5a $TMP/race5b; exit 1; }

# --- 6. a Snap view authorisation races its close: never bytes served AND the view refunded
for round in 1 2; do
  s6=$("${PSQL[@]}" "${DB[@]}" -At -f "$ROOT/supabase/tests/helpers.sql" -f - 2>&1 <<SQL | grep -E '^S6|ERROR' | tail -1
create temp table s6 as select test.upload('$SENDER', 'snap', 'image/jpeg', 1000) asset;
alter table s6 add column snap uuid, add column sess uuid;
grant all on s6 to authenticated;
select test.as_user('$SENDER');
update s6 set snap = public.send_snap(asset, array['$RECIP'::uuid], null, 3::smallint, false, gen_random_uuid());
select test.as_user('$RECIP');
update s6 set sess = (select session_id from public.open_snap(snap));
select 'S6 ' || snap || ' ' || sess from s6;
SQL
)
  s6="${s6#S6 }"; read -r S6SNAP S6SESS <<< "$s6"
  if [ -z "${S6SESS:-}" ]; then echo "race 6 setup failed: $s6"; exit 1; fi
  close_sql="begin; select 'CLOSED ' || public.close_snap_view('$S6SNAP', '$S6SESS'); select pg_sleep(1.2); commit;"
  grant_sql="begin; select 'GRANT' from public.authorize_snap_media('$S6SNAP', '$S6SESS'); select pg_sleep(1.2); commit;"
  if [ "$round" = 1 ]; then first="$close_sql"; second="$grant_sql"; else first="$grant_sql"; second="$close_sql"; fi
  "${PSQL[@]}" "${DB[@]}" -At -c "$(as_user "$RECIP")" -c "$first" > $TMP/race6a 2>&1 & P1=$!
  sleep 0.3
  "${PSQL[@]}" "${DB[@]}" -At -c "$(as_user "$RECIP")" -c "$second" > $TMP/race6b 2>&1 & P2=$!
  wait $P1 $P2
  granted=$(cat $TMP/race6a $TMP/race6b | grep -c '^GRANT')
  views=$("${PSQL[@]}" "${DB[@]}" -At -c "select views_used || ' ' || status from public.snap_recipients where snap_id = '$S6SNAP'")
  echo "  snap close vs authorise (round $round): granted=$granted views/status=$views"
  if [ "$granted" = "1" ] && [ "${views%% *}" != "1" ]; then cat $TMP/race6a $TMP/race6b; exit 1; fi
  if [ "$granted" = "0" ] && [ "${views%% *}" != "0" ]; then cat $TMP/race6a $TMP/race6b; exit 1; fi
done

# --- 7. removing a member while they mark the chat read must not deadlock
g7=$("${PSQL[@]}" "${DB[@]}" -At -f "$ROOT/supabase/tests/helpers.sql" -f - 2>&1 <<SQL | grep -E '^G7|ERROR' | tail -1
create temp table g7 as select test.new_user('race_e_' || floor(random()*1e6)::int) e;
select test.befriend('$SENDER', e) from g7;
alter table g7 add column conv uuid, add column msg uuid;
grant all on g7 to authenticated;
select test.as_user('$SENDER');
update g7 set conv = public.create_group('race7', array['$RECIP'::uuid, e]);
update g7 set msg = public.send_message(conv, 'text', 'saved by e', gen_random_uuid());
select test.as_user(e) from g7;
select public.set_message_saved(msg, true) from g7;
select 'G7 ' || conv || ' ' || msg || ' ' || e from g7;
SQL
)
g7="${g7#G7 }"
read -r G7CONV G7MSG G7E <<< "$g7"
if [ -z "${G7E:-}" ]; then echo "race 7 setup failed: $g7"; exit 1; fi
# Hold e's saved row so the removal pauses inside detach_member, then let e read.
"${PSQL[@]}" "${DB[@]}" -At -c "begin; select 1 from public.saved_messages where user_id = '$G7E' for update; select pg_sleep(2); rollback;" > /dev/null 2>&1 & P0=$!
sleep 0.3
"${PSQL[@]}" "${DB[@]}" -At -c "$(as_user "$SENDER")" -c "select 'REMOVED ' || public.remove_group_member('$G7CONV', '$G7E');" > $TMP/race7a 2>&1 & P1=$!
sleep 0.5
"${PSQL[@]}" "${DB[@]}" -At -c "$(as_user "$G7E")" -c "select 'READ ' || public.mark_conversation_read('$G7CONV');" > $TMP/race7b 2>&1 & P2=$!
wait $P0 $P1 $P2
left=$("${PSQL[@]}" "${DB[@]}" -At -c "select left_at is not null from public.conversation_members where conversation_id = '$G7CONV' and user_id = '$G7E'")
deadlocks=$(cat $TMP/race7a $TMP/race7b | grep -c 'deadlock')
echo "  remove vs read race: removed=$left deadlocks=$deadlocks"
[ "$left" = "t" ] && [ "$deadlocks" = "0" ] || { cat $TMP/race7a $TMP/race7b; exit 1; }

# --- 8. blocking someone while they leave a shared group must not deadlock
g8=$("${PSQL[@]}" "${DB[@]}" -At -f "$ROOT/supabase/tests/helpers.sql" -f - 2>&1 <<SQL | grep -E '^G8|ERROR' | tail -1
create temp table g8 as select test.new_user('race_p_' || floor(random()*1e6)::int) p, test.new_user('race_q_' || floor(random()*1e6)::int) q;
select test.befriend(p, q) from g8;
alter table g8 add column conv uuid, add column msg uuid;
grant all on g8 to authenticated;
select test.as_user(q) from g8;
update g8 set conv = public.create_group('race8', array[p]);
update g8 set msg = public.send_message(conv, 'text', 'saved by p', gen_random_uuid());
select test.as_user(p) from g8;
select public.set_message_saved(msg, true) from g8;
select 'G8 ' || conv || ' ' || p || ' ' || q from g8;
SQL
)
g8="${g8#G8 }"
read -r G8CONV G8P G8Q <<< "$g8"
if [ -z "${G8Q:-}" ]; then echo "race 8 setup failed: $g8"; exit 1; fi
# p leaves (holding the chat lock a moment first, as leave_group takes it), q blocks p meanwhile.
claims_p="select set_config('request.jwt.claims', '{\"sub\":\"$G8P\",\"role\":\"authenticated\"}', false);"
"${PSQL[@]}" "${DB[@]}" -At -c "$claims_p" -c "begin; select private.lock_conv('$G8CONV'); select pg_sleep(1); select 'LEFT ' || public.leave_group('$G8CONV'); commit;" > $TMP/race8a 2>&1 & P1=$!
sleep 0.3
"${PSQL[@]}" "${DB[@]}" -At -c "$(as_user "$G8Q")" -c "select 'BLOCKED ' || public.block_user('$G8P');" > $TMP/race8b 2>&1 & P2=$!
wait $P1 $P2
deadlocks=$(cat $TMP/race8a $TMP/race8b | grep -c 'deadlock')
ok=$(cat $TMP/race8a $TMP/race8b | grep -cE '^(LEFT|BLOCKED)')
echo "  block vs leave race: completed=$ok deadlocks=$deadlocks"
[ "$deadlocks" = "0" ] && [ "$ok" = "2" ] || { cat $TMP/race8a $TMP/race8b; exit 1; }
