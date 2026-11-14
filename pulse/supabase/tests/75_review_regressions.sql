-- Regression tests for the fixes from the multi-agent review (migrations 0014-0015).

-- Text abuse: edit caps, no-op edits, daily text quota, database-size guard, solo groups.
do $$
declare a uuid; b uuid; conv uuid; m uuid; i integer;
begin
  a := test.new_user('edit_a_75'); b := test.new_user('edit_b_75');
  perform test.befriend(a, b);
  perform test.as_user(a);
  conv := public.create_direct_conversation(b);
  perform public.set_chat_expiry(conv, 'never');
  m := public.send_message(conv, 'text', 'v0', gen_random_uuid());
  perform public.edit_message(m, 'v0');   -- no-op: not counted, nothing stored
  perform test.as_superuser();
  perform test.ok((select count(*) from private.message_edits where message_id = m) = 0, 'no-op edit stores nothing');
  perform test.as_user(a);
  for i in 1..5 loop perform public.edit_message(m, 'v' || i); end loop;
  perform test.throws(format($q$select public.edit_message(%L, 'v6')$q$, m), 'edit_limit_reached', 'edits per message capped');
  perform test.as_superuser();
  perform test.ok((select count(*) from private.message_edits where message_id = m) = 5, 'edit history bounded');

  update private.platform_config set daily_text_bytes_per_user = 10;
  perform test.as_user(a);
  perform test.throws(format($q$select public.send_message(%L, 'text', 'this is more than ten bytes', gen_random_uuid())$q$, conv),
                      'text_quota_exceeded', 'daily text quota per user');
  perform test.as_superuser();
  update private.platform_config set daily_text_bytes_per_user = 2097152;

  insert into private.platform_usage (id, db_bytes, measured_at) values (true, 499000000, now())
  on conflict (id) do update set db_bytes = excluded.db_bytes, measured_at = excluded.measured_at;
  perform test.as_user(a);
  perform test.throws(format($q$select public.send_message(%L, 'text', 'hi', gen_random_uuid())$q$, conv),
                      'storage_full', 'writes refused above 90% of the database budget');
  perform test.as_superuser();
  perform private.refresh_db_usage();
  perform test.as_user(a);
  perform test.ok(public.send_message(conv, 'text', 'hi', gen_random_uuid()) is not null, 'writes resume');
  perform test.throws(format('select public.create_group(%L, array[%L]::uuid[])', 'solo', a), 'group_needs_members',
                      'no one-person groups');
  perform test.as_superuser();
end $$;

-- Blocking someone you already chat with closes that chat, its topic and its Snaps.
do $$
declare a uuid; b uuid; conv uuid; m uuid; img uuid; snap uuid;
begin
  a := test.new_user('blk_a_75'); b := test.new_user('blk_b_75');
  perform test.befriend(a, b);
  img := test.upload(a, 'snap', 'image/jpeg', 2000);
  perform test.as_user(a);
  conv := public.create_direct_conversation(b);
  m := public.send_message(conv, 'text', 'before the block', gen_random_uuid());
  snap := public.send_snap(img, array[b], null, 5::smallint, false, gen_random_uuid());
  perform test.as_user(b);
  perform public.block_user(a);
  -- The blocked person:
  perform test.as_user(a);
  perform test.throws(format($q$select public.send_message(%L, 'text', 'x', gen_random_uuid())$q$, conv),
                      'not_a_member', 'blocked: cannot send (looks like no chat)');
  perform test.ok((select count(*) from public.messages where conversation_id = conv) = 0, 'blocked: history hidden');
  perform test.ok((select count(*) from public.conversations where id = conv) = 0, 'blocked: chat hidden');
  perform test.ok(not private.can_use_topic('conv:' || conv), 'blocked: realtime topic refused');
  perform test.throws(format('select * from public.conversation_participants(%L)', conv), 'not_a_member',
                      'blocked: no roster (no new-handle leak)');
  perform test.throws(format($q$select public.set_chat_expiry(%L, 'never')$q$, conv), 'not_a_member',
                      'blocked: cannot change chat settings');
  perform test.throws(format('select public.mark_conversation_read(%L)', conv), 'not_a_member', 'blocked: no read receipts');
  -- The blocker:
  perform test.as_user(b);
  perform test.ok((select count(*) from public.messages where conversation_id = conv) = 0, 'blocker: history hidden');
  perform test.throws(format('select * from public.open_snap(%L)', snap), 'snap_not_found', 'blocker: Snap closed');
  perform test.ok(not private.can_use_topic('conv:' || conv), 'blocker: topic refused');
  perform test.as_superuser();
