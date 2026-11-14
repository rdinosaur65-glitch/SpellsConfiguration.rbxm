-- PULSE 0032 — Snap streaks.
--
-- Rules (all decided by the database; the app only displays):
-- * A streak belongs to two accepted friends. It counts days on which BOTH sent the other
--   at least one photo or video Snap directly (not in a group). Texts, voice notes,
--   reactions and group activity never count.
-- * Days are server days: [00:00, 24:00) in platform_config.streak_timezone (UTC by
--   default), taken from the database clock when the Snap reaches the server. Device
--   clocks play no part; a Snap queued offline counts on the day the server receives it.
-- * The first day both have sent → 1. Each following day both send → +1, at most once a
--   day (the completion is recorded under a row lock; more Snaps that day change nothing).
--   A day without the exchange ends the streak (back to 0 at the next day boundary).
-- * Expiry and warnings run every 10 minutes (pg_cron), whether or not anyone is online;
--   reads also apply expiry themselves, so a late job never shows a dead streak as alive.
--   One warning per streak per day, only to the friend(s) who have not sent yet that day,
--   in the last streak_warn_hours of the day, and only if their "streaks" notifications are on.
-- * Milestones 10, 25, 50, 100, 250, 365, 500, 1000: recorded once per streak; each friend
--   acknowledges the celebration once (no notification, no repeats).
-- * Only the two friends can read a streak (my_streaks). Unfriending or blocking deletes
--   it; becoming friends again starts from 0. Account deletion cascades.

alter table private.platform_config
  add column if not exists streak_timezone text not null default 'UTC',
  add column if not exists streak_warn_hours integer not null default 4 check (streak_warn_hours between 1 and 12);

create table private.streaks (
  user_a uuid not null references public.profiles(id) on delete cascade,
  user_b uuid not null references public.profiles(id) on delete cascade,
  count integer not null default 0 check (count >= 0),
  best integer not null default 0 check (best >= 0),
  started_on date,
  last_completed_on date,
  a_sent_on date,
  b_sent_on date,
  warned_on date,
  milestone integer not null default 0,
  milestone_on date,
  a_milestone_seen integer not null default 0,
  b_milestone_seen integer not null default 0,
  updated_at timestamptz not null default now(),
  primary key (user_a, user_b),
  check (user_a < user_b)
);
create index streaks_user_b on private.streaks (user_b);
create index streaks_live on private.streaks (last_completed_on) where count > 0;

create or replace function private.streak_milestones()
returns integer[] language sql immutable set search_path = '' as $$
  select array[10, 25, 50, 100, 250, 365, 500, 1000]
$$;

-- The server day a moment belongs to, and when a day ends.
create or replace function private.streak_day(p_at timestamptz)
returns date language sql stable security definer set search_path = '' as $$
  select (p_at at time zone (select streak_timezone from private.platform_config where id))::date
$$;
create or replace function private.streak_day_end(p_day date)
returns timestamptz language sql stable security definer set search_path = '' as $$
  select ((p_day + 1)::timestamp at time zone (select streak_timezone from private.platform_config where id))
$$;

-- One qualifying Snap from p_sender to p_recipient at p_at (the trigger passes now()).
create or replace function private.streak_record_snap(p_sender uuid, p_recipient uuid, p_at timestamptz default now())
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_a uuid := least(p_sender, p_recipient);
  v_b uuid := greatest(p_sender, p_recipient);
  v_day date := private.streak_day(p_at);
  s private.streaks;
