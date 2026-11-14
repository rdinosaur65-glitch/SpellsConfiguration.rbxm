-- Two-step verification is enforced by the database once a factor is verified.
do $$
declare u uuid; f uuid; v uuid; c uuid;
begin
  u := test.new_user('mfa_90'); v := test.new_user('pal_90');
  perform test.befriend(u, v);
  perform test.as_user(u);
  c := public.create_direct_conversation(v);

  -- No factor: a normal (aal1) session works.
  perform test.ok((select count(*) from public.profiles where id = u) = 1, 'aal1 ok without 2FA');
  perform public.touch_presence();

  -- An unverified (abandoned) enrollment does not lock the user out.
  perform test.as_superuser();
  insert into auth.mfa_factors (id, user_id, factor_type, status, created_at, updated_at)
  values (gen_random_uuid(), u, 'totp', 'unverified', now(), now()) returning id into f;
  perform test.as_user(u);
  perform test.ok((select count(*) from public.profiles where id = u) = 1, 'unverified factor: still aal1 ok');

  -- Verified factor: aal1 is refused everywhere.
  perform test.as_superuser();
  update auth.mfa_factors set status = 'verified' where id = f;
  perform test.as_user(u, '{"aal":"aal1"}');
  perform test.throws('select public.touch_presence()', 'mfa_required', 'RPC via assert_active');
  perform test.throws('select * from public.my_sessions()', 'mfa_required', 'direct-auth RPC');
  perform test.throws('select public.request_account_deletion()', 'mfa_required', 'deletion needs aal2');
  perform test.throws(format('select public.send_message(%L, ''text'', ''hi'', gen_random_uuid())', c), 'mfa_required', 'send blocked');
  perform test.ok((select count(*) from public.profiles where id = u) = 0, 'own profile hidden at aal1');
  perform test.ok((select count(*) from public.user_settings) = 0, 'settings hidden at aal1');
  perform test.ok((select count(*) from public.conversations) = 0, 'chats hidden at aal1');
  perform test.ok(not private.can_use_topic('conv:' || c), 'realtime topic refused at aal1');
  perform test.throws(format('select public.delete_message(%L)', gen_random_uuid()), 'mfa_required', 'delete_message');
  perform test.throws(format('select public.delete_media_asset(%L)', gen_random_uuid()), 'mfa_required', 'delete_media_asset');
  perform test.throws(format('select public.close_snap_view(%L, %L)', gen_random_uuid(), gen_random_uuid()), 'mfa_required',
                      'close_snap_view');
  perform test.throws(format('select public.revoke_session(%L)', gen_random_uuid()), 'mfa_required', 'revoke_session');
  perform test.throws('select public.revoke_other_sessions()', 'mfa_required', 'revoke_other_sessions');
  perform test.throws('select * from public.my_profile()', 'mfa_required', 'my_profile');
  perform test.ok((select count(*) from storage.objects where bucket_id = 'media') = 0, 'no Storage reads at aal1');
  perform test.ok(not public.am_i_owner(), 'am_i_owner false at aal1');

  -- aal2 session: everything works again.
  perform test.as_user(u, '{"aal":"aal2"}');
  perform test.ok((select count(*) from public.profiles where id = u) = 1, 'aal2 profile visible');
  perform public.touch_presence();
  perform test.ok(public.send_message(c, 'text', 'hi', gen_random_uuid()) is not null, 'aal2 can send');
  perform test.ok(private.can_use_topic('conv:' || c), 'aal2 topic ok');

  -- An owner with 2FA: every admin RPC needs aal2.
  perform test.as_superuser();
  update private.platform_config set owner_user_id = u;
  perform test.as_user(u, '{"aal":"aal1"}');
  perform test.throws('select public.admin_usage_summary()', 'mfa_required', 'admin_usage_summary');
  perform test.throws('select * from public.admin_search_users(null)', 'mfa_required', 'admin_search_users');
  perform test.throws('select * from public.admin_list_reports()', 'mfa_required', 'admin_list_reports');
  perform test.throws(format($q$select public.admin_resolve_report(%L, 'dismissed')$q$, gen_random_uuid()), 'mfa_required',
                      'admin_resolve_report');
  perform test.throws(format($q$select public.admin_set_account_state(%L, 'suspended', 'x')$q$, v), 'mfa_required',
                      'admin_set_account_state');
  perform test.throws(format($q$select public.admin_delete_account(%L, 'x')$q$, v), 'mfa_required', 'admin_delete_account');
  perform test.throws('select * from public.admin_audit_log()', 'mfa_required', 'admin_audit_log');
  perform test.as_user(u, '{"aal":"aal2"}');
  perform test.ok((public.admin_usage_summary() ->> 'accounts') is not null, 'owner at aal2 can administer');
  perform test.as_superuser();
  update private.platform_config set owner_user_id = null;

  -- The friend (no 2FA) is unaffected.
  perform test.as_user(v);
  perform test.ok((select count(*) from public.messages where conversation_id = c) = 1, 'friend reads normally');
  perform test.as_superuser();
end $$;
