-- Push notifications (migration 0028): subscriptions, what is queued, who gets what.
do $$
declare a uuid; b uuid; c uuid; sa uuid := gen_random_uuid(); sb uuid := gen_random_uuid(); sc uuid := gen_random_uuid();
        conv uuid; grp uuid; m uuid; r record; n integer;
        ep_b text := 'https://fcm.googleapis.com/fcm/send/b-device-' || gen_random_uuid();
        ep_c text := 'https://updates.push.services.mozilla.com/wpush/v2/c-device-' || gen_random_uuid();
        k text := rpad('B', 87, 'x'); s text := rpad('A', 22, 'y');
begin
  a := test.new_user('push_a_78', 'Amy'); b := test.new_user('push_b_78', 'Ben'); c := test.new_user('push_c_78', 'Cleo');
  perform test.befriend(a, b); perform test.befriend(a, c); perform test.befriend(b, c);
  insert into auth.sessions (id, user_id) values (sa, a), (sb, b), (sc, c);

  -- Subscribing: only real push services, well-formed keys, signed-in users.
  perform test.as_user(b, jsonb_build_object('session_id', sb));
  perform test.throws(format($q$select public.save_push_subscription('https://evil.example/x', %L, %L)$q$, k, s), 'push_endpoint_invalid', 'unknown host refused');
  perform test.throws(format($q$select public.save_push_subscription('http://kong:8000/rest/v1/x', %L, %L)$q$, k, s), 'push_endpoint_invalid', 'internal URL refused');
  perform test.throws(format($q$select public.save_push_subscription('https://fcm.googleapis.com.evil.io/x', %L, %L)$q$, k, s), 'push_endpoint_invalid', 'look-alike host refused');
  perform test.throws(format($q$select public.save_push_subscription(%L, 'short', %L)$q$, ep_b, s), 'push_keys_invalid', 'bad key refused');
  perform public.save_push_subscription(ep_b, k, s);
  perform test.ok(public.has_push_subscription(ep_b), 'saved for this device');
  perform test.as_user(c, jsonb_build_object('session_id', sc));
  perform public.save_push_subscription(ep_c, k, s);
end $$;