end $$;

-- Ending a friendship makes the direct chat read-only.
do $$
declare a uuid; b uuid; conv uuid;
begin
  a := test.new_user('exf_a_75'); b := test.new_user('exf_b_75');
  perform test.befriend(a, b);
  perform test.as_user(a);
  conv := public.create_direct_conversation(b);
  perform public.set_chat_expiry(conv, 'never');
  perform public.send_message(conv, 'text', 'hello', gen_random_uuid());
  perform public.remove_friend(b);
  perform test.as_user(b);
  perform test.throws(format($q$select public.send_message(%L, 'text', 'x', gen_random_uuid())$q$, conv),
                      'not_friends', 'ex-friend cannot keep messaging');
  perform test.ok((select count(*) from public.messages where conversation_id = conv and kind = 'text') = 1,
                  'history stays readable');
  perform test.ok(not private.can_use_topic('conv:' || conv), 'no typing channel with an ex-friend');
  perform test.as_superuser();
end $$;

-- Co-member privacy, group blocks, per-message expiry mode, leave re-evaluation.
do $$
declare a uuid; b uuid; c uuid; g uuid; m1 uuid; m2 uuid; m3 uuid;
begin
  a := test.new_user('grp_a_75'); b := test.new_user('grp_b_75'); c := test.new_user('grp_c_75');
  perform test.befriend(a, b); perform test.befriend(a, c);
  perform test.as_user(a);
  g := public.create_group('crew', array[b, c]);
  m1 := public.send_message(g, 'text', 'disappearing', gen_random_uuid());
  perform public.set_chat_expiry(g, 'never');          -- applies to later messages only
  perform test.ok(exists (select 1 from public.messages where conversation_id = g and kind = 'system'
                          and body = 'expiry_mode:never'), 'mode change announced in the chat');
  m2 := public.send_message(g, 'text', 'kept', gen_random_uuid());

  perform test.as_user(b);
  perform public.mark_conversation_read(g);
  perform public.set_message_saved(m2, true);
  perform test.ok((select count(*) from public.conversation_members where conversation_id = g) = 1,
                  'members see only their own member row');
  perform test.ok((select count(*) from public.message_reads where user_id <> b) = 0, 'no one else''s read times');
  perform test.as_user(a);
  perform test.ok((select count(*) from public.message_reads where message_id = m1 and user_id = b) = 1,
                  'sender sees who read their message');
  perform test.ok((select count(*) from public.saved_messages) = 0, 'saves are private');
  perform test.as_user(c);
  perform test.ok((select count(*) from public.message_reads where user_id = b) = 0, 'third member sees no receipts');

  -- c has not read m1 yet; when c leaves, m1 (sent in after_view mode) starts expiring.
  perform test.ok((select expires_at is null from public.messages where id = m1), 'still waiting for c');
  perform public.leave_group(g);
  perform test.as_superuser();
  perform test.ok((select expires_at is not null from public.messages where id = m1),
                  'leaving re-evaluates expiry; per-message mode survives the switch to never');
  perform test.ok((select expires_at is null from public.messages where id = m2), 'message sent under never is kept');

  -- A save by someone who leaves no longer pins the message.
  perform test.as_user(b);
  perform public.leave_group(g);
  perform test.as_superuser();
  perform test.ok(not exists (select 1 from public.saved_messages where message_id = m2), 'leaver''s saves removed');

  -- Group blocks hide messages both ways.
  perform test.as_user(a);
  perform public.add_group_members(g, array[c]);
  m3 := public.send_message(g, 'text', 'from a', gen_random_uuid());
  perform test.as_user(c);
  perform public.block_user(a);
  perform test.ok((select count(*) from public.messages where id = m3) = 0, 'blocker does not see blocked member''s messages');
  perform test.ok(not exists (select 1 from public.conversation_participants(g) where user_id = a),
                  'blocked member left out of the roster');
  perform test.as_superuser();
end $$;

