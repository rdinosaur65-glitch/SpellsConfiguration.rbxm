-- Owner-only administration, audit log, reporting evidence, bans, sessions,
-- account deletion, Realtime topic authorisation.
do $$
declare o uuid; u uuid; w uuid; conv uuid; msg uuid; rep uuid; s1 uuid; s2 uuid;
begin
  o := test.new_user('boss_60'); u := test.new_user('user_60'); w := test.new_user('witness_60');
  update private.platform_config set owner_user_id = o;
  perform test.befriend(u, w);

  -- Non-owners are refused by every admin RPC.
  perform test.as_user(u);
  perform test.throws($q$select public.admin_usage_summary()$q$, 'forbidden', 'admin summary owner-only');
  perform test.throws($q$select public.admin_search_users(null)$q$, 'forbidden', 'admin search owner-only');
  perform test.throws(format($q$select public.admin_set_account_state(%L, 'banned', 'x')$q$, w), 'forbidden',
                      'no privilege escalation');
  perform test.throws($q$select public.admin_audit_log()$q$, 'forbidden', 'audit log owner-only');
  -- A username cannot make someone the owner.
  perform test.throws($q$select public.change_username('boss_60')$q$, 'username_taken', 'cannot take owner name');

  -- Reporting: evidence is a snapshot of content the reporter could see.
  conv := public.create_direct_conversation(w);
  perform public.set_chat_expiry(conv, 'never');
  msg := public.send_message(conv, 'text', 'abusive text', gen_random_uuid());
  perform test.as_user(o);
  perform test.throws(format($q$select public.report_message(%L, 'harassment')$q$, msg), 'message_not_found',
                      'cannot report unseen content');
  perform test.ok((select count(*) from public.messages where id = msg) = 0, 'owner has no chat access');
  perform test.as_user(w);
  rep := public.report_message(msg, 'harassment', 'please review');
  perform test.ok((select count(*) from public.reports where id = rep) = 1, 'reporter sees own report');

  perform test.as_user(o);
  perform test.ok((select evidence->>'body' from public.admin_list_reports('open') where id = rep) = 'abusive text',
                  'owner sees authorised evidence');
  perform test.ok((select (admin_usage_summary()->>'accounts')::int) >= 3, 'aggregate analytics');

  -- Ban: state, auth ban, sessions revoked, audited, enforced.
  perform test.as_superuser();
  insert into auth.sessions (id, user_id) values (gen_random_uuid(), u) returning id into s1;
  insert into auth.sessions (id, user_id) values (gen_random_uuid(), u) returning id into s2;
  perform test.as_user(o);
  perform test.throws(format($q$select public.admin_set_account_state(%L, 'banned', '')$q$, u), 'reason_required',
                      'reason required');
  perform test.throws(format($q$select public.admin_set_account_state(%L, 'banned', 'x')$q$, o), 'cannot_moderate_owner',
                      'owner cannot ban self');
  perform public.admin_set_account_state(u, 'banned', 'harassment report ' || rep);
  perform public.admin_resolve_report(rep, 'actioned', 'banned');
  perform test.as_superuser();
  perform test.ok((select banned_until = 'infinity' from auth.users where id = u), 'auth-level ban');
  perform test.ok((select count(*) from auth.sessions where user_id = u) = 0, 'sessions revoked on ban');
  perform test.ok((select count(*) from private.audit_log where target_user_id = u and action = 'account.set_state') = 1,
                  'ban audited');
  perform test.throws($q$update private.audit_log set action = 'x'$q$, 'audit_log is append-only', 'audit immutable');
  perform test.as_user(u);
  perform test.throws(format($q$select public.send_message(%L, 'text', 'still here', gen_random_uuid())$q$, conv),
                      'account_not_active', 'banned user cannot act');
  perform test.as_user(w);
  perform test.ok((select count(*) from public.search_users('user_60')) = 0, 'banned user hidden from search');
  perform test.as_superuser();
  update private.platform_config set owner_user_id = null;
end $$;

-- Session management.
do $$
declare w uuid := (select id from public.profiles where username = 'witness_60'); cur uuid; other uuid;
begin
  insert into auth.sessions (id, user_id, user_agent) values (gen_random_uuid(), w, 'phone') returning id into cur;
  insert into auth.sessions (id, user_id, user_agent) values (gen_random_uuid(), w, 'laptop') returning id into other;
  perform test.as_user(w, jsonb_build_object('session_id', cur));
  perform test.ok((select count(*) from public.my_sessions()) = 2, 'device/session history');
  perform test.ok((select current from public.my_sessions() where id = cur), 'current session flagged');
  perform test.ok(public.revoke_other_sessions() = 1, 'remote revocation');
  perform test.ok((select count(*) from public.my_sessions()) = 1, 'only current left');
  perform test.as_superuser();
end $$;

-- Realtime broadcast topics require membership.
do $$
declare a uuid; b uuid; x uuid; conv uuid;
begin
  a := test.new_user('rt_a_60'); b := test.new_user('rt_b_60'); x := test.new_user('rt_x_60');
  perform test.befriend(a, b);
  perform test.as_user(a);
  conv := public.create_direct_conversation(b);
  perform test.ok(private.can_use_topic('conv:' || conv), 'member may join conversation channel');
  perform test.ok(not private.can_use_topic('conv:not-a-uuid'), 'malformed topic refused');
  perform test.as_user(x);
  perform test.ok(not private.can_use_topic('conv:' || conv), 'outsider refused (no typing/call leakage)');
  perform test.as_superuser();
end $$;

-- Account deletion: re-auth required, immediate disablement, staged purge.
do $$
declare d uuid; f uuid; asset uuid; rep uuid; conv uuid;
begin
  d := test.new_user('leaver_60'); f := test.new_user('friend_60');
  perform test.befriend(d, f);
  asset := test.upload(d, 'chat', 'image/jpeg', 1000);
  perform test.as_user(f);
  rep := public.report_user(d, 'spam');
  perform test.as_superuser();
  insert into auth.sessions (id, user_id) values (gen_random_uuid(), d);

  perform test.as_user(d);
  perform test.throws($q$select public.request_account_deletion()$q$, 'reauthentication_required', 'stale login refused');
  perform test.as_user(d, jsonb_build_object('amr', jsonb_build_array(
    jsonb_build_object('method', 'password', 'timestamp', extract(epoch from now())::bigint))));
  perform public.request_account_deletion();

  perform test.as_superuser();
  perform test.ok((select account_state from public.profiles where id = d) = 'deleting', 'access disabled immediately');
  perform test.ok((select count(*) from auth.sessions where user_id = d) = 0, 'sessions invalidated');
  perform test.ok((select status from public.media_assets where id = asset) = 'deleting', 'media deletion scheduled');

  perform private.run_maintenance();
  perform test.ok(exists (select 1 from auth.users where id = d), 'account kept until media objects are removed');
  perform test.as_superuser();
  perform set_config('role', 'service_role', false);
  perform public.janitor_mark_deleted(array(select asset_id from public.janitor_claim_deletions(1000)));
  perform test.as_superuser();
  perform private.run_maintenance();
  perform test.ok(not exists (select 1 from auth.users where id = d), 'account rows deleted');
  perform test.ok(not exists (select 1 from public.friendships where user_a = d or user_b = d), 'relationships gone');
  perform test.ok((select target_user_id is null and evidence ? 'username' from public.reports where id = rep),
                  'report evidence retained without account link');
end $$;
