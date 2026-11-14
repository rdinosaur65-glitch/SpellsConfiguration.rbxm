-- Invite-only registration (migration 0031). Inserting into auth.users here is exactly what
-- Supabase Auth does for /signup, /otp, /invite and the admin API, so every path is covered.
create or replace function test.signup(p_email text, p_username text, p_meta jsonb default '{}'::jsonb,
                                       p_app jsonb default '{}'::jsonb, p_confirmed boolean default true)
returns uuid language plpgsql as $$
declare v uuid;
begin
  insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data, raw_app_meta_data)
  values (gen_random_uuid(), p_email, case when p_confirmed then now() end,
          jsonb_build_object('username', p_username) || p_meta, p_app)
  returning id into v;
  return v;
end $$;
create or replace function test.owner_aal2(p_owner uuid) returns void language plpgsql as $$
begin
  perform test.as_user(p_owner, jsonb_build_object('aal', 'aal2', 'amr', jsonb_build_array(
    jsonb_build_object('method', 'password', 'timestamp', extract(epoch from now())::bigint))));
end $$;
grant execute on function test.signup(text, text, jsonb, jsonb, boolean), test.owner_aal2(uuid) to authenticated, anon;
create table if not exists test.saved_owner as select owner_user_id from private.platform_config;

do $$
declare
  o uuid; u uuid; v uuid; inv record; id1 uuid; id2 uuid; id3 uuid; id4 uuid; c1 text; c2 text; c3 text; c4 text; st jsonb; n integer; r record;