-- Reads only cover what was rendered; reports still work after after_view expiry.
do $$
declare a uuid; b uuid; conv uuid; m1 uuid; m2 uuid; cut timestamptz;
begin
  a := test.new_user('rd_a_75'); b := test.new_user('rd_b_75');
  perform test.befriend(a, b);
  perform test.as_user(a);
  conv := public.create_direct_conversation(b);
  m1 := public.send_message(conv, 'text', 'one', gen_random_uuid());
  perform test.as_superuser();
  update public.messages set created_at = now() - interval '1 minute' where id = m1;
  update public.conversation_members set joined_at = now() - interval '5 minutes' where conversation_id = conv;
  cut := now() - interval '30 seconds';
  perform test.as_user(a);
  m2 := public.send_message(conv, 'text', 'two', gen_random_uuid());
  perform test.as_user(b);
  perform public.mark_conversation_read(conv, cut);
  perform test.ok(exists (select 1 from public.message_reads where message_id = m1 and user_id = b), 'rendered message read');
  perform test.ok(not exists (select 1 from public.message_reads where message_id = m2 and user_id = b),
                  'unrendered message not marked read');
  perform test.ok(public.mark_conversation_read(conv, cut) = 0, 'nothing new: no writes');

  perform test.as_superuser();
  update public.messages set expires_at = now() - interval '1 minute' where id = m1;
  perform test.as_user(b);
  perform test.ok(public.report_message(m1, 'harassment') is not null, 'read message reportable after it disappeared');
  perform test.as_user(a);
  perform test.throws(format($q$select public.report_message(%L, 'spam')$q$, m2), 'message_not_found',
                      'cannot report your own message');
  perform test.as_user(b);
  perform test.throws($q$select evidence from public.reports$q$, 'sqlstate:42501', 'reporter cannot read evidence');
  perform test.as_superuser();
end $$;

-- Snaps: unsending, deduplicated media, one reaction per person.
do $$
declare a uuid; b uuid; conv uuid; img uuid; snap uuid; snap_msg uuid; pic uuid; m1 uuid; m2 uuid; t uuid;
begin
  a := test.new_user('snp_a_75'); b := test.new_user('snp_b_75');
  perform test.befriend(a, b);
  img := test.upload(a, 'snap', 'image/jpeg', 2000);
  pic := test.upload(a, 'chat', 'image/jpeg', 3000);
  perform test.as_user(a);
  snap := public.send_snap(img, array[b], null, 5::smallint, false, gen_random_uuid());
  conv := public.create_direct_conversation(b);
  select id into snap_msg from public.messages where snap_id = snap;
  perform public.delete_message(snap_msg);
  perform test.as_user(b);
  perform test.throws(format('select * from public.open_snap(%L)', snap), 'snap_expired', 'deleted Snap message unsends the Snap');
  perform test.as_superuser();
  perform test.ok((select status from public.media_assets where id = img) = 'deleting', 'unsent Snap media released');

  perform test.as_user(a);
  perform public.set_chat_expiry(conv, 'never');
  m1 := public.send_message(conv, 'photo', null, gen_random_uuid(), pic);
  m2 := public.send_message(conv, 'photo', null, gen_random_uuid(), pic);   -- same asset (dedupe)
  perform public.delete_message(m1);
  perform test.as_superuser();
  perform test.ok((select status from public.media_assets where id = pic) = 'uploaded', 'shared media kept while still used');
  perform test.as_user(a);
  perform public.delete_message(m2);
  perform test.as_superuser();
  perform test.ok((select status from public.media_assets where id = pic) = 'deleting', 'released when unused');

  perform test.as_user(a);
  t := public.send_message(conv, 'text', 'react', gen_random_uuid());
  perform test.as_user(b);
  perform public.toggle_reaction(t, '🔥');
  perform public.toggle_reaction(t, '👍');
  perform test.ok((select count(*) from public.message_reactions where message_id = t and user_id = b) = 1,
                  'one reaction per person per message');
  perform test.ok((select emoji from public.message_reactions where message_id = t and user_id = b) = '👍', 'replaced');
  perform test.as_superuser();
end $$;

