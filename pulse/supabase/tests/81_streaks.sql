-- Snap streaks (migration 0032). Days are moved by passing explicit moments to the private
-- functions (the server clock is the only clock; nothing a user sends can set it).
create or replace function test.snap(p_from uuid, p_to uuid[], p_groups uuid[] default null, p_client uuid default gen_random_uuid())
returns uuid language plpgsql as $$
declare v_asset uuid; v uuid;
begin
  v_asset := test.upload(p_from, 'snap', 'image/webp', 1000);
  perform test.as_user(p_from);
  v := public.send_snap(v_asset, p_to, p_groups, 3::smallint, false, p_client);
  perform test.as_superuser();
  return v;
end $$;
create or replace function test.streak(p_x uuid, p_y uuid) returns private.streaks language sql as $$
  select * from private.streaks where user_a = least(p_x, p_y) and user_b = greatest(p_x, p_y)
$$;
-- Moment inside server day "today + p_days" (noon).
create or replace function test.day_at(p_days integer, p_time interval default interval '12 hours') returns timestamptz language sql as $$
  select (private.streak_day(now()) + p_days)::timestamp at time zone (select streak_timezone from private.platform_config) + p_time
$$;
grant execute on all functions in schema test to authenticated, anon, service_role;

do $$
declare a uuid; b uuid; c uuid; g uuid; s private.streaks; cid uuid := gen_random_uuid(); n integer; v record;
begin
  perform test.as_superuser();
  a := test.new_user('stk_a_81', 'Ana'); b := test.new_user('stk_b_81', 'Ben'); c := test.new_user('stk_c_81', 'Cy');
  perform test.befriend(a, b); perform test.befriend(a, c); perform test.befriend(b, c);

  -- One-sided: no streak yet.
  perform test.snap(a, array[b]);
  s := test.streak(a, b);
  perform test.ok(s.count = 0 and (case when s.user_a = a then s.a_sent_on else s.b_sent_on end) = private.streak_day(now()), 'one-sided: recorded, count 0');
  perform test.as_user(a);
  perform test.ok(not exists (select 1 from public.my_streaks()), 'one-sided: nothing to show');
  perform test.as_superuser();
  perform test.snap(a, array[b]);
  perform test.ok((test.streak(a, b)).count = 0, 'several Snaps from one side: still 0');

  -- First exchange: 1, once.
  perform test.snap(b, array[a], null, cid);
  s := test.streak(a, b);
  perform test.ok(s.count = 1 and s.started_on = private.streak_day(now()) and s.last_completed_on = s.started_on, 'both sent today: 1');
  perform test.snap(b, array[a]); perform test.snap(a, array[b]);
  perform test.ok((test.streak(a, b)).count = 1, 'more Snaps the same day: still 1');
  -- Replaying the same request (same client id) changes nothing.
  perform test.snap(b, array[a], null, cid);
  perform test.ok((test.streak(a, b)).count = 1, 'replayed request: still 1');
  perform test.as_user(a);
  select * into v from public.my_streaks() where friend_id = b;
  perform test.ok(v.count = 1 and v.completed_today and v.i_sent_today and v.they_sent_today and not v.at_risk, 'visible to Ana');
  perform test.as_user(b);
  perform test.ok((select count from public.my_streaks() where friend_id = a) = 1, 'visible to Ben');

  -- What does not count: texts, voice notes, group Snaps.
  perform test.as_user(a);
  perform public.send_message(public.create_direct_conversation(c), 'text', 'hi', gen_random_uuid());
  perform test.as_user(c);
  perform public.send_message(public.create_direct_conversation(a), 'text', 'hi back', gen_random_uuid());
  perform test.as_user(a);
  g := public.create_group('Trio', array[b, c]);
  perform test.as_superuser();
  perform test.snap(a, null, array[g]); perform test.snap(c, null, array[g]);
  perform test.ok(coalesce((test.streak(a, c)).count, 0) = 0, 'texts and group Snaps do not count');
  perform test.ok(coalesce((test.streak(a, c)).a_sent_on, (test.streak(a, c)).b_sent_on) is null, 'not even recorded');

  -- Only the two friends can see it; nobody can write it.
  perform test.as_user(c);
  perform test.ok(not exists (select 1 from public.my_streaks() where friend_id in (a, b)), 'a third person sees nothing');
  perform test.throws('select * from private.streaks', 'sqlstate:42501', 'table not readable');
  perform test.throws(format('select private.streak_record_snap(%L, %L)', c, a), 'sqlstate:42501', 'cannot record a Snap directly');
  perform test.throws('select private.streak_maintenance()', 'sqlstate:42501', 'cannot run the job');
  perform test.as_anon();
  perform test.throws('select * from public.my_streaks()', 'sqlstate:42501', 'anon: nothing');
  perform test.as_superuser();