begin
  perform test.as_superuser();
  perform test.ok((select registration_mode from private.platform_config) = 'invite_only', 'default: invite only');
  o := test.new_user('inv_owner_79', 'Owner');
  u := test.new_user('inv_user_79', 'User');
  update private.platform_config set owner_user_id = o;

  -- No code, a made-up code: refused, whatever path creates the account.
  perform test.throws($q$select test.signup('nocode79@test.local', 'nocode_79')$q$, 'invite_required', 'no invitation: refused');
  perform test.throws($q$select test.signup('fake79@test.local', 'fake_79', '{"invite_code": "AAAA-BBBB-CCCC"}')$q$,
                      'invite_invalid', 'unknown code: refused');
  perform test.throws($q$select test.signup('blank79@test.local', 'blank_79', '{"invite_code": " - "}')$q$,
                      'invite_required', 'blank code: refused');

  -- Only the owner, with their own 2FA, manages invitations.
  perform test.as_anon();
  perform test.throws('select * from public.admin_create_invitation(24)', 'sqlstate:42501', 'anon cannot create');
  perform test.throws('select * from public.admin_list_invitations()', 'sqlstate:42501', 'anon cannot list');
  perform test.throws('select * from private.invitations', 'sqlstate:42501', 'anon cannot read the table');
  perform test.as_user(u);
  perform test.throws('select * from public.admin_create_invitation(24)', 'forbidden', 'a member cannot create');
  perform test.throws('select * from public.admin_list_invitations()', 'forbidden', 'a member cannot list');
  perform test.throws(format('select public.admin_revoke_invitation(%L)', gen_random_uuid()), 'forbidden', 'a member cannot revoke');
  perform test.throws($q$select public.admin_set_registration('public')$q$, 'forbidden', 'a member cannot open registration');
  perform test.throws('select * from private.invitations', 'sqlstate:42501', 'a member cannot read the table');
  perform test.as_user(o);
  perform test.throws('select * from public.admin_create_invitation(24)', 'owner_mfa_required', 'owner needs their 2FA session');

  perform test.owner_aal2(o);
  perform test.throws('select * from public.admin_create_invitation(0)', 'invalid_expiry', 'expiry at least an hour');
  perform test.throws('select * from public.admin_create_invitation(721)', 'invalid_expiry', 'expiry at most 30 days');
  perform test.throws($q$select * from public.admin_create_invitation(24, repeat('x', 61))$q$, 'note_too_long', 'note length');
  select * into inv from public.admin_create_invitation(72, 'for Sam');
  c1 := inv.code;
  perform test.ok(c1 ~ '^[A-HJKMNP-Z02-9]{12}$', 'code: 12 unambiguous characters');
  perform test.ok(inv.expires_at between now() + interval '71 hours 59 minutes' and now() + interval '72 hours 1 minute', 'chosen expiry');
  c2 := (select code from public.admin_create_invitation(1));
  c3 := (select code from public.admin_create_invitation(24));
  c4 := (select code from public.admin_create_invitation(24));
  perform test.ok(c1 <> c2 and c2 <> c3 and c3 <> c4, 'codes are unique');

  -- Checking a code (signed out) never consumes it.
  perform test.as_anon();
  st := public.registration_status(lower(substr(c1, 1, 4) || '-' || substr(c1, 5, 4) || ' ' || substr(c1, 9)));
  perform test.ok(st ->> 'mode' = 'invite_only' and st ->> 'invite' = 'pending', 'status: valid code (any spelling)');
  perform test.ok(public.registration_status('ZZZZ-ZZZZ-ZZZZ') ->> 'invite' = 'invalid', 'status: unknown code');
  perform test.ok(public.registration_status() ->> 'invite' is null, 'status without a code');

  -- A failed sign-up (username taken) does not use the invitation up.
  perform test.as_superuser();
  perform test.throws(format($q$select test.signup('taken79@test.local', 'inv_user_79', jsonb_build_object('invite_code', %L))$q$, c1),
                      'username_taken', 'username taken');
  perform test.ok((select redeemed_at is null from private.invitations where code = c1), 'invitation still unused after a failed sign-up');

  -- Redeem: hyphens / lower case / O-for-0 accepted; code removed from the stored metadata.
  v := test.signup('sam79@test.local', 'sam_79', jsonb_build_object('invite_code', lower(substr(c1, 1, 4) || '-' || substr(c1, 5, 4) || '-' || substr(c1, 9))));
  select * into r from private.invitations where code = c1;
  perform test.ok(r.redeemed_by = v and r.redeemed_username = 'sam_79', 'redeemed by the new account');
  perform test.ok(not ((select raw_user_meta_data from auth.users where id = v) ? 'invite_code'), 'code not kept in user metadata');
  perform test.ok(exists (select 1 from public.profiles where id = v), 'profile created');

  -- Single use.
  perform test.throws(format($q$select test.signup('again79@test.local', 'again_79', jsonb_build_object('invite_code', %L))$q$, c1),
                      'invite_invalid', 'a used code is refused');
  perform test.as_anon();
  perform test.ok(public.registration_status(c1) ->> 'invite' = 'redeemed', 'status: used');

  -- Expired.
  perform test.as_superuser();
  update private.invitations set expires_at = now() - interval '1 second' where code = c2;
  perform test.throws(format($q$select test.signup('late79@test.local', 'late_79', jsonb_build_object('invite_code', %L))$q$, c2),
                      'invite_invalid', 'an expired code is refused');

  -- Revoke: pending only; a revoked code is refused.
  select id into id1 from private.invitations where code = c1;
  select id into id2 from private.invitations where code = c2;
  select id into id3 from private.invitations where code = c3;
  select id into id4 from private.invitations where code = c4;
  perform test.owner_aal2(o);
  perform public.admin_revoke_invitation(id3);
  perform test.throws(format('select public.admin_revoke_invitation(%L)', id1),
                      'invitation_not_pending', 'a used invitation cannot be revoked');
  perform test.throws(format('select public.admin_revoke_invitation(%L)', id3),
                      'invitation_not_pending', 'revoking twice');
  perform test.as_superuser();
  perform test.throws(format($q$select test.signup('rev79@test.local', 'rev_79', jsonb_build_object('invite_code', %L))$q$, c3),
                      'invite_invalid', 'a revoked code is refused');

  -- The owner's list: every state; the code itself only while it can still be used.
  perform test.owner_aal2(o);
  select count(*) into n from public.admin_list_invitations() l
   where (l.id, l.status, l.code is not null) in (
     (id1, 'redeemed', false), (id2, 'expired', false), (id3, 'revoked', false), (id4, 'pending', true));
  perform test.ok(n = 4, 'list shows pending, redeemed, expired and revoked');
  perform test.ok((select redeemed_username from public.admin_list_invitations() where code is null and status = 'redeemed' and note = 'for Sam') = 'sam_79',
                  'list shows who joined');
  perform test.as_superuser();
  perform test.ok(exists (select 1 from private.audit_log where action = 'registration.invite_created')
              and exists (select 1 from private.audit_log where action = 'registration.invite_revoked'), 'audited');
  perform test.ok(not exists (select 1 from private.audit_log where details::text like '%' || c4 || '%'), 'codes never written to the audit log');

  -- Public registration: owner switch, capped; back to invite only.
  perform test.as_user(u);
  perform test.throws($q$select public.admin_set_registration('public')$q$, 'forbidden', 'only the owner switches');
  perform test.owner_aal2(o);
  perform test.throws($q$select public.admin_set_registration('open')$q$, 'invalid_mode', 'mode checked');
  perform test.as_superuser();
  select count(*)::integer + 1 into n from public.profiles where account_state <> 'deleting';
  perform test.owner_aal2(o);
  perform public.admin_set_registration('public', n);
  perform test.as_anon();
  perform test.ok(public.registration_status() ->> 'mode' = 'public', 'status: public');
  perform test.as_superuser();
  perform test.signup('pub79@test.local', 'pub_79');
  perform test.throws($q$select test.signup('pub79b@test.local', 'pub_79b')$q$, 'registration_closed', 'public mode is capped');
  perform test.signup('pub79c@test.local', 'pub_79c', jsonb_build_object('invite_code', c4));
  perform test.ok((select redeemed_at is not null from private.invitations where code = c4), 'an invitation still works (and is not capped) in public mode');
  perform test.owner_aal2(o);
  perform public.admin_set_registration('invite_only');
  perform test.as_superuser();
  perform test.throws($q$select test.signup('pub79d@test.local', 'pub_79d')$q$, 'invite_required', 'invite only again');
  perform test.ok(exists (select 1 from private.audit_log where action = 'registration.mode_changed'), 'mode change audited');

  -- Invitations are not capped in invite-only mode.
  update private.platform_config set registration_cap = 1;
  perform test.owner_aal2(o);
  c1 := (select code from public.admin_create_invitation(24));
  perform test.as_superuser();
  perform test.signup('nocap79@test.local', 'nocap_79', jsonb_build_object('invite_code', c1));
  update private.platform_config set registration_cap = 1000;

  -- A purged, never-confirmed sign-up gives its invitation back.
  perform test.owner_aal2(o);
  c1 := (select code from public.admin_create_invitation(24));
  perform test.as_superuser();
  v := test.signup('typo79@test.local', 'typo_79', jsonb_build_object('invite_code', c1), '{}', false);
  update auth.users set created_at = now() - interval '7 hours', confirmation_sent_at = now() - interval '7 hours' where id = v;
  perform private.purge_unconfirmed_signups();
  perform test.ok(not exists (select 1 from auth.users where id = v), 'unconfirmed sign-up purged');
  perform test.ok((select redeemed_at is null and redeemed_by is null from private.invitations where code = c1), 'its invitation is usable again');
