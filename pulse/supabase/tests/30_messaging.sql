-- Messaging: access control, idempotency, labels, edit window, deletion, expiry,
-- saving, reactions, pins, groups, search.
do $$
declare a uuid; b uuid; x uuid; conv uuid; m1 uuid; cid uuid := gen_random_uuid();
begin
  a := test.new_user('amy_30'); b := test.new_user('bo_30'); x := test.new_user('xeno_30');
  perform test.as_user(a);
  perform test.throws(format('select public.create_direct_conversation(%L)', b), 'not_friends', 'chat requires friendship');
  perform test.befriend(a, b);
  perform test.as_user(a);
  conv := public.create_direct_conversation(b);
  perform test.ok(public.create_direct_conversation(b) = conv, 'direct conversation is unique per pair');

  m1 := public.send_message(conv, 'text', 'hello bo', cid);
  perform test.ok(public.send_message(conv, 'text', 'hello bo', cid) = m1, 'retry with same client id is idempotent');
  perform test.ok((select count(*) from public.messages where conversation_id = conv) = 1, 'no duplicate row');

  -- Chat list shows labels, never bodies.
  perform test.ok((select label from public.chat_list() where conversation_id = conv) = 'Delivered', 'sender sees Delivered');
  perform test.ok(pg_get_function_result('public.chat_list()'::regprocedure) !~ 'body', 'chat_list has no body column');
  perform test.as_user(b);
  perform test.ok((select label from public.chat_list() where conversation_id = conv) = 'New Chat', 'recipient sees New Chat');
  perform test.ok((select unread from public.chat_list() where conversation_id = conv), 'unread flag');

  -- Outsiders get nothing.
  perform test.as_user(x);
  perform test.ok((select count(*) from public.messages where conversation_id = conv) = 0, 'outsider reads nothing');
  perform test.ok((select count(*) from public.conversations where id = conv) = 0, 'outsider sees no conversation');
  perform test.throws(format($q$select public.send_message(%L, 'text', 'hi', gen_random_uuid())$q$, conv),
                      'not_a_member', 'outsider cannot send');
  perform test.throws(format($q$insert into public.messages (conversation_id, sender_id, kind, body, client_msg_id) values (%L, %L, 'text', 'x', gen_random_uuid())$q$, conv, x),
                      'sqlstate:42501', 'no direct inserts');

  -- Editing: own message, within 15 minutes.
  perform test.as_user(b);
  perform test.throws(format($q$select public.edit_message(%L, 'hacked')$q$, m1), 'message_not_found', 'cannot edit others');
  perform test.as_user(a);
  perform public.edit_message(m1, 'hello bo!');
  perform test.ok((select edited_at is not null and body = 'hello bo!' from public.messages where id = m1), 'edited indicator');
  perform test.as_superuser();
  update public.messages set created_at = now() - interval '16 minutes' where id = m1;
  perform test.as_user(a);
  perform test.throws(format($q$select public.edit_message(%L, 'late')$q$, m1), 'edit_window_closed', '15 minute cutoff');
  perform test.as_superuser();
end $$;

-- Deletion propagates as a tombstone; reads start expiry; saved messages survive.
do $$
declare a uuid := (select id from public.profiles where username = 'amy_30');
        b uuid := (select id from public.profiles where username = 'bo_30');
        conv uuid; m2 uuid; m3 uuid; m4 uuid;