end $$;

-- Days: consecutive, missed, expiry, restart, day boundary.
do $$
declare a uuid; b uuid; s private.streaks; v record; r jsonb;
begin
  perform test.as_superuser();
  a := (select id from public.profiles where username = 'stk_a_81'); b := (select id from public.profiles where username = 'stk_b_81');
  -- Tomorrow both send: 2. The day after, both: 3.
  perform private.streak_record_snap(a, b, test.day_at(1)); perform private.streak_record_snap(b, a, test.day_at(1, interval '23 hours 59 minutes'));
  perform test.ok((test.streak(a, b)).count = 2, 'next day: 2');
  perform private.streak_record_snap(b, a, test.day_at(2, interval '1 minute')); perform private.streak_record_snap(a, b, test.day_at(2));
  perform test.ok((test.streak(a, b)).count = 3, 'third day: 3');
  -- Day 3: only Ana. Late on day 3 the streak is at risk (⌛), still 3.
  perform private.streak_record_snap(a, b, test.day_at(3));
  select * into v from private.streak_view(b, test.day_at(3, interval '22 hours'));
  perform test.ok(v.count = 3 and v.at_risk and not v.i_sent_today and v.they_sent_today, '⌛ late in a one-sided day');
  select * into v from private.streak_view(b, test.day_at(3, interval '10 hours'));
  perform test.ok(not v.at_risk, 'not at risk earlier in the day');
  perform test.ok(v.expires_at = private.streak_day_end(private.streak_day(test.day_at(3))), 'ends at the end of that day');
  -- Day 4: the job expires it (no one online needed); reads agree even before the job.
  perform test.ok(not exists (select 1 from private.streak_view(a, test.day_at(4))), 'missed day: gone from view before the job');
  r := private.streak_maintenance(test.day_at(4, interval '1 hour'));
  perform test.ok((test.streak(a, b)).count = 0 and (r ->> 'expired')::int >= 1, 'missed day: expired by the job');
  perform test.ok((test.streak(a, b)).best = 3, 'best kept');
  -- A Snap after expiry starts again from 1 only when both send that day.
  perform private.streak_record_snap(b, a, test.day_at(4));
  perform test.ok((test.streak(a, b)).count = 0, 'one side after expiry: 0');
  perform private.streak_record_snap(a, b, test.day_at(4));
  s := test.streak(a, b);
  perform test.ok(s.count = 1 and s.started_on = private.streak_day(test.day_at(4)), 'restart at 1');
  -- A job run (even twice) the same day changes nothing.
  r := private.streak_maintenance(test.day_at(4, interval '20 hours'));
  r := private.streak_maintenance(test.day_at(4, interval '20 hours'));
  perform test.ok((test.streak(a, b)).count = 1, 'job is idempotent');
  -- Just before and just after the boundary are different days: no completion for day 5,
  -- so the streak ends instead of growing.
  perform private.streak_record_snap(a, b, private.streak_day_end(private.streak_day(test.day_at(5))) - interval '1 second');
  perform private.streak_record_snap(b, a, private.streak_day_end(private.streak_day(test.day_at(5))));
  perform test.ok((test.streak(a, b)).count = 0, '23:59:59 and 00:00:00 are not the same day');
end $$;