end $$;

-- First owner: no invitation; needs the one-time token set with database access, for the
-- configured address, and ownership only once that address is confirmed.
do $$
declare v uuid; w uuid; c text;
begin
  perform test.as_superuser();
  update private.platform_config set owner_user_id = null;
  -- Someone who got an invitation and signs up with the owner's address gains nothing.
  update private.platform_config set owner_bootstrap_email = 'squat79@test.local',
         owner_bootstrap_hash = encode(extensions.digest('tok-squat-79', 'sha256'), 'hex');
  w := test.signup('squat79@test.local', 'squat_79', jsonb_build_object('invite_code', test.new_invite()));
  update auth.users set email_confirmed_at = now() where id = w;
  perform test.ok((select owner_user_id from private.platform_config) is null, 'invited account with the owner address: not owner');

  update private.platform_config set owner_bootstrap_email = 'Boss79@Test.Local',
         owner_bootstrap_hash = encode(extensions.digest('s3cret-token-79', 'sha256'), 'hex');
  perform test.throws($q$select test.signup('boss79@test.local', 'boss_79')$q$, 'invite_required', 'owner address without the token: refused');
  perform test.throws($q$select test.signup('boss79@test.local', 'boss_79', '{"owner_bootstrap_token": "wrong"}')$q$,
                      'invite_required', 'wrong token: refused');
  perform test.throws($q$select test.signup('other79@test.local', 'other_79', '{"owner_bootstrap_token": "s3cret-token-79"}')$q$,
                      'invite_required', 'right token, other address: refused');
  v := test.signup('boss79@test.local', 'boss_79', '{"owner_bootstrap_token": "s3cret-token-79"}', '{}', false);
  perform test.ok(not ((select raw_user_meta_data from auth.users where id = v) ? 'owner_bootstrap_token'), 'token not kept');
  perform test.ok((select owner_bootstrap_hash is null and owner_bootstrap_user = v from private.platform_config), 'token used up');
  perform test.ok((select owner_user_id from private.platform_config) is null, 'not owner before the address is confirmed');
  update auth.users set email_confirmed_at = now() where id = v;
  perform test.ok((select owner_user_id from private.platform_config) = v, 'owner once confirmed');
  perform test.ok((select owner_bootstrap_email is null and owner_bootstrap_user is null from private.platform_config), 'bootstrap closed');
  perform test.ok(exists (select 1 from private.audit_log where action = 'owner.bootstrapped' and target_user_id = v), 'audited');
  -- Nobody can bootstrap again while an owner exists.
  update private.platform_config set owner_bootstrap_email = 'boss79b@test.local',
         owner_bootstrap_hash = encode(extensions.digest('t2-79', 'sha256'), 'hex');
  perform test.throws($q$select test.signup('boss79b@test.local', 'boss_79b', '{"owner_bootstrap_token": "t2-79"}')$q$,
                      'invite_required', 'no second bootstrap while an owner exists');
  update private.platform_config set owner_bootstrap_email = null, owner_bootstrap_hash = null, owner_bootstrap_user = null,
         owner_user_id = (select owner_user_id from test.saved_owner);
end $$;
drop table test.saved_owner;