-- Account state: banned users lose table, Storage and topic access at once; the owner
-- cannot "restore" an account being deleted; moderation state is private.
do $$
declare o uuid; u uuid; f uuid; conv uuid; fac uuid;
begin
  o := test.new_user('own_75'); u := test.new_user('ban_75'); f := test.new_user('pal_75');
  update private.platform_config set owner_user_id = o;
  perform test.befriend(u, f);
  perform test.as_user(u);
  conv := public.create_direct_conversation(f);
  perform public.send_message(conv, 'text', 'hi', gen_random_uuid());

  perform test.as_user(f);
  perform test.throws(format('select account_state from public.profiles where id = %L', u), 'sqlstate:42501',
                      'friends cannot read moderation state');
  perform test.ok((select account_state from public.my_profile()) = 'active', 'own state via my_profile');

  perform test.as_user(o);
  perform public.admin_set_account_state(u, 'suspended', 'test');
  perform test.as_user(u);   -- JWT still valid for up to an hour
  perform test.ok((select count(*) from public.messages) = 0, 'suspended: messages hidden immediately');
  perform test.ok((select count(*) from public.conversations) = 0, 'suspended: chats hidden immediately');
  perform test.ok(not private.can_use_topic('conv:' || conv), 'suspended: topic refused');
  perform test.ok((select account_state from public.my_profile()) = 'suspended', 'suspended user can still see why');

  perform test.as_superuser();
  update public.profiles set account_state = 'deleting' where id = u;
  perform test.as_user(o);
  perform test.throws(format($q$select public.admin_set_account_state(%L, 'active', 'oops')$q$, u), 'account_deleting',
                      'cannot restore an account being deleted');

  -- am_i_owner does not reveal the owner to a password-only session of a 2FA account.
  perform test.as_superuser();
  insert into auth.mfa_factors (id, user_id, factor_type, status, created_at, updated_at)
  values (gen_random_uuid(), o, 'totp', 'verified', now(), now()) returning id into fac;
  perform test.as_user(o, '{"aal":"aal1"}');
  perform test.ok(not public.am_i_owner(), 'owner hidden at aal1');
  perform test.throws($q$select public.admin_usage_summary()$q$, 'mfa_required', 'admin needs aal2');
  perform test.as_user(o, '{"aal":"aal2"}');
  perform test.ok(public.am_i_owner(), 'owner at aal2');
  perform test.as_superuser();
  delete from auth.mfa_factors where id = fac;
  update private.platform_config set owner_user_id = null;
end $$;

-- Re-authentication for deletion needs a recent password sign-in, not a TOTP step.
do $$
declare d uuid; nowe bigint := extract(epoch from now())::bigint;
begin
  d := test.new_user('reauth_75');
  perform test.as_user(d, jsonb_build_object('amr', jsonb_build_array(
    jsonb_build_object('method', 'password', 'timestamp', nowe - 3600),
    jsonb_build_object('method', 'totp', 'timestamp', nowe))));
  perform test.throws($q$select public.request_account_deletion()$q$, 'reauthentication_required',
                      'fresh TOTP + stale password refused');
  perform test.as_user(d, jsonb_build_object('amr', jsonb_build_array(
    jsonb_build_object('method', 'password', 'timestamp', nowe - 660))));
  perform test.throws($q$select public.request_account_deletion()$q$, 'reauthentication_required', '11 minutes is too old');
  perform test.as_user(d, jsonb_build_object('amr', jsonb_build_array(
    jsonb_build_object('method', 'password', 'timestamp', nowe - 540))));
  perform public.request_account_deletion();
  perform public.request_account_deletion();   -- idempotent
  perform test.as_superuser();
  perform test.ok((select count(*) from private.audit_log where target_user_id = d
                   and action = 'account.deletion_requested') = 1, 'requested once');
end $$;

-- Reporting a stranger snapshots only the minimal card.
do $$
declare a uuid; s uuid; r uuid;
begin
  a := test.new_user('rep_a_75'); s := test.new_user('rep_s_75');
  update public.profiles set bio = 'friends only' where id = s;
  perform test.as_user(a);
  r := public.report_user(s, 'spam');
  perform test.as_superuser();
  perform test.ok(not (select evidence ? 'bio' from public.reports where id = r), 'no friends-only bio in evidence');
end $$;

-- Signups: unconfirmed accounts are not searchable; purge keys on the latest email.
do $$
declare a uuid; u uuid; k uuid;
begin
  a := test.new_user('srch_a_75'); u := test.new_user('ghost_75'); k := test.new_user('keep_75');
  perform test.new_user('findme_75');
  update auth.users set email_confirmed_at = null where id in (u, k);
  update auth.users set created_at = now() - interval '3 days', confirmation_sent_at = now() where id = k;
  perform test.as_user(a);
  perform test.ok((select count(*) from public.search_users('ghost_75')) = 0, 'unconfirmed signup not searchable');
  perform test.ok((select count(*) from public.search_users('@findme')) = 1, '@username search works');
  perform test.throws(format('select public.send_friend_request(%L)', u), 'user_not_found', 'no requests to unconfirmed');
  perform test.as_superuser();
  perform private.purge_unconfirmed_signups();
  perform test.ok(exists (select 1 from auth.users where id = k), 'fresh confirmation email keeps the account');