begin
  perform test.as_user(a);
  conv := public.create_direct_conversation(b);
  m2 := public.send_message(conv, 'text', 'oops', gen_random_uuid());
  perform public.delete_message(m2);
  perform test.as_user(b);
  perform test.ok((select deleted_at is not null and body is null from public.messages where id = m2),
                  'recipient receives content-free tombstone');
  m3 := public.send_message(conv, 'text', 'not yours', gen_random_uuid());
  perform test.as_user(a);
  perform test.throws(format('select public.delete_message(%L)', m3), 'message_not_found', 'cannot delete others'' messages');
  perform test.as_superuser();
  perform test.ok((select deleted_at is null and body = 'not yours' from public.messages where id = m3), 'others'' message untouched');
  delete from public.messages where id = m3;   -- same transaction timestamp: keep the chat-list checks below unambiguous
  perform test.as_user(a);
  perform test.throws(format('select public.delete_message(%L)', m2), 'message_not_found', 'cannot delete twice');

  -- After-view expiry (default mode).
  perform test.as_user(a);
  m3 := public.send_message(conv, 'text', 'ephemeral', gen_random_uuid());
  m4 := public.send_message(conv, 'text', 'keep me', gen_random_uuid());
  perform test.as_user(b);
  perform public.set_message_saved(m4, true);
  perform public.mark_conversation_read(conv);
  perform test.ok((select expires_at is not null from public.messages where id = m4), 'expiry started on read');
  perform test.ok((select expires_at between now() + interval '4 minutes' and now() + interval '6 minutes'
                   from public.messages where id = m3), 'after_view keeps a short grace (save/reply/report)');
  perform test.as_superuser();
  update public.messages set expires_at = now() - interval '1 second' where id in (m3, m4);
  perform test.as_user(b);
  perform test.ok((select count(*) from public.messages where id = m3) = 0, 'viewed message gone for recipient');
  perform test.ok((select count(*) from public.messages where id = m4) = 1, 'saved message remains');
  perform test.ok((select count(*) from public.search_messages('ephemeral')) = 0, 'expired message not searchable');
  perform test.ok((select count(*) from public.search_messages('keep')) = 1, 'saved message searchable');
  perform test.as_user(a);
  perform test.ok((select label from public.chat_list() where conversation_id = conv) = 'Opened', 'sender sees Opened');

  -- Reactions expire with their parent.
  perform test.as_user(b);
  perform test.ok(public.toggle_reaction(m4, '🔥'), 'reaction added');
  perform test.ok(not public.toggle_reaction(m4, '🔥'), 'reaction removed');
  perform public.toggle_reaction(m4, '🔥');
  perform test.throws(format($q$select public.toggle_reaction(%L, 'abc')$q$, m4), 'sqlstate:23514', 'emoji only');
  perform public.set_message_saved(m4, false);
  perform test.ok((select count(*) from public.message_reactions where message_id = m4) = 0,
                  'reaction hidden once parent expired');

  -- 24-hour mode.
  perform public.set_chat_expiry(conv, 'after_view_24h');
  perform test.as_user(a);
  m3 := public.send_message(conv, 'text', 'day long', gen_random_uuid());
  perform test.as_user(b);
  perform public.mark_conversation_read(conv);
  perform test.ok((select expires_at between now() + interval '23 hours' and now() + interval '25 hours'
                   from public.messages where id = m3), '24h after viewing');

  -- Maintenance purges expired, unsaved messages.
  perform test.as_superuser();
  update public.messages set expires_at = now() - interval '1 second' where id = m3;
  perform private.run_maintenance();
  perform test.ok(exists (select 1 from public.messages where id = m3), 'kept (invisible) during the report window');
  update public.messages set expires_at = now() - interval '2 hours' where id = m3;
  perform test.ok(jsonb_array_length(private.run_maintenance() -> 'errors') = 0, 'maintenance ran without errors');
  perform test.ok(not exists (select 1 from public.messages where id = m3), 'expired message purged');
end $$;

-- Replies, pins, mute.
do $$
declare a uuid := (select id from public.profiles where username = 'amy_30');
        b uuid := (select id from public.profiles where username = 'bo_30');
        f uuid; conv uuid; parent uuid; reply uuid; i integer; convs uuid[] := '{}';