-- The server timezone decides the day, never the device.
do $$
declare tz text := (select streak_timezone from private.platform_config);
begin
  perform test.as_superuser();
  update private.platform_config set streak_timezone = 'Europe/Amsterdam';
  perform test.ok(private.streak_day('2026-11-14 23:30:00+00') = '2026-11-15', 'Amsterdam: 23:30 UTC is the next day');
  perform test.ok(private.streak_day_end('2026-11-14') = '2026-11-14 23:00:00+00', 'Amsterdam day ends 23:00 UTC in winter');
  perform test.ok(private.streak_day_end('2026-07-14') = '2026-07-14 22:00:00+00', 'and 22:00 UTC in summer');
  update private.platform_config set streak_timezone = 'UTC';
  perform test.ok(private.streak_day('2026-11-14 23:30:00+00') = '2026-11-14', 'UTC');
  perform test.ok(private.streak_day('2026-11-14 23:30:00-05') = '2026-11-15', 'an offset in the input does not matter');
  update private.platform_config set streak_timezone = tz;
end $$;

-- Warnings: once per streak per day, only to whoever has not sent, only near the end.
do $$
declare a uuid; b uuid; c uuid; sa uuid := gen_random_uuid(); sb uuid := gen_random_uuid(); r jsonb; n integer; k text := rpad('B', 87, 'x'); t text := rpad('A', 22, 'y');
begin
  perform test.as_superuser();
  a := test.new_user('stk_w_a_81', 'Wanda'); b := test.new_user('stk_w_b_81', 'Walt');
  perform test.befriend(a, b);
  insert into auth.sessions (id, user_id) values (sa, a), (sb, b);
  perform test.as_user(a, jsonb_build_object('session_id', sa));
  perform public.save_push_subscription('https://fcm.googleapis.com/fcm/send/wa-' || gen_random_uuid(), k, t);
  perform test.as_user(b, jsonb_build_object('session_id', sb));
  perform public.save_push_subscription('https://fcm.googleapis.com/fcm/send/wb-' || gen_random_uuid(), k, t);
  perform public.create_direct_conversation(a);
  perform test.as_superuser();
  -- Streak started on day 1; on day 2 only Wanda has sent.
  perform private.streak_record_snap(a, b, test.day_at(1)); perform private.streak_record_snap(b, a, test.day_at(1));
  perform private.streak_record_snap(a, b, test.day_at(2));
  delete from private.push_queue;
  r := private.streak_maintenance(test.day_at(2, interval '15 hours'));
  perform test.ok((r ->> 'warned')::int = 0, 'no warning early in the day');
  r := private.streak_maintenance(test.day_at(2, interval '21 hours'));
  perform test.ok((select count(*) from private.push_queue where kind = 'streak_warning') = 1
              and (select target_user from private.push_queue where kind = 'streak_warning') = b, 'warned: only Walt, who has not sent');
  r := private.streak_maintenance(test.day_at(2, interval '22 hours'));
  r := private.streak_maintenance(test.day_at(2, interval '23 hours 50 minutes'));
  perform test.ok((select count(*) from private.push_queue where kind = 'streak_warning') = 1, 'no duplicate warning');
  -- What the device gets (claimed while it is still at risk "now": move the streak into today).
  update private.streaks set last_completed_on = private.streak_day(now()) - 1, a_sent_on = private.streak_day(now()),
         b_sent_on = private.streak_day(now()) - 1
   where user_a = least(a, b) and user_b = greatest(a, b);
  perform set_config('role', 'service_role', false);
  select count(*) into n from public.push_claim(100) x
   where x.title = '⌛ Wanda' and x.body like 'Your 🔥 1-day streak ends soon%' and x.url like '/chats/%';
  perform test.ok(n = 1, 'warning: who and the count, opens the chat');
  perform test.as_superuser();
  -- Notifications for streaks off: no warning.
  update private.streaks set warned_on = null where user_a = least(a, b) and user_b = greatest(a, b);
  update public.user_settings set notifications = notifications || '{"streaks": false}' where user_id = b;
  perform private.streak_record_snap(a, b, test.day_at(1)); -- (no change; keeps the scenario)
  update private.streaks set last_completed_on = private.streak_day(test.day_at(2)) - 1, a_sent_on = private.streak_day(test.day_at(2)),
         b_sent_on = private.streak_day(test.day_at(1)), count = 2
   where user_a = least(a, b) and user_b = greatest(a, b);
  delete from private.push_queue;
  r := private.streak_maintenance(test.day_at(2, interval '21 hours'));
  perform test.ok(not exists (select 1 from private.push_queue), 'streak notifications off: none');
end $$;

