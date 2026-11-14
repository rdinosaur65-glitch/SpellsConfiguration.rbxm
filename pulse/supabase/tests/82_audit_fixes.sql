-- Regression tests for the pre-launch security audit (migration 0033).
do $$
declare a uuid; b uuid; c uuid; conv uuid; m uuid; snap_asset uuid; prof_asset uuid; sa uuid := gen_random_uuid(); sb uuid := gen_random_uuid();
        ep text := 'https://fcm.googleapis.com/fcm/send/audit-' || gen_random_uuid(); n integer; inv text; d uuid;
        k text := rpad('B', 87, 'x'); s text := rpad('A', 22, 'y');
begin
  perform test.as_superuser();
  a := test.new_user('aud_a_82', 'Ada'); b := test.new_user('aud_b_82', 'Bob'); c := test.new_user('aud_c_82', 'Cat');
  perform test.befriend(a, b);

  -- 1. A suspended account cannot erase its messages (evidence for reports).
  perform test.as_user(a);
  conv := public.create_direct_conversation(b);
  m := public.send_message(conv, 'text', 'nasty words', gen_random_uuid());
  perform test.as_superuser();
  update public.profiles set account_state = 'suspended' where id = a;
  perform test.as_user(a);
  perform test.throws(format('select public.delete_message(%L)', m), 'account_not_active', 'suspended: cannot delete a message');
  perform test.as_superuser();
  perform test.ok((select body from public.messages where id = m) = 'nasty words', 'message still there for the report');
  update public.profiles set account_state = 'active' where id = a;

  -- 2. Avatar/banner only from my own profile pictures.
  snap_asset := test.upload(a, 'snap', 'image/webp', 1000);
  prof_asset := test.upload(a, 'profile', 'image/webp', 1000);
  perform test.as_user(a);
  perform test.throws(format('update public.profiles set avatar_asset_id = %L where id = %L', snap_asset, a), 'invalid_media', 'avatar cannot point at a Snap');
  perform test.throws(format('update public.profiles set avatar_asset_id = %L where id = %L', gen_random_uuid(), a), 'invalid_media', 'avatar cannot point at anything else');
  update public.profiles set avatar_asset_id = prof_asset where id = a;
  perform test.ok((select avatar_asset_id from public.profiles where id = a) = prof_asset, 'own profile picture accepted');
  update public.profiles set avatar_asset_id = null where id = a;
  perform test.ok((select avatar_asset_id from public.profiles where id = a) is null, 'and can be removed');

  -- 3. A nickname cannot be moved to someone who is not a friend.
  insert into public.friend_nicknames (owner_id, friend_id, nickname) values (a, b, 'Bobby');
  perform test.throws(format('update public.friend_nicknames set friend_id = %L where owner_id = %L', c, a), 'sqlstate:42501', 'nickname moved to a non-friend: refused');

  -- 4. After being blocked, the sender no longer sees whether the Snap was opened.
  perform test.as_superuser();
  snap_asset := test.upload(a, 'snap', 'image/webp', 1000);
  perform test.as_user(a);
  perform public.send_snap(snap_asset, array[b], null, 3::smallint, false, gen_random_uuid());
  perform test.ok(exists (select 1 from public.snap_recipients where recipient_id = b), 'sender sees delivery state');
  perform test.as_user(b); perform public.block_user(a);
  perform test.as_user(a);
  perform test.ok(not exists (select 1 from public.snap_recipients where recipient_id = b), 'blocked: delivery state hidden');
  perform test.as_user(b); perform public.unblock_user(a);

  -- 5. Presence of a banned friend is not shown.
  perform test.as_superuser();
  perform test.befriend(a, c);
  update public.profiles set account_state = 'banned' where id = c;
  perform test.as_user(a);
  perform test.ok(not exists (select 1 from public.get_friend_presence() where user_id = c), 'banned friend: no presence');
  perform test.as_superuser();
  update public.profiles set account_state = 'active' where id = c;

  -- 6. Error reports older than 14 days are purged by the job.
  insert into private.client_errors (user_id, message, created_at) values (a, 'old error 82', now() - interval '15 days');
  perform private.purge_client_errors();
  perform test.ok(not exists (select 1 from private.client_errors where message = 'old error 82'), 'old error report purged');

  -- 7. A deleted account's username is cleared from its invitation.
  inv := test.new_invite();
  insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
  values (gen_random_uuid(), 'gone82@test.local', now(), jsonb_build_object('username', 'gone_82', 'invite_code', inv)) returning id into d;
  perform test.ok((select redeemed_username from private.invitations where code = inv) = 'gone_82', 'invitation shows who joined');
  delete from auth.users where id = d;
  perform test.ok((select redeemed_username from private.invitations where code = inv) is null, 'deleted account: username cleared');
  perform test.ok((select redeemed_at is not null from private.invitations where code = inv), 'invitation stays used');

  -- 8. Push keys must be exact; a device someone else is signed in on cannot be taken over.
  insert into auth.sessions (id, user_id) values (sa, a), (sb, b);
  perform test.as_user(a, jsonb_build_object('session_id', sa));
  perform test.throws(format($q$select public.save_push_subscription(%L, %L, %L)$q$, ep, rpad('B', 86, 'x'), s), 'push_keys_invalid', 'short key refused');
  perform public.save_push_subscription(ep, k, s);
  perform test.as_user(b, jsonb_build_object('session_id', sb));
  perform public.save_push_subscription(ep, k, s);
  perform test.as_superuser();
  perform test.ok((select user_id from private.push_subscriptions where endpoint = ep) = a, 'live device not taken over');
  delete from auth.sessions where id = sa;               -- Ada signed out on that device
  perform test.as_user(b, jsonb_build_object('session_id', sb));
  perform public.save_push_subscription(ep, k, s);
  perform test.as_superuser();
  perform test.ok((select user_id from private.push_subscriptions where endpoint = ep) = b, 'after sign-out the device can be reused');
end $$;