begin
  if p_sender = p_recipient or not private.are_friends(p_sender, p_recipient)
     or private.is_blocked_either(p_sender, p_recipient) then
    return;
  end if;
  insert into private.streaks (user_a, user_b) values (v_a, v_b) on conflict do nothing;
  select * into s from private.streaks where user_a = v_a and user_b = v_b for update;

  if s.count > 0 and (s.last_completed_on is null or s.last_completed_on < v_day - 1) then
    s.count := 0;                                            -- missed a day (job not run yet)
  end if;
  if p_sender = v_a then s.a_sent_on := greatest(coalesce(s.a_sent_on, v_day), v_day);
                    else s.b_sent_on := greatest(coalesce(s.b_sent_on, v_day), v_day); end if;

  if s.a_sent_on = v_day and s.b_sent_on = v_day and s.last_completed_on is distinct from v_day then
    if s.count > 0 then
      s.count := s.count + 1;                                -- yesterday was completed
    else
      s.count := 1; s.started_on := v_day;                   -- a new streak
      s.milestone := 0; s.milestone_on := null; s.a_milestone_seen := 0; s.b_milestone_seen := 0;
    end if;
    s.last_completed_on := v_day;
    s.best := greatest(s.best, s.count);
    if s.count = any (private.streak_milestones()) and s.count > s.milestone then
      s.milestone := s.count; s.milestone_on := v_day;
    end if;
  end if;

  update private.streaks
     set count = s.count, best = s.best, started_on = s.started_on, last_completed_on = s.last_completed_on,
         a_sent_on = s.a_sent_on, b_sent_on = s.b_sent_on, milestone = s.milestone, milestone_on = s.milestone_on,
         a_milestone_seen = s.a_milestone_seen, b_milestone_seen = s.b_milestone_seen, updated_at = now()
   where user_a = v_a and user_b = v_b;
end $$;

-- Every Snap delivery row (only send_snap writes them) — direct chats only.
create or replace function private.streak_on_snap()
returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if exists (select 1 from public.conversations c where c.id = new.conversation_id and c.kind = 'direct')
     and exists (select 1 from public.snaps sn where sn.id = new.snap_id and sn.media_kind in ('photo', 'video')) then
    perform private.streak_record_snap(new.sender_id, new.recipient_id, now());
  end if;
  return null;
end $$;
drop trigger if exists streak_on_snap on public.snap_recipients;
create trigger streak_on_snap after insert on public.snap_recipients
  for each row execute function private.streak_on_snap();

-- Unfriending or blocking ends the streak for good (a new friendship starts from 0).
create or replace function private.streak_end()
returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if tg_table_name = 'friendships' then
    delete from private.streaks where user_a = old.user_a and user_b = old.user_b;
  else
    delete from private.streaks
     where user_a = least(new.blocker_id, new.blocked_id) and user_b = greatest(new.blocker_id, new.blocked_id);
  end if;
  return null;
end $$;
drop trigger if exists streak_end_unfriend on public.friendships;
create trigger streak_end_unfriend after delete on public.friendships
  for each row execute function private.streak_end();
drop trigger if exists streak_end_block on public.blocks;
create trigger streak_end_block after insert on public.blocks
  for each row execute function private.streak_end();

-- ---------------------------------------------------------------------------
-- Reading (only the two friends; expiry applied on the fly).
-- ---------------------------------------------------------------------------
create or replace function private.streak_view(p_user uuid, p_now timestamptz)
returns table (friend_id uuid, count integer, completed_today boolean, i_sent_today boolean, they_sent_today boolean,
               at_risk boolean, expires_at timestamptz, best integer, milestone integer, milestone_unseen boolean,
               day_ends_at timestamptz)
language sql stable security definer set search_path = '' as $$
  with d as (select private.streak_day(p_now) as day, (select streak_warn_hours from private.platform_config where id) as warn)
  select case when s.user_a = p_user then s.user_b else s.user_a end,
         s.count,
         s.last_completed_on = d.day,
         case when s.user_a = p_user then s.a_sent_on else s.b_sent_on end = d.day,
         case when s.user_a = p_user then s.b_sent_on else s.a_sent_on end = d.day,
         s.last_completed_on < d.day and p_now >= private.streak_day_end(d.day) - make_interval(hours => d.warn),
         private.streak_day_end(case when s.last_completed_on = d.day then d.day + 1 else d.day end),
         s.best,
         s.milestone,
         s.milestone > case when s.user_a = p_user then s.a_milestone_seen else s.b_milestone_seen end,
         private.streak_day_end(d.day)
    from private.streaks s, d
   where (s.user_a = p_user or s.user_b = p_user)
     and s.count > 0 and s.last_completed_on >= d.day - 1
     and private.are_friends(s.user_a, s.user_b)
     and not private.is_blocked_either(s.user_a, s.user_b)
$$;