end $$;

-- Uploads: outstanding reservations and per-user pool shares are capped; egress is
-- shared fairly and not charged twice for a quick re-fetch.
do $$
declare u uuid; v uuid; i integer; img uuid; conv uuid;
begin
  u := test.new_user('upl_u_75'); v := test.new_user('upl_v_75');
  perform test.as_user(u);
  for i in 1..5 loop
    perform public.authorize_upload('chat', 'image/jpeg', 1000, encode(extensions.digest(i::text || 'x75', 'sha256'), 'hex'));
  end loop;
  perform test.throws($q$select public.authorize_upload('chat', 'image/jpeg', 1000, repeat('9', 64))$q$,
                      'too_many_pending_uploads', 'pending reservations capped');
  perform test.as_superuser();
  delete from public.media_assets where owner_id = u and status = 'pending';
  update private.platform_config set ephemeral_user_quota_bytes = 1500;
  perform test.as_user(u);
  perform public.authorize_upload('chat', 'image/jpeg', 1000, repeat('8', 64));
  perform test.throws($q$select public.authorize_upload('chat', 'image/jpeg', 1000, repeat('7', 64))$q$,
                      'media_quota_full', 'per-user share of the ephemeral pool');
  perform test.as_superuser();
  update private.platform_config set ephemeral_user_quota_bytes = 52428800;
  delete from public.media_assets where owner_id = u and status = 'pending';

  perform test.befriend(u, v);
  img := test.upload(u, 'chat', 'image/jpeg', 4000);
  perform test.as_user(u);
  conv := public.create_direct_conversation(v);
  perform public.send_message(conv, 'photo', null, gen_random_uuid(), img);
  perform test.as_superuser();
  update private.platform_config set daily_egress_user_bytes = 5000;
  perform test.as_user(v);
  perform public.authorize_media_access(img);
  perform public.authorize_media_access(img);   -- re-fetch: not charged again
  perform test.as_superuser();
  perform test.ok((select egress_bytes from private.usage_daily where user_id = v) = 4000, 'charged once');
  delete from private.egress_recent where user_id = v;
  perform test.as_user(v);
  perform test.throws(format('select public.authorize_media_access(%L)', img), 'egress_quota_exceeded',
                      'per-user egress share');
  perform test.as_superuser();
  update private.platform_config set daily_egress_user_bytes = 41943040;
end $$;

-- Maintenance: a failing account deletion does not stop expiry; unattached uploads
-- and empty groups are reclaimed.
do $$
declare a uuid; b uuid; x uuid; conv uuid; m uuid; loose uuid; r jsonb;
begin
  a := test.new_user('mnt_a_75'); b := test.new_user('mnt_b_75'); x := test.new_user('mnt_x_75');
  perform test.befriend(a, b);
  perform test.as_user(a);
  conv := public.create_direct_conversation(b);
  m := public.send_message(conv, 'text', 'bye', gen_random_uuid());
  perform test.as_superuser();
  update public.messages set expires_at = now() - interval '2 hours' where id = m;
  loose := test.upload(a, 'chat', 'image/jpeg', 1200);
  update public.media_assets set uploaded_at = now() - interval '25 hours' where id = loose;

  create function test.boom() returns trigger language plpgsql as $f$
  begin raise exception 'simulated failure'; end $f$;
  execute format('create trigger boom before delete on auth.users for each row when (old.id = %L) execute function test.boom()', x);
  insert into private.deletion_queue (user_id) values (x);

  r := private.run_maintenance();
  perform test.ok(not exists (select 1 from public.messages where id = m), 'expiry ran despite a failing deletion');
  perform test.ok((select attempts = 1 and last_error like '%simulated failure%' from private.deletion_queue where user_id = x),
                  'failure recorded for retry');
  perform test.ok((select status from public.media_assets where id = loose) = 'deleting', 'unattached upload reclaimed');
  drop trigger boom on auth.users;
  drop function test.boom();
  delete from private.deletion_queue where user_id = x;
