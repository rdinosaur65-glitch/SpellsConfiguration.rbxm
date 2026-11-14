-- Friend discovery, requests, friendship visibility, nicknames, blocking, presence.
do $$
declare a uuid; b uuid; c uuid; d uuid; r uuid; n integer;
begin
  a := test.new_user('anna_20'); b := test.new_user('ben_20'); c := test.new_user('cara_20');
  d := test.new_user('dan_20');

  -- Non-friends cannot read each other's profiles; search returns a minimal card.
  perform test.as_user(a);
  perform test.ok((select count(*) from public.profiles where id = b) = 0, 'non-friend profile hidden');
  perform test.ok((select count(*) from public.search_users('ben_2')) = 1, 'partial username search');
  perform test.ok((select relationship from public.search_users('ben_20')) = 'none', 'relationship none');
  perform test.throws($q$select public.search_users('be')$q$, 'query_too_short', 'min 3 chars');

  -- Request -> duplicate rejected -> accept.
  r := public.send_friend_request(b);
  perform test.throws(format('select public.send_friend_request(%L)', b), 'request_exists', 'no duplicate request');
  perform test.ok((select relationship from public.search_users('ben_20')) = 'request_sent', 'shows request_sent');
  perform test.throws(format('select public.respond_friend_request(%L, true)', r), 'request_not_found',
                      'sender cannot accept own request');
  perform test.as_user(b);
  perform public.respond_friend_request(r, true);
  perform test.ok(private.are_friends(a, b), 'friends after accept');
  perform test.ok((select count(*) from public.friendships where user_a = least(a,b) and user_b = greatest(a,b)) = 1,
                  'single canonical friendship row');
  perform test.ok((select count(*) from public.profiles where id = a) = 1, 'friend profile visible');

  -- Cancel and decline.
  perform test.as_user(a);
  r := public.send_friend_request(c);
  perform public.cancel_friend_request(r);
  perform test.ok((select status from public.friend_requests where id = r) = 'cancelled', 'cancelled');
  r := public.send_friend_request(c);
  perform test.as_user(c);
  perform public.respond_friend_request(r, false);
  perform test.ok(not private.are_friends(a, c), 'declined -> not friends');
  -- Mutual request auto-accepts.
  perform test.as_user(d);
  r := public.send_friend_request(c);
  perform test.as_user(c);
  perform public.send_friend_request(d);
  perform test.ok(private.are_friends(c, d), 'mutual request accepted');
  -- Third parties cannot see others' requests.
  perform test.as_user(b);
  perform test.ok((select count(*) from public.friend_requests where sender_id = d) = 0, 'requests private');
  perform test.as_superuser();
end $$;

-- Private nicknames.
do $$
declare a uuid := (select id from public.profiles where username = 'anna_20');
        b uuid := (select id from public.profiles where username = 'ben_20');
        c uuid := (select id from public.profiles where username = 'cara_20');
begin
  perform test.as_user(a);
  insert into public.friend_nicknames (owner_id, friend_id, nickname, color) values (a, b, 'Benny', '#ff00aa');
  perform test.ok((select nickname from public.friend_nicknames where friend_id = b) = 'Benny', 'owner sees nickname');
  perform test.throws(format($q$insert into public.friend_nicknames (owner_id, friend_id, nickname) values (%L, %L, 'x')$q$, a, c),
                      'sqlstate:42501', 'nickname only for friends');
  perform test.throws(format($q$insert into public.friend_nicknames (owner_id, friend_id, nickname) values (%L, %L, 'x')$q$, b, a),
                      'sqlstate:42501', 'cannot write nickname as someone else');
  perform test.as_user(b);
  perform test.ok((select count(*) from public.friend_nicknames) = 0, 'nickname invisible to the friend');
  perform test.as_superuser();
end $$;

-- Presence respects Ghost Mode server-side.
do $$
declare a uuid := (select id from public.profiles where username = 'anna_20');
        b uuid := (select id from public.profiles where username = 'ben_20');
begin
  perform test.as_user(b);
  perform public.touch_presence();
  perform test.as_user(a);
  perform test.ok((select online from public.get_friend_presence() where user_id = b), 'friend online visible');
  perform test.as_user(b);
  update public.user_settings set ghost_mode = true where user_id = b;
  perform test.as_user(a);
  perform test.ok((select online is null and last_active_at is null from public.get_friend_presence() where user_id = b),
                  'ghost mode hides presence');
  perform test.throws($q$select * from private.presence$q$, 'sqlstate:42501', 'raw presence table closed');
  perform test.as_superuser();
end $$;

-- Blocking cuts every path.
do $$
declare a uuid := (select id from public.profiles where username = 'anna_20');
        b uuid := (select id from public.profiles where username = 'ben_20');
begin
  perform test.as_user(b);
  perform public.block_user(a);
  perform test.ok(not private.are_friends(a, b), 'block removes friendship');
  perform test.as_user(a);
  perform test.ok((select count(*) from public.blocks) = 0, 'blocked user cannot see the block');
  perform test.ok((select count(*) from public.search_users('ben_20')) = 0, 'blocker hidden from search');
  perform test.ok((select count(*) from public.profiles where id = b) = 0, 'blocker profile hidden');
  perform test.ok((select count(*) from public.friend_nicknames where friend_id = b) = 0, 'nickname removed');
  perform test.throws(format('select public.send_friend_request(%L)', b), 'not_allowed', 'cannot re-request');
  perform test.throws(format('select public.create_direct_conversation(%L)', b), 'not_allowed', 'cannot open chat');
  perform test.as_user(b);
  perform public.unblock_user(a);
  perform test.ok((select count(*) from public.blocks) = 0, 'unblocked');
  perform test.as_superuser();
end $$;
