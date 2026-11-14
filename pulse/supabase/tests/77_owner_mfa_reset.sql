-- Owner-verified 2FA reset (migration 0021). The email step is played by the test as the
-- Edge Function would (service role); delivery itself is covered by functions.test.mjs.
create or replace function test.fresh_owner(p_owner uuid) returns void language plpgsql as $$
begin
  perform test.as_user(p_owner, jsonb_build_object('aal', 'aal2', 'amr', jsonb_build_array(
    jsonb_build_object('method', 'password', 'timestamp', extract(epoch from now())::bigint))));
end $$;
create or replace function test.issue(p_request uuid) returns text language plpgsql as $$
declare v text;
begin
  perform set_config('role', 'service_role', false);
  select code into v from public.mfa_reset_issue_code(p_request);
  perform public.mfa_reset_mark_sent(p_request, true);
  perform test.as_superuser();
  return v;
end $$;
grant execute on function test.fresh_owner(uuid), test.issue(uuid) to authenticated, service_role;

do $$
declare o uuid; t uuid; t2 uuid; t3 uuid; x uuid; r1 uuid; r2 uuid; r3 uuid; r4 uuid; r5 uuid; r6 uuid; r7 uuid; r8 uuid;
        c1 text; c2 text; c3 text; c4 text; c5 text; c7 text; res jsonb; em text; i integer;