end $$;

-- Constraints on client-writable columns.
do $$
declare u uuid;
begin
  u := test.new_user('cons_75');
  perform test.as_user(u);
  perform test.throws(format($q$update public.profiles set display_name = E'Ann‎a' where id = %L$q$, u),
                      'sqlstate:23514', 'no invisible/bidi characters in display names');
  perform test.throws(format($q$update public.user_settings set notifications = to_jsonb(repeat('x', 3000)) where user_id = %L$q$, u),
                      'sqlstate:23514', 'notifications must be a small object');
  perform test.as_superuser();
end $$;

-- Realtime broadcast policies on realtime.messages (not just the helper).
do $$
declare a uuid; b uuid; x uuid; conv uuid; msg text;
begin
  a := test.new_user('bc_a_75'); b := test.new_user('bc_b_75'); x := test.new_user('bc_x_75');
  perform test.befriend(a, b);
  perform test.as_user(a);
  conv := public.create_direct_conversation(b);
  perform set_config('realtime.topic', 'conv:' || conv, false);
  perform test.as_user(x);
  perform test.ok((select count(*) from realtime.messages) = 0, 'outsider reads nothing on the topic');
  perform test.throws($q$insert into realtime.messages (topic, extension, payload) values (realtime.topic(), 'broadcast', '{}')$q$,
                      'sqlstate:42501', 'outsider cannot broadcast');
  perform test.as_user(a);
  begin
    insert into realtime.messages (topic, extension, payload) values (realtime.topic(), 'broadcast', '{}');
  exception when others then
    get stacked diagnostics msg = message_text;
    perform test.ok(msg not like '%row-level security%', 'member allowed by the policy (got: ' || msg || ')');
  end;
  perform set_config('realtime.topic', '', false);
  perform test.as_superuser();
end $$;

-- Rate limits on the main write paths (fixed windows; the next call is refused).
do $$
declare a uuid; b uuid; conv uuid; m uuid; i integer; others uuid[] := '{}';
begin
  a := test.new_user('rl_a_75'); b := test.new_user('rl_b_75');
  perform test.befriend(a, b);
  perform test.as_user(a);
  conv := public.create_direct_conversation(b);
  perform public.set_chat_expiry(conv, 'never');
  for i in 1..60 loop perform public.send_message(conv, 'text', 'm' || i, gen_random_uuid()); end loop;
  perform test.throws(format($q$select public.send_message(%L, 'text', 'x', gen_random_uuid())$q$, conv),
                      'rate_limited', 'send_message: 60 per minute');
  perform test.as_superuser();
  delete from private.rate_limits where user_id = a;
  perform test.as_user(a);
  m := public.send_message(conv, 'text', 'edit me', gen_random_uuid());
  perform test.as_superuser();
  update private.platform_config set max_edits_per_message = 100;
  perform test.as_user(a);
  for i in 1..20 loop perform public.edit_message(m, 'e' || i); end loop;
  perform test.throws(format($q$select public.edit_message(%L, 'e21')$q$, m), 'rate_limited', 'edit_message: 20 per minute');
  perform test.as_superuser();
  update private.platform_config set max_edits_per_message = 5;
  perform test.as_user(b);
  for i in 1..60 loop perform public.toggle_reaction(m, '🔥'); end loop;
  perform test.throws(format($q$select public.toggle_reaction(%L, '👍')$q$, m), 'rate_limited', 'toggle_reaction: 60 per minute');
  for i in 1..30 loop perform public.set_mute(conv, null); end loop;
  perform test.throws(format('select public.set_mute(%L, null)', conv), 'rate_limited', 'set_mute: 30 per minute');
  for i in 1..20 loop perform public.report_user(a, 'spam'); end loop;
  perform test.throws(format($q$select public.report_user(%L, 'spam')$q$, a), 'rate_limited', 'reports: 20 per hour');
  perform test.as_superuser();
  for i in 1..31 loop others := others || test.new_user('rl_t' || i || '_75'); end loop;
  perform test.as_user(a);
  for i in 1..30 loop perform public.send_friend_request(others[i]); end loop;
  perform test.throws(format('select public.send_friend_request(%L)', others[31]), 'rate_limited',
                      'friend requests: 30 per hour');
  perform test.as_superuser();
end $$;