-- Milestones: once, acknowledged per person, reset with a new streak.
do $$
declare a uuid; b uuid; s private.streaks; v record;
begin
  perform test.as_superuser();
  a := test.new_user('stk_m_a_81', 'Mia'); b := test.new_user('stk_m_b_81', 'Max');
  perform test.befriend(a, b);
  insert into private.streaks (user_a, user_b, count, best, started_on, last_completed_on)
  values (least(a, b), greatest(a, b), 9, 9, private.streak_day(now()) - 9, private.streak_day(now()) - 1);
  perform test.snap(a, array[b]); perform test.snap(b, array[a]);
  s := test.streak(a, b);
  perform test.ok(s.count = 10 and s.milestone = 10, '10 days: milestone');
  perform test.as_user(a);
  perform test.ok((select milestone_unseen from public.my_streaks() where friend_id = b), 'Mia: celebration pending');
  perform public.ack_streak_milestone(b);
  perform test.ok(not (select milestone_unseen from public.my_streaks() where friend_id = b), 'Mia: seen, not repeated');
  perform test.as_user(b);
  perform test.ok((select milestone_unseen from public.my_streaks() where friend_id = a), 'Max: still pending until he sees it');
  perform test.as_superuser();
  perform private.streak_record_snap(a, b, test.day_at(1)); perform private.streak_record_snap(b, a, test.day_at(1));
  s := test.streak(a, b);
  perform test.ok(s.count = 11 and s.milestone = 10, '11: no new milestone');
  update private.streaks set count = 24, last_completed_on = private.streak_day(test.day_at(1)) where user_a = s.user_a and user_b = s.user_b;
  perform private.streak_record_snap(a, b, test.day_at(2)); perform private.streak_record_snap(b, a, test.day_at(2));
  perform test.ok((test.streak(a, b)).milestone = 25, '25: next milestone');
  perform test.ok(private.streak_milestones() = array[10, 25, 50, 100, 250, 365, 500, 1000], 'milestone list');
  -- Acknowledging for someone you have no streak with changes nothing.
  perform test.as_user(a);
  perform public.ack_streak_milestone(gen_random_uuid());
  perform test.as_superuser();
end $$;

-- Friendship changes and deleted accounts.
do $$
declare a uuid; b uuid; c uuid; d uuid; v record;
begin
  perform test.as_superuser();
  a := test.new_user('stk_f_a_81', 'Fay'); b := test.new_user('stk_f_b_81', 'Finn'); c := test.new_user('stk_f_c_81', 'Flo');
  perform test.befriend(a, b); perform test.befriend(a, c);
  perform test.snap(a, array[b, c]); perform test.snap(b, array[a]); perform test.snap(c, array[a]);
  perform test.ok((test.streak(a, b)).count = 1 and (test.streak(a, c)).count = 1, 'two streaks');
  -- Blocking ends it, and no Snap can restart it.
  perform test.as_user(a); perform public.block_user(b);
  perform test.as_superuser();
  perform test.ok((test.streak(a, b)).user_a is null, 'block: streak removed');
  perform private.streak_record_snap(b, a, now());
  perform test.ok((test.streak(a, b)).user_a is null, 'blocked: nothing recorded');
  -- Unfriending ends it; friends again start from 0.
  perform test.as_user(a); perform public.remove_friend(c);
  perform test.as_superuser();
  perform test.ok((test.streak(a, c)).user_a is null, 'unfriend: streak removed');
  perform private.streak_record_snap(a, c, now());
  perform test.ok((test.streak(a, c)).user_a is null, 'not friends: nothing recorded');
  perform test.befriend(a, c);
  perform test.snap(a, array[c]);
  perform test.ok((test.streak(a, c)).count = 0, 'friends again: from 0');
  perform test.snap(c, array[a]);
  perform test.ok((test.streak(a, c)).count = 1, 'and a new streak');
  -- Deleting an account leaves no streak rows behind.
  d := test.new_user('stk_f_d_81', 'Dee');
  perform test.befriend(a, d);
  perform test.snap(a, array[d]); perform test.snap(d, array[a]);
  perform test.ok((test.streak(a, d)).count = 1, 'streak with Dee');
  delete from auth.users where id = d;
  perform test.ok(not exists (select 1 from private.streaks where user_a = d or user_b = d), 'deleted account: no orphan rows');
end $$;