create or replace function public.my_streaks()
returns table (friend_id uuid, count integer, completed_today boolean, i_sent_today boolean, they_sent_today boolean,
               at_risk boolean, expires_at timestamptz, best integer, milestone integer, milestone_unseen boolean,
               day_ends_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active();
begin
  return query select * from private.streak_view(v_uid, now());
end $$;

-- When the current streak day ends (for "Streak days end at …" in the app).
create or replace function public.streak_clock()
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_cfg private.platform_config := private.config();
begin
  return jsonb_build_object('timezone', v_cfg.streak_timezone, 'warn_hours', v_cfg.streak_warn_hours,
                            'day_ends_at', private.streak_day_end(private.streak_day(now())));
end $$;

-- "I've seen the celebration" (per friend, once). Changes nothing else.
create or replace function public.ack_streak_milestone(p_friend uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active();
begin
  perform private.rate_limit_hit('ack_streak_milestone', 200, interval '1 hour');
  update private.streaks
     set a_milestone_seen = case when user_a = v_uid then milestone else a_milestone_seen end,
         b_milestone_seen = case when user_b = v_uid then milestone else b_milestone_seen end
   where user_a = least(v_uid, p_friend) and user_b = greatest(v_uid, p_friend);
end $$;

-- ---------------------------------------------------------------------------
-- Expiry and warnings (pg_cron every 10 minutes; p_now only for tests).
-- ---------------------------------------------------------------------------
alter table private.push_queue drop constraint if exists push_queue_kind_check;
alter table private.push_queue
  add constraint push_queue_kind_check check (kind in ('message', 'friend_request', 'streak_warning')),
  add column if not exists target_user uuid;            -- streak_warning: who is told; ref_id = the friend

create or replace function private.streak_maintenance(p_now timestamptz default now())
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_day date := private.streak_day(p_now);
  v_warn integer := (private.config()).streak_warn_hours;
  v_expired integer; v_warned integer := 0; v_dormant integer;
begin
  update private.streaks set count = 0, updated_at = now()
   where count > 0 and last_completed_on < v_day - 1;
  get diagnostics v_expired = row_count;
  -- Rows with no streak and no Snap for 30 days carry no information.
  delete from private.streaks
   where count = 0 and coalesce(greatest(a_sent_on, b_sent_on), v_day - 31) < v_day - 30;
  get diagnostics v_dormant = row_count;

  if p_now >= private.streak_day_end(v_day) - make_interval(hours => v_warn) then
    with w as (
      update private.streaks s set warned_on = v_day
       where s.count > 0 and s.last_completed_on = v_day - 1 and s.warned_on is distinct from v_day
      returning s.user_a, s.user_b, s.a_sent_on, s.b_sent_on
    ), t as (
      select w.user_a as rid, w.user_b as peer from w where w.a_sent_on is distinct from v_day
      union all
      select w.user_b, w.user_a from w where w.b_sent_on is distinct from v_day
    )
    insert into private.push_queue (kind, ref_id, target_user)
    select 'streak_warning', t.peer, t.rid from t
     where private.are_friends(t.rid, t.peer) and not private.is_blocked_either(t.rid, t.peer)
       and exists (select 1 from public.profiles p where p.id = t.rid and p.account_state = 'active')
       and private.push_wanted(t.rid, 'streaks') and private.push_device_live(t.rid);
    get diagnostics v_warned = row_count;
    if v_warned > 0 then perform private.invoke_push(); end if;
  end if;
  return jsonb_build_object('expired', v_expired, 'warned', v_warned, 'dormant_removed', v_dormant);
end $$;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'pulse-streaks';
    perform cron.schedule('pulse-streaks', '*/10 * * * *', 'select private.streak_maintenance()');
  end if;
end $$;

-- send_snap as in 0017, with recipients sorted.
create or replace function public.send_snap(
  p_media_asset uuid, p_recipients uuid[], p_groups uuid[], p_view_seconds smallint,
  p_allow_saving boolean, p_client_id uuid)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.assert_active();
  a public.media_assets;
  v_snap uuid; v_kind text; r uuid; g uuid; v_conv uuid; v_count integer := 0;
  v_peers uuid[] := private.my_block_peers();
begin
  if p_client_id is null then perform private.fail('client_id_required'); end if;
  select id into v_snap from public.snaps where sender_id = v_uid and client_id = p_client_id;
  if v_snap is not null then return v_snap; end if;

  perform private.rate_limit_hit('send_snap', 60, interval '1 hour');
  perform private.assert_db_headroom();
  select * into a from public.media_assets where id = p_media_asset;
  if a.id is null or a.owner_id <> v_uid or a.purpose <> 'snap' or a.status <> 'uploaded' then
    perform private.fail('invalid_media');
  end if;
  v_kind := case when a.mime_type like 'video/%' then 'video' else 'photo' end;
  if v_kind = 'photo' and p_view_seconds is not null and p_view_seconds not between 1 and 10 then
    perform private.fail('invalid_view_seconds');
  end if;
  -- Each person and each group at most once (repeats used to write one message each).
  -- Sorted: streak rows are locked in one global order, so simultaneous Snaps between the
  -- same friends can never deadlock (0032).
  p_recipients := array(select distinct x from unnest(coalesce(p_recipients, '{}')) x where x is not null order by x);
  p_groups := array(select distinct x from unnest(coalesce(p_groups, '{}')) x where x is not null);
  if coalesce(array_length(p_recipients, 1), 0) + coalesce(array_length(p_groups, 1), 0) > 50 then
    perform private.fail('too_many_recipients');
  end if;

  insert into public.snaps (sender_id, media_asset_id, media_kind, view_seconds, video_seconds,
                            allow_saving, client_id, expires_at)
  values (v_uid, a.id, v_kind, case when v_kind = 'photo' then p_view_seconds end,
          case when v_kind = 'video' then a.duration_seconds end,
          coalesce(p_allow_saving, false), p_client_id, now() + (private.config()).unopened_snap_ttl)
  on conflict (sender_id, client_id) do nothing
  returning id into v_snap;
  if v_snap is null then
    select id into v_snap from public.snaps where sender_id = v_uid and client_id = p_client_id;
    return v_snap;
  end if;

  foreach r in array coalesce(p_recipients, '{}') loop
    if r = v_uid then continue; end if;
    if not private.are_friends(v_uid, r) then perform private.fail('not_friends', r::text); end if;
    perform private.assert_can_interact(v_uid, r);
    v_conv := private.ensure_direct_conversation(v_uid, r);
    insert into public.snap_recipients (snap_id, recipient_id, conversation_id, sender_id)
    values (v_snap, r, v_conv, v_uid) on conflict do nothing;
    perform private.rate_limit_hit('send_message_day', 2000, interval '1 day');
    insert into public.messages (conversation_id, sender_id, kind, snap_id, client_msg_id, expiry_mode)
    values (v_conv, v_uid, 'snap', v_snap, gen_random_uuid(), 'never');
    update public.conversations set last_message_at = now() where id = v_conv;
    v_count := v_count + 1;
  end loop;

  foreach g in array coalesce(p_groups, '{}') loop
    if not private.is_member(g, v_uid)
       or (select kind from public.conversations where id = g) <> 'group' then
      perform private.fail('not_a_member', g::text);
    end if;
    perform private.rate_limit_hit('send_message_day', 2000, interval '1 day');
    insert into public.snap_recipients (snap_id, recipient_id, conversation_id, sender_id)
    select v_snap, cm.user_id, g, v_uid from public.conversation_members cm
     where cm.conversation_id = g and cm.left_at is null and cm.user_id <> v_uid
       and cm.user_id <> all (v_peers)
    on conflict do nothing;
    insert into public.messages (conversation_id, sender_id, kind, snap_id, client_msg_id, expiry_mode)
    values (g, v_uid, 'snap', v_snap, gen_random_uuid(), 'never');
    update public.conversations set last_message_at = now() where id = g;
    v_count := v_count + 1;
  end loop;

  if v_count = 0 then perform private.fail('no_recipients'); end if;
  return v_snap;
end $$;
revoke execute on function public.send_snap(uuid, uuid[], uuid[], smallint, boolean, uuid) from public, anon;
grant execute on function public.send_snap(uuid, uuid[], uuid[], smallint, boolean, uuid) to authenticated;

-- push_claim as in 0030, plus streak warnings.
create or replace function public.push_claim(p_limit integer default 100)
returns table (subscription_id uuid, endpoint text, p256dh text, auth text,
               title text, body text, url text, tag text)
language plpgsql security definer set search_path = '' as $$
begin
  return query
  with claimed as (
    delete from private.push_queue q
     where q.id in (select id from private.push_queue order by id limit greatest(1, least(p_limit, 500)) for update skip locked)
    returning q.kind, q.ref_id, q.target_user, q.created_at
  ), msg as (
    select cm.user_id as rid,
      case when cv.kind = 'group' then coalesce(cv.name, 'Group')
           else coalesce(n.nickname, sp.display_name) end as title,
      case when cv.kind = 'group' then coalesce(n.nickname, sp.display_name) || ' · ' else '' end
        || case when m.kind = 'snap' then 'New Snap' else 'New Chat' end as body,
      '/chats/' || cv.id as url, 'chat:' || cv.id as tag
    from claimed c
    join public.messages m on m.id = c.ref_id and m.deleted_at is null
    join public.conversations cv on cv.id = m.conversation_id
    join public.profiles sp on sp.id = m.sender_id
    join public.conversation_members cm on cm.conversation_id = m.conversation_id and cm.left_at is null
                                       and cm.user_id <> m.sender_id and cm.joined_at <= m.created_at
    join public.profiles rp on rp.id = cm.user_id and rp.account_state = 'active'
    left join public.friend_nicknames n on n.owner_id = cm.user_id and n.friend_id = m.sender_id
    where c.kind = 'message' and c.created_at > now() - interval '1 hour'
      and (cm.muted_until is null or cm.muted_until <= now())
      and not private.is_blocked_either(cm.user_id, m.sender_id)
      and private.push_wanted(cm.user_id, case when m.kind = 'snap' then 'snaps' else 'messages' end)
  ), req as (
    select fr.recipient_id as rid, 'New friend request'::text as title,
      '@' || sp.username || ' wants to be friends' as body, '/friends'::text as url, 'friend-requests'::text as tag
    from claimed c
    join public.friend_requests fr on fr.id = c.ref_id and fr.status = 'pending'
    join public.profiles sp on sp.id = fr.sender_id and sp.account_state = 'active'
    join public.profiles rp on rp.id = fr.recipient_id and rp.account_state = 'active'
    where c.kind = 'friend_request' and c.created_at > now() - interval '1 hour'
      and not private.is_blocked_either(fr.recipient_id, fr.sender_id)
      and private.push_wanted(fr.recipient_id, 'friend_requests')
  ), streak as (
    -- Still at risk when the device is reached (not completed meanwhile), still friends.
    select c.target_user as rid,
      '⌛ ' || coalesce(n.nickname, pp.display_name) as title,
      'Your 🔥 ' || s.count || '-day streak ends soon. Send a Snap to keep it going.' as body,
      coalesce('/chats/' || cv.id, '/camera') as url,
      'streak:' || c.ref_id as tag
    from claimed c
    join private.streaks s on s.user_a = least(c.target_user, c.ref_id) and s.user_b = greatest(c.target_user, c.ref_id)
    join public.profiles pp on pp.id = c.ref_id and pp.account_state = 'active'
    join public.profiles rp on rp.id = c.target_user and rp.account_state = 'active'
    left join public.friend_nicknames n on n.owner_id = c.target_user and n.friend_id = c.ref_id
    left join public.conversations cv on cv.direct_key = least(c.target_user, c.ref_id)::text || ':' || greatest(c.target_user, c.ref_id)::text
    where c.kind = 'streak_warning' and c.created_at > now() - interval '1 hour'
      and s.count > 0 and s.last_completed_on = private.streak_day(now()) - 1
      and private.are_friends(c.target_user, c.ref_id) and not private.is_blocked_either(c.target_user, c.ref_id)
      and private.push_wanted(c.target_user, 'streaks')
  ), targets as (select * from msg union all select * from req union all select * from streak)
  select ps.id, ps.endpoint, ps.p256dh, ps.auth, t.title, t.body, t.url, t.tag
    from targets t
    join private.push_subscriptions ps on ps.user_id = t.rid
    -- Only devices that are still signed in to that account.
    join auth.sessions s on s.id = ps.session_id and s.user_id = ps.user_id
   where private.push_endpoint_allowed(ps.endpoint);
end $$;

revoke execute on function
  private.streak_milestones(), private.streak_day(timestamptz), private.streak_day_end(date),
  private.streak_record_snap(uuid, uuid, timestamptz), private.streak_on_snap(), private.streak_end(),
  private.streak_view(uuid, timestamptz), private.streak_maintenance(timestamptz),
  public.my_streaks(), public.streak_clock(), public.ack_streak_milestone(uuid)
  from public, anon, authenticated;
grant execute on function public.my_streaks(), public.streak_clock(), public.ack_streak_milestone(uuid) to authenticated;
revoke execute on function public.push_claim(integer) from public, anon, authenticated;
grant execute on function public.push_claim(integer) to service_role;
