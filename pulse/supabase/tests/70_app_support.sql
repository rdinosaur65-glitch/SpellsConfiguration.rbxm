-- my_friend_requests(), list_friends(), purge_unconfirmed_signups().
do $$
declare a uuid; b uuid; c uuid; d uuid; r uuid; stale uuid; fresh uuid; confirmed uuid;
begin
  a := test.new_user('ava_70', 'Ava'); b := test.new_user('bo_70', 'Bo');
  c := test.new_user('cy_70', 'Cy'); d := test.new_user('di_70', 'Di');

  perform test.as_user(a);
  r := public.send_friend_request(b);
  perform test.ok((select direction from public.my_friend_requests() where id = r) = 'outgoing', 'sender sees outgoing');
  perform test.as_user(b);
  perform test.ok((select username from public.my_friend_requests() where id = r) = 'ava_70', 'recipient sees sender card');
  perform test.ok((select direction from public.my_friend_requests() where id = r) = 'incoming', 'incoming');
  perform test.as_user(c);
  perform test.ok((select count(*) from public.my_friend_requests()) = 0, 'third party sees nothing');

  -- A block hides the pending request from the blocked side's list.
  perform test.as_user(b);
  perform public.block_user(a);
  perform test.as_user(a);
  perform test.ok((select count(*) from public.my_friend_requests()) = 0, 'blocked: request gone');
  perform test.as_user(b);
  perform public.unblock_user(a);

  -- list_friends: nickname applied, ghost mode hides presence.
  perform test.as_superuser();
  perform test.befriend(c, d);
  perform test.as_user(c);
  insert into public.friend_nicknames (owner_id, friend_id, nickname, color) values (c, d, 'Dee', '#ff0000');
  perform test.ok((select nickname from public.list_friends() where user_id = d) = 'Dee', 'nickname applied');
  perform test.ok((select online from public.list_friends() where user_id = d) is not null, 'presence visible');
  perform test.as_user(d);
  update public.user_settings set ghost_mode = true where user_id = d;
  -- Each check requires the row to exist, so a missing row cannot pass as "hidden".
  perform test.ok((select count(*) = 1 and bool_and(nickname is null) from public.list_friends() where user_id = c),
                  'nicknames private');
  perform test.as_user(c);
  perform test.ok((select count(*) = 1 and bool_and(online is null) from public.list_friends() where user_id = d),
                  'ghost mode hides online');
  perform test.ok((select count(*) = 1 and bool_and(last_active_at is null) from public.list_friends() where user_id = d),
                  'ghost mode hides last active');
  perform test.as_user(a);
  perform test.ok((select count(*) from public.list_friends()) = 0, 'non-friends listed nowhere');

  -- Anonymous callers cannot use the new RPCs.
  perform test.as_anon();
  perform test.throws('select * from public.list_friends()', 'sqlstate:42501', 'anon blocked');
  perform test.throws('select * from public.my_friend_requests()', 'sqlstate:42501', 'anon blocked 2');

  -- Purge: only stale + unconfirmed accounts go; the username becomes free again.
  perform test.as_superuser();
  stale := test.new_user('stale_70'); fresh := test.new_user('fresh_70'); confirmed := test.new_user('conf_70');
  update auth.users set email_confirmed_at = null where id in (stale, fresh);
  update auth.users set created_at = now() - interval '3 days' where id in (stale, confirmed);
  perform test.ok(private.purge_unconfirmed_signups() = 1, 'one stale signup purged');
  perform test.ok(not exists (select 1 from public.profiles where id = stale), 'stale profile gone');
  perform test.ok(exists (select 1 from public.profiles where id = fresh), 'fresh signup kept');
  perform test.ok(exists (select 1 from public.profiles where id = confirmed), 'confirmed kept');
  perform test.ok(test.new_user('stale_70') is not null, 'username reusable after purge');
  perform test.as_user(a);
  perform test.throws('select private.purge_unconfirmed_signups()', 'sqlstate:42501', 'users cannot run purge');
end $$;

-- App error reports (0029): rate-limited, truncated, owner-only, kept 14 days.
do $$
declare u uuid; o uuid; i integer;
begin
  perform test.as_superuser();
  u := test.new_user('err_u_70'); o := test.new_user('err_o_70');
  perform test.as_user(u);
  perform public.report_client_error(repeat('x', 1000), repeat('s', 5000), '/chats/abc?secret=1', 'UA', 'v1');
  perform test.as_superuser();
  perform test.ok((select char_length(message) = 300 and char_length(stack) = 2000 and path = '/chats/abc'
                   from private.client_errors where user_id = u), 'truncated, query string dropped');
  insert into private.client_errors (user_id, message, created_at) values (u, 'old', now() - interval '20 days');
  perform test.as_user(u);
  for i in 1..19 loop perform public.report_client_error('e' || i, null, '/', null, null); end loop;
  perform test.throws($q$select public.report_client_error('one too many', null, '/', null, null)$q$, 'rate_limited', 'rate-limited');
  perform test.as_superuser();
  perform test.ok(not exists (select 1 from private.client_errors where message = 'old'), 'older than 14 days removed');
  perform test.as_user(u);
  perform test.throws('select * from public.admin_client_errors()', 'forbidden', 'only the owner reads them');
  perform test.as_superuser();
  update private.platform_config set owner_user_id = o;
  perform test.as_user(o, '{"aal":"aal2"}');
  perform test.ok((select count(*) from public.admin_client_errors(100) where username = 'err_u_70') = 20, 'owner sees them');
  perform test.as_superuser();
  update private.platform_config set owner_user_id = null;
end $$;
