-- Regression tests for the second review round (migration 0017).

-- Storage: deleting does not free quota or pool bytes until the janitor removed the object.
do $$
declare u uuid; a1 uuid; pool_before bigint; pool_after bigint;
begin
  u := test.new_user('churn_76');
  a1 := test.upload(u, 'chat', 'image/jpeg', 1000);
  select bytes_used into pool_before from private.storage_pools where pool = 'ephemeral';
  update private.platform_config set ephemeral_user_quota_bytes = 1500;
  perform test.as_user(u);
  perform public.delete_media_asset(a1);
  perform test.throws($q$select public.authorize_upload('chat', 'image/jpeg', 1000, repeat('6', 64))$q$,
                      'media_quota_full', 'deleted-but-not-removed bytes still count for the user');
  perform test.as_superuser();
  perform test.ok((select bytes_used from private.storage_pools where pool = 'ephemeral') = pool_before,
                  'pool bytes kept until removal');
  perform set_config('role', 'service_role', false);
  perform public.janitor_mark_deleted(array[a1]);
  perform test.as_superuser();
  select bytes_used into pool_after from private.storage_pools where pool = 'ephemeral';
  perform test.ok(pool_after = pool_before - 1000, 'janitor releases the bytes');
  perform test.as_user(u);
  perform test.ok((select asset_id from public.authorize_upload('chat', 'image/jpeg', 1000, repeat('6', 64))) is not null,
                  'quota free again after removal');
  perform test.as_superuser();
  update private.platform_config set ephemeral_user_quota_bytes = 52428800;
  perform test.ok((select count(*) from pg_proc where proname = 'process_account_deletions') = 1, 'no leftover overload');
  perform private.process_account_deletions();   -- unambiguous again
end $$;

-- Mode-change notices are limited and stop at the database guard; Snap sends are de-duplicated.
do $$
declare a uuid; b uuid; conv uuid; img uuid; snap uuid; i integer;
begin
  a := test.new_user('mode_a_76'); b := test.new_user('mode_b_76');
  perform test.befriend(a, b);
  perform test.as_user(a);
  conv := public.create_direct_conversation(b);
  perform test.as_superuser();
  insert into private.platform_usage (id, db_bytes, measured_at) values (true, 499000000, now())
  on conflict (id) do update set db_bytes = excluded.db_bytes, measured_at = excluded.measured_at;
  perform test.as_user(a);
  perform test.throws(format($q$select public.set_chat_expiry(%L, 'never')$q$, conv), 'storage_full',
                      'mode-change notice stops at the database guard');
  perform test.as_superuser();
  perform private.refresh_db_usage();
  perform test.as_user(a);
  for i in 1..30 loop
    perform public.set_chat_expiry(conv, case when i % 2 = 1 then 'never' else 'after_view' end::public.expiry_mode);
    if i % 10 = 0 then perform test.as_superuser(); delete from private.rate_limits where user_id = a and action = 'set_chat_expiry'; perform test.as_user(a); end if;
  end loop;
  perform test.throws(format($q$select public.set_chat_expiry(%L, 'after_view_7d')$q$, conv), 'rate_limited',
                      'at most 30 mode changes a day');

  img := test.upload(a, 'snap', 'image/jpeg', 1500);
  perform test.as_user(a);
  snap := public.send_snap(img, array[b, b, b], null, 3::smallint, false, gen_random_uuid());
  perform test.ok((select count(*) from public.messages where snap_id = snap) = 1, 'repeated recipient: one message');
  perform test.ok((select sender_id from public.snap_recipients where snap_id = snap) = a, 'recipient rows carry the sender');

  -- The egress share is checked before a view is used up.
  perform test.as_superuser();
  update private.platform_config set daily_egress_user_bytes = 1000;
  perform test.as_user(b);
  perform test.throws(format('select * from public.open_snap(%L)', snap), 'egress_quota_exceeded', 'refused before using a view');
  perform test.ok((select views_used from public.snap_recipients where snap_id = snap and recipient_id = b) = 0, 'view not used');
  perform test.as_superuser();
  update private.platform_config set daily_egress_user_bytes = 67108864;
end $$;