do $$
declare a uuid; b uuid; c uuid; conv uuid; grp uuid; m uuid; r record; n integer; ep_b text; ep_c text;
begin
  perform test.as_superuser();
  select id into a from public.profiles where username = 'push_a_78';
  select id into b from public.profiles where username = 'push_b_78';
  select id into c from public.profiles where username = 'push_c_78';
  select endpoint into ep_b from private.push_subscriptions where user_id = b;
  select endpoint into ep_c from private.push_subscriptions where user_id = c;
  perform test.ok((select session_id is not null from private.push_subscriptions where user_id = b), 'tied to the sign-in session');
  perform test.as_user(c);
  perform public.delete_push_subscription(ep_b);
  perform test.as_superuser();
  perform test.ok(exists (select 1 from private.push_subscriptions where endpoint = ep_b), 'nobody can remove another person''s device');
  perform test.as_anon();
  perform test.throws(format($q$select public.save_push_subscription(%L, 'x', 'y')$q$, ep_b), 'sqlstate:42501', 'anon cannot subscribe');

  -- A direct message to Ben: queued, and Ben's device gets "Amy — New Chat", no text.
  perform test.as_user(a);
  conv := public.create_direct_conversation(b);
  perform public.set_chat_expiry(conv, 'never');
  perform test.as_superuser();
  delete from private.push_queue;
  perform test.as_user(a);
  m := public.send_message(conv, 'text', 'top secret words', gen_random_uuid());
  perform test.as_superuser();
  perform test.ok((select count(*) from private.push_queue where kind = 'message' and ref_id = m) = 1, 'new message queued');
  perform test.as_user(b);
  perform test.throws('select * from public.push_claim(10)', 'sqlstate:42501', 'users cannot claim pushes');
  perform set_config('role', 'service_role', false);
  select count(*) into n from public.push_claim(100) x
   where x.endpoint = ep_b and x.title = 'Amy' and x.body = 'New Chat' and x.url = '/chats/' || conv and x.tag = 'chat:' || conv;
  perform test.ok(n = 1, 'Ben''s device: who and "New Chat"');
  perform test.as_superuser();
  perform test.ok(not exists (select 1 from private.push_queue), 'claimed once');

  -- No push when nobody in the chat has a device.
  perform test.as_user(b);
  perform public.send_message(conv, 'text', 'reply', gen_random_uuid());     -- Amy has no subscription
  perform test.as_superuser();
  perform test.ok(not exists (select 1 from private.push_queue), 'nothing queued without a subscribed recipient');

  -- Muted, notifications off, blocked: no push.
  update public.conversation_members set muted_until = now() + interval '1 hour' where conversation_id = conv and user_id = b;
  perform test.as_user(a); m := public.send_message(conv, 'text', 'muted?', gen_random_uuid());
  perform set_config('role', 'service_role', false);
  perform test.ok(not exists (select 1 from public.push_claim(100)), 'muted chat: no push');
  perform test.as_superuser();
  update public.conversation_members set muted_until = null where conversation_id = conv and user_id = b;
  update public.user_settings set notifications = notifications || '{"messages": false}' where user_id = b;
  perform test.as_user(a); m := public.send_message(conv, 'text', 'off?', gen_random_uuid());
  perform set_config('role', 'service_role', false);
  perform test.ok(not exists (select 1 from public.push_claim(100)), 'message notifications off: no push');
  perform test.as_superuser();
  update public.user_settings set notifications = notifications || '{"messages": true}' where user_id = b;

  -- A group: title is the group, body names the sender.
  perform test.as_user(a);
  grp := public.create_group('Trip', array[b, c]);
  perform test.as_superuser(); delete from private.push_queue;
  perform test.as_user(a); m := public.send_message(grp, 'text', 'hi all', gen_random_uuid());
  perform set_config('role', 'service_role', false);
  select count(*) into n from public.push_claim(100) x where x.title = 'Trip' and x.body = 'Amy · New Chat';
  perform test.ok(n = 2, 'both group members'' devices');

  -- Friend request.
  perform test.as_superuser();
  perform test.as_user(b); perform public.remove_friend(c);
  perform test.as_user(c); perform public.send_friend_request(b);
  perform set_config('role', 'service_role', false);
  select count(*) into n from public.push_claim(100) x where x.endpoint = ep_b and x.title = 'New friend request'
     and x.body = '@push_c_78 wants to be friends' and x.url = '/friends';
  perform test.ok(n = 1, 'friend request push');

  -- Blocked sender: nothing.
  perform test.as_user(b); perform public.block_user(a);
  perform test.as_superuser(); delete from private.push_queue;
  insert into private.push_queue (kind, ref_id) values ('message', m);   -- (Amy's group message, replayed)
  perform set_config('role', 'service_role', false);
  select count(*) into n from public.push_claim(100) x where x.endpoint = ep_b;
  perform test.ok(n = 0, 'blocked: no push from them');

  -- Signed out (session gone): never sent, and cleaned up.
  perform test.as_superuser();
  delete from auth.sessions where user_id = c;
  insert into private.push_queue (kind, ref_id) values ('message', m);
  perform set_config('role', 'service_role', false);
  perform test.ok(not exists (select 1 from public.push_claim(100) x where x.endpoint = ep_c), 'signed-out device gets nothing');
  perform public.push_report('{}', '{}');
  perform test.as_superuser();
  perform test.ok(not exists (select 1 from private.push_subscriptions where endpoint = ep_c), 'and its subscription is removed');

  -- Gone at the push service (404/410): removed.
  select id into m from private.push_subscriptions where endpoint = ep_b;
  perform set_config('role', 'service_role', false);
  perform public.push_report(array[m], '{}');
  perform test.as_superuser();
  perform test.ok(not exists (select 1 from private.push_subscriptions where endpoint = ep_b), 'expired subscription removed');
end $$;

-- Fixes from the push review (0030).
do $$
declare a uuid; b uuid; c uuid; sb uuid := gen_random_uuid(); conv uuid; m uuid; n integer; ep text;
begin
  perform test.as_superuser();
  a := test.new_user('push2_a_78', 'Ava'); b := test.new_user('push2_b_78', 'Bo'); c := test.new_user('push2_c_78', 'Cy');
  perform test.befriend(a, b);
  insert into auth.sessions (id, user_id) values (sb, b);
  ep := 'https://fcm.googleapis.com/fcm/send/bo-' || gen_random_uuid();
  perform test.as_user(b, jsonb_build_object('session_id', sb));
  perform public.save_push_subscription(ep, rpad('B', 87, 'x'), rpad('A', 22, 'y'));
  perform test.as_user(a);
  conv := public.create_direct_conversation(b);
  perform test.as_superuser(); delete from private.push_queue;

  -- A malformed setting (anyone can write their own) cannot jam the queue.
  update public.user_settings set notifications = notifications || '{"messages": "yes please"}' where user_id = b;
  perform test.as_user(a); m := public.send_message(conv, 'text', 'still delivered?', gen_random_uuid());
  perform set_config('role', 'service_role', false);
  select count(*) into n from public.push_claim(100) x where x.endpoint = ep;
  perform test.ok(n = 1, 'non-boolean setting counts as on and the claim does not fail');
  perform test.as_superuser();
  update public.user_settings set notifications = notifications || '{"messages": true}' where user_id = b;

  -- Nothing is queued (no function call) when nobody would get it.
  update public.conversation_members set muted_until = now() + interval '1 hour' where conversation_id = conv and user_id = b;
  perform test.as_user(a); perform public.send_message(conv, 'text', 'muted', gen_random_uuid());
  perform test.as_superuser();
  perform test.ok(not exists (select 1 from private.push_queue), 'muted: not even queued');
  update public.conversation_members set muted_until = null where conversation_id = conv and user_id = b;
  delete from auth.sessions where id = sb;
  perform test.as_user(a); perform public.send_message(conv, 'text', 'signed out', gen_random_uuid());
  perform test.as_superuser();
  perform test.ok(not exists (select 1 from private.push_queue), 'no signed-in device: not queued');
  insert into auth.sessions (id, user_id) values (sb, b);

  -- One friend-request notification per sender and recipient a day.
  perform test.as_user(c); perform public.send_friend_request(b);
  perform test.as_superuser();
  perform test.ok((select count(*) from private.push_queue where kind = 'friend_request') = 1, 'first request queued');
  perform test.as_user(c);
  perform public.cancel_friend_request((select id from public.friend_requests where sender_id = c and recipient_id = b and status = 'pending'));
  perform public.send_friend_request(b);
  perform test.as_superuser();
  perform test.ok((select count(*) from private.push_queue where kind = 'friend_request') = 1, 'send-cancel-send does not buzz again');

  -- The sweep drops stale entries.
  update private.push_queue set created_at = now() - interval '2 days';
  perform private.push_sweep();
  perform test.ok(not exists (select 1 from private.push_queue), 'entries older than a day dropped');
end $$;