begin
  o := test.new_user('own_77'); t := test.new_user('tgt_77'); t2 := test.new_user('tgt2_77');
  t3 := test.new_user('tgt3_77'); x := test.new_user('nobody_77');
  update private.platform_config set owner_user_id = o;
  insert into auth.mfa_factors (id, user_id, factor_type, status, created_at, updated_at) values
    (gen_random_uuid(), o, 'totp', 'verified', now(), now()),
    (gen_random_uuid(), t, 'totp', 'verified', now(), now()),
    (gen_random_uuid(), t3, 'totp', 'verified', now(), now());
  insert into auth.sessions (id, user_id) values (gen_random_uuid(), t), (gen_random_uuid(), t);

  -- Unauthorised requests.
  perform test.as_user(x, jsonb_build_object('aal', 'aal2', 'amr', jsonb_build_array(
    jsonb_build_object('method', 'password', 'timestamp', extract(epoch from now())::bigint))));
  perform test.throws(format($q$select public.admin_mfa_reset_request(%L, 'x')$q$, t), 'forbidden', 'non-owner refused');
  perform test.as_user(o, '{"aal":"aal1"}');
  perform test.throws(format($q$select public.admin_mfa_reset_request(%L, 'x')$q$, t), 'mfa_required', 'owner needs aal2');
  perform test.as_user(o, jsonb_build_object('aal', 'aal2', 'amr', jsonb_build_array(
    jsonb_build_object('method', 'password', 'timestamp', extract(epoch from now())::bigint - 3600),
    jsonb_build_object('method', 'totp', 'timestamp', extract(epoch from now())::bigint))));
  perform test.throws(format($q$select public.admin_mfa_reset_request(%L, 'x')$q$, t), 'reauthentication_required',
                      'fresh password sign-in required');
  perform test.fresh_owner(o);
  perform test.throws(format($q$select public.admin_mfa_reset_request(%L, '')$q$, t), 'reason_required', 'reason required');
  perform test.throws(format($q$select public.admin_mfa_reset_request(%L, 'x')$q$, o), 'cannot_moderate_owner', 'not on self');
  perform test.throws('select public.admin_reset_mfa(gen_random_uuid(), ''x'')', 'sqlstate:42883', 'one-step reset removed');

  -- Successful reset.
  r1 := public.admin_mfa_reset_request(t, 'lost phone, confirmed by call');
  perform test.throws(format('select * from public.mfa_reset_issue_code(%L)', r1), 'sqlstate:42501', 'users cannot issue codes');
  perform test.throws(format('select * from public.mfa_reset_execute(%L)', r1), 'sqlstate:42501', 'users cannot execute');
  perform set_config('role', 'service_role', false);
  select code, owner_email into c1, em from public.mfa_reset_issue_code(r1);
  perform test.throws(format('select * from public.mfa_reset_issue_code(%L)', r1), 'request_not_found', 'one code per request');
  perform test.as_superuser();
  perform test.ok(c1 ~ '^[0-9]{6}$', 'six-digit code');
  perform test.ok(em = (select email from auth.users where id = o), 'code goes to the owner''s verified email');
  perform test.ok(em <> (select email from auth.users where id = t), 'never to the target');
  perform set_config('role', 'service_role', false);
  perform public.mfa_reset_mark_sent(r1, true);
  perform test.as_superuser();
  perform test.ok((select code_hash <> c1 and code_hash is not null from private.mfa_reset_requests where id = r1),
                  'only a hash is stored');
  perform test.fresh_owner(o);
  res := public.admin_mfa_reset_confirm(r1, lpad(((c1::int + 1) % 1000000)::text, 6, '0'));
  perform test.ok(res ->> 'status' = 'incorrect' and (res ->> 'attempts_left')::int = 4, 'wrong code counted');
  perform set_config('role', 'service_role', false);
  perform test.throws(format('select * from public.mfa_reset_execute(%L)', r1), 'request_not_verified', 'nothing happens before verification');
  perform test.fresh_owner(o);
  perform test.ok(public.admin_mfa_reset_confirm(r1, c1) ->> 'status' = 'verified', 'correct code verifies');
  perform test.ok(public.admin_mfa_reset_confirm(r1, c1) ->> 'status' = 'used', 'replay refused');
  perform test.as_superuser();
  perform test.ok(exists (select 1 from auth.mfa_factors where user_id = t), 'verification alone changes nothing');
  perform set_config('role', 'service_role', false);
  perform test.ok((select factors_removed = 1 and sessions_revoked = 2 from public.mfa_reset_execute(r1)), 'reset carried out');
  perform test.throws(format('select * from public.mfa_reset_execute(%L)', r1), 'request_not_verified', 'single use');
  perform test.as_superuser();
  perform test.ok(not exists (select 1 from auth.mfa_factors where user_id = t), 'target 2FA removed');
  perform test.ok(not exists (select 1 from auth.sessions where user_id = t), 'target signed out everywhere');

  -- A code is bound to its request (and target).
  delete from private.rate_limits where user_id = o;
  perform test.fresh_owner(o);
  r2 := public.admin_mfa_reset_request(t2, 'binding test a');
  r3 := public.admin_mfa_reset_request(t3, 'binding test b');
  c2 := test.issue(r2); c3 := test.issue(r3);
  perform test.fresh_owner(o);
  perform test.ok(public.admin_mfa_reset_confirm(r3, c2) ->> 'status' = 'incorrect', 'another request''s code does not work');
  perform test.as_superuser();
  perform test.ok(exists (select 1 from auth.mfa_factors where user_id = t3), 'other target untouched');

  -- Expiry.
  perform test.fresh_owner(o);
  r4 := public.admin_mfa_reset_request(t3, 'expiry test');      -- replaces r3
  perform test.ok(public.admin_mfa_reset_confirm(r3, c3) ->> 'status' = 'cancelled', 'a newer request cancels the old code');
  perform test.as_superuser();
  perform test.ok(exists (select 1 from private.audit_log where action = 'account.mfa_reset.cancelled'
                           and details ->> 'request_id' = r3::text and target_user_id = t3), 'the replaced request is audited (0026)');
  perform test.ok((select code_hash is null from private.mfa_reset_requests where id = r3), 'its code hash is dropped');
  c4 := test.issue(r4);
  update private.mfa_reset_requests set expires_at = now() - interval '1 second' where id = r4;
  perform test.fresh_owner(o);
  perform test.ok(public.admin_mfa_reset_confirm(r4, c4) ->> 'status' = 'expired', 'expired after 5 minutes');
  perform test.ok(public.admin_mfa_reset_confirm(r4, c4) ->> 'status' = 'expired', 'stays expired');
  perform test.as_superuser();
  perform test.ok((select expires_at <= code_sent_at + interval '5 minutes' from private.mfa_reset_requests where id = r2),
                  'codes live 5 minutes');

  -- Lockout after 5 wrong codes.
  delete from private.rate_limits where user_id = o;
  perform test.fresh_owner(o);
  r5 := public.admin_mfa_reset_request(t3, 'lockout test');
  c5 := test.issue(r5);
  perform test.fresh_owner(o);
  for i in 1..4 loop perform public.admin_mfa_reset_confirm(r5, '000000'); end loop;
  res := public.admin_mfa_reset_confirm(r5, '000001');
  perform test.ok(res ->> 'status' = 'locked', 'locked after the fifth wrong code');
  perform test.ok(public.admin_mfa_reset_confirm(r5, c5) ->> 'status' = 'locked', 'correct code no longer accepted');
  perform test.as_superuser();
  perform test.ok(exists (select 1 from auth.mfa_factors where user_id = t3), 'locked request changed nothing');

  -- Email failure: the request can never complete.
  perform test.fresh_owner(o);
  r6 := public.admin_mfa_reset_request(t3, 'email failure test');
  perform set_config('role', 'service_role', false);
  select code into c7 from public.mfa_reset_issue_code(r6);
  perform public.mfa_reset_mark_sent(r6, false, 'smtp down');
  perform test.fresh_owner(o);
  perform test.ok(public.admin_mfa_reset_confirm(r6, c7) ->> 'status' = 'failed', 'undelivered code is useless');
  perform set_config('role', 'service_role', false);
  perform test.throws(format('select * from public.mfa_reset_execute(%L)', r6), 'request_not_verified', 'no reset without delivery');
  perform test.as_superuser();
  perform test.ok(exists (select 1 from auth.mfa_factors where user_id = t3), 'still untouched');

  -- Issuing late (more than a minute after the request) is refused.
  perform test.fresh_owner(o);
  r7 := public.admin_mfa_reset_request(t2, 'late issue test');
  perform test.as_superuser();
  update private.mfa_reset_requests set created_at = now() - interval '2 minutes' where id = r7;
  perform set_config('role', 'service_role', false);
  perform test.throws(format('select * from public.mfa_reset_issue_code(%L)', r7), 'request_not_found', 'stale request cannot get a code');

  -- Rate limit on new requests (5 an hour).
  perform test.as_superuser();
  delete from private.rate_limits where user_id = o;
  perform test.fresh_owner(o);
  for i in 1..5 loop r8 := public.admin_mfa_reset_request(t2, 'rate ' || i); end loop;
  perform test.throws(format($q$select public.admin_mfa_reset_request(%L, 'one too many')$q$, t2), 'rate_limited',
                      'new codes are rate-limited');

  -- An unverified owner email blocks the flow.
  perform test.as_superuser();
  delete from private.rate_limits where user_id = o;
  update auth.users set email_confirmed_at = null where id = o;
  perform test.fresh_owner(o);
  perform test.throws(format($q$select public.admin_mfa_reset_request(%L, 'x')$q$, t2), 'owner_email_unverified',
                      'owner email must be verified');
  perform test.as_superuser();
  update auth.users set email_confirmed_at = now() where id = o;

  -- Audit trail.
  perform test.ok((select count(distinct action) from private.audit_log where action like 'account.mfa_reset.%'
                   and action in ('account.mfa_reset.requested', 'account.mfa_reset.code_sent', 'account.mfa_reset.code_incorrect',
                                  'account.mfa_reset.verified', 'account.mfa_reset.completed', 'account.mfa_reset.expired',
                                  'account.mfa_reset.locked', 'account.mfa_reset.email_failed')) = 8,
                  'request, delivery, outcomes and completion are audited');
  perform test.ok((select count(*) from private.audit_log where action = 'account.mfa_reset.completed' and target_user_id = t) = 1,
                  'completed reset names the target');
  update private.platform_config set owner_user_id = null;
end $$;