begin
  perform test.as_user(a);
  conv := public.create_direct_conversation(b);
  perform public.set_chat_expiry(conv, 'never');
  parent := public.send_message(conv, 'text', 'parent', gen_random_uuid());
  reply := public.send_message(conv, 'text', 'child', gen_random_uuid(), null, parent);
  perform test.ok((select reply_to_id from public.messages where id = reply) = parent, 'quoted reply');

  for i in 1..3 loop
    perform test.as_superuser();
    f := test.new_user('pinpal' || i || '_30');
    perform test.befriend(a, f);
    perform test.as_user(a);
    convs := convs || public.create_direct_conversation(f);
  end loop;
  perform public.set_pin(convs[1], 1::smallint);
  perform public.set_pin(convs[2], 2::smallint);
  perform public.set_pin(convs[3], 3::smallint);
  perform test.throws(format('select public.set_pin(%L, 4::smallint)', conv), 'max_three_pins', 'max three pins');
  perform public.set_pin(conv, 1::smallint);   -- takes rank 1; previous rank-1 is unpinned
  perform test.ok((select count(*) from public.conversation_members where user_id = a and pinned_rank is not null) = 3,
                  'still three pins');
  perform test.ok((select pinned_rank from public.chat_list() limit 1) = 1, 'pinned first in list');
  perform test.as_user(b);
  perform test.ok((select pinned_rank from public.conversation_members where conversation_id = conv and user_id = b) is null,
                  'pins are personal');
  perform test.as_superuser();
end $$;

-- Groups: membership, roles, ownership, history visibility.
do $$
declare o uuid; ad uuid; m uuid; late uuid; stranger uuid; g uuid; early uuid;
begin
  o := test.new_user('gowner_30'); ad := test.new_user('gadmin_30'); m := test.new_user('gmember_30');
  late := test.new_user('glate_30'); stranger := test.new_user('gstranger_30');
  perform test.befriend(o, ad); perform test.befriend(o, m); perform test.befriend(o, late);
  perform test.as_user(o);
  perform test.throws(format('select public.create_group(%L, array[%L]::uuid[])', 'G', stranger), 'not_friends',
                      'only friends can be added');
  g := public.create_group('Crew', array[ad, m]);
  perform public.set_group_role(g, ad, 'admin');
  early := public.send_message(g, 'text', 'before late joined', gen_random_uuid());
  perform test.as_superuser();   -- whole block is one transaction: backdate so "earlier" is real
  update public.messages set created_at = now() - interval '1 minute' where id = early;

  perform test.as_user(m);
  perform test.throws(format('select public.add_group_members(%L, array[%L]::uuid[])', g, late), 'not_allowed',
                      'members cannot add');
  perform test.ok((select count(*) from public.conversation_participants(g)) = 3, 'participants listed');

  perform test.as_user(ad);
  perform test.throws(format('select public.remove_group_member(%L, %L)', g, o), 'not_allowed', 'admin cannot remove owner');
  perform test.throws(format('select public.set_group_role(%L, %L, %L)', g, m, 'admin'), 'not_allowed',
                      'admin cannot appoint admins');
  perform test.throws(format('select public.transfer_group_ownership(%L, %L)', g, ad), 'not_allowed',
                      'admin cannot take ownership');

  perform test.as_user(o);
  perform public.add_group_members(g, array[late]);
  perform test.as_user(late);
  perform test.ok((select count(*) from public.messages where id = early) = 0, 'late joiner cannot read earlier history');

  perform test.as_user(ad);
  perform public.remove_group_member(g, m);
  perform test.as_user(m);
  perform test.ok((select count(*) from public.messages where conversation_id = g) = 0, 'removed member loses access');
  perform test.throws(format($q$select public.send_message(%L, 'text', 'hi', gen_random_uuid())$q$, g), 'not_a_member',
                      'removed member cannot send');

  perform test.as_user(o);
  perform test.throws(format('select public.leave_group(%L)', g), 'transfer_ownership_first', 'owner must transfer first');
  perform public.transfer_group_ownership(g, ad);
  perform public.leave_group(g);
  perform test.as_user(ad);
  perform test.ok((select role from public.conversation_participants(g) where user_id = ad) = 'owner', 'ownership transferred');
  perform test.as_superuser();
end $$;