-- Groups: receipts, saves, blocks and removed members.
do $$
declare a uuid; b uuid; c uuid; g uuid; m1 uuid; m2 uuid; m3 uuid; img uuid; snap uuid;
begin
  a := test.new_user('grp_a_76'); b := test.new_user('grp_b_76'); c := test.new_user('grp_c_76');
  perform test.befriend(a, b); perform test.befriend(a, c);
  perform test.as_user(a);
  g := public.create_group('round two', array[b, c]);

  -- An ex-member no longer sees receipts for their old messages.
  perform test.as_user(c);
  m1 := public.send_message(g, 'text', 'from c', gen_random_uuid());
  perform test.as_user(b);
  perform public.mark_conversation_read(g);
  perform test.as_user(c);
  perform test.ok((select count(*) from public.message_reads where message_id = m1) = 1, 'member sees receipts');
  perform public.leave_group(g);
  perform test.ok((select count(*) from public.message_reads where message_id = m1) = 0, 'ex-member sees none');

  -- Saves are private in search and in the gallery.
  perform test.as_user(a);
  perform public.add_group_members(g, array[c]);
  perform public.set_chat_expiry(g, 'never');
  m2 := public.send_message(g, 'text', 'save me', gen_random_uuid());
  perform test.as_user(b);
  perform public.set_message_saved(m2, true);
  perform test.ok((select count(*) from public.search_messages(null, null, null, null, true, null, g)) = 1, 'my saves listed');
  perform test.as_user(a);
  perform test.ok((select count(*) from public.search_messages(null, null, null, null, true, null, g)) = 0, 'others'' saves not');
  perform test.ok((select not saved from public.search_messages('save me', null, null, null, false, null, g)), 'saved flag is mine');

  -- A block between two members does not hold back expiry; blocking settles waiting messages.
  perform public.set_chat_expiry(g, 'after_view');
  perform test.as_user(b);
  m3 := public.send_message(g, 'text', 'disappear please', gen_random_uuid());
  perform test.as_user(a);
  perform public.mark_conversation_read(g);
  perform test.as_superuser();
  perform test.ok((select expires_at is null from public.messages where id = m3), 'waiting for c');
  perform test.as_user(c);
  perform public.block_user(b);
  perform test.as_superuser();
  perform test.ok((select expires_at is not null from public.messages where id = m3), 'block settles the wait');

  -- Removed members lose the group's Snaps.
  img := test.upload(a, 'snap', 'image/jpeg', 1200);
  perform test.as_user(a);
  snap := public.send_snap(img, null, array[g], 5::smallint, false, gen_random_uuid());
  perform public.remove_group_member(g, c);
  perform test.as_user(c);
  perform test.throws(format('select * from public.open_snap(%L)', snap), 'snap_not_found', 'removed member cannot open');
  perform test.as_superuser();
  perform test.ok((select status from public.snap_recipients where snap_id = snap and recipient_id = c) = 'expired',
                  'their recipient row expired');
end $$;

-- Deleting an owner whose remaining members are suspended still hands the group over.
do $$
declare o uuid; s uuid; boss uuid; g uuid;
begin
  o := test.new_user('own_76'); s := test.new_user('susp_76'); boss := test.new_user('boss_76');
  perform test.befriend(o, s);
  perform test.as_user(o);
  g := public.create_group('heirs', array[s]);
  perform test.as_superuser();
  update public.profiles set account_state = 'suspended' where id = s;
  perform test.as_user(o, jsonb_build_object('amr', jsonb_build_array(
    jsonb_build_object('method', 'password', 'timestamp', extract(epoch from now())::bigint))));
  perform public.request_account_deletion();
  perform test.as_superuser();
  perform private.run_maintenance();
  perform test.ok((select role from public.conversation_members where conversation_id = g and user_id = s) = 'owner',
                  'suspended member inherits rather than leaving the group ownerless');
end $$;

-- A Snap view counts only once its bytes were served (0018).
do $$
declare a uuid; b uuid; img uuid; snap uuid; s uuid; st public.snap_status;
begin
  a := test.new_user('refund_a_76'); b := test.new_user('refund_b_76');
  perform test.befriend(a, b);
  img := test.upload(a, 'snap', 'image/jpeg', 1300);
  perform test.as_user(a);
  snap := public.send_snap(img, array[b], null, 3::smallint, false, gen_random_uuid());
  perform test.as_user(b);
  select session_id into s from public.open_snap(snap);
  st := public.close_snap_view(snap, s);              -- nothing fetched
  perform test.ok(st = 'delivered', 'unserved view given back');
  perform test.ok((select views_used from public.snap_recipients where snap_id = snap and recipient_id = b) = 0, 'views_used restored');
  perform test.as_superuser();
  perform test.as_user(b);
  select session_id into s from public.open_snap(snap);
  perform public.authorize_snap_media(snap, s);         -- bytes released
  st := public.close_snap_view(snap, s);
  perform test.ok(st = 'opened' and (select views_used from public.snap_recipients where snap_id = snap and recipient_id = b) = 1,
                  'served view counts');
  perform test.as_superuser();
end $$;
