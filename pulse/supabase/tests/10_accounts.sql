-- Accounts, usernames, privileges, registration cap.
do $$
declare a uuid; b uuid; o uuid; v text; id_before uuid;
begin
  a := test.new_user('alice_10', 'Alice');
  perform test.ok((select count(*) from public.profiles where id = a) = 1, 'profile created on signup');
  perform test.ok((select count(*) from public.user_settings where user_id = a) = 1, 'settings created');

  -- Case-insensitive uniqueness through the signup path.
  perform test.throws($q$select test.new_user('ALICE_10')$q$, 'username_taken', 'duplicate username, other case');
  perform test.throws($q$select test.new_user('ab')$q$, 'invalid_username', 'too short');
  perform test.throws($q$select test.new_user('bad name')$q$, 'invalid_username', 'space');
  perform test.throws($q$select test.new_user('a__b_10')$q$, 'invalid_username', 'double underscore');
  perform test.throws($q$select test.new_user('admin')$q$, 'username_reserved', 'reserved word');

  -- Username change + cooldown; internal id never changes.
  b := test.new_user('bob_10');
  perform test.as_user(a);
  v := public.change_username('alicia_10');
  perform test.ok(v = 'alicia_10', 'username changed');
  perform test.ok((select id from public.profiles where username = 'alicia_10') = a, 'same internal id');
  perform test.throws($q$select public.change_username('alicia2_10')$q$, 'username_cooldown', '48h cooldown');

  -- Old name reserved against impersonation (signup and rename).
  perform test.as_superuser();
  perform test.throws($q$select test.new_user('alice_10')$q$, 'username_taken', 'old name reserved for signup');
  perform test.as_user(b);
  perform test.throws($q$select public.change_username('alice_10')$q$, 'username_taken', 'old name reserved for rename');

  -- Cooldown elapsed -> allowed.
  perform test.as_superuser();
  update public.profiles set username_changed_at = now() - interval '49 hours' where id = a;
  perform test.as_user(a);
  perform public.change_username('alicia2_10');
  -- The original holder may reclaim their own reserved name.
  perform test.as_superuser();
  update public.profiles set username_changed_at = null where id = a;
  perform test.as_user(a);
  perform public.change_username('alice_10');

  -- Owner has no cooldown.
  perform test.as_superuser();
  o := test.new_user('owner_10');
  update private.platform_config set owner_user_id = o;
  perform test.as_user(o);
  perform public.change_username('owner2_10');
  perform public.change_username('owner3_10');
  perform test.ok(public.am_i_owner(), 'owner recognised by id');
  perform test.as_superuser();
  update private.platform_config set owner_user_id = null;
end $$;

-- Column and table privileges.
do $$
declare a uuid := (select id from public.profiles where username = 'alice_10');
begin
  perform test.as_user(a);
  update public.profiles set display_name = 'Alice B', bio = 'hi' where id = a;
  perform test.ok((select display_name from public.profiles where id = a) = 'Alice B', 'cosmetic update ok');
  perform test.throws(format($q$update public.profiles set account_state = 'active' where id = %L$q$, a),
                      'sqlstate:42501', 'cannot touch account_state');
  perform test.throws(format($q$update public.profiles set username = 'zzz_10' where id = %L$q$, a),
                      'sqlstate:42501', 'cannot bypass change_username');
  perform test.throws($q$select * from private.platform_config$q$, 'sqlstate:42501', 'private schema closed');
  perform test.as_anon();
  perform test.throws($q$select * from public.profiles$q$, 'sqlstate:42501', 'anon reads nothing');
  perform test.throws($q$select public.search_users('alice')$q$, 'sqlstate:42501', 'anon cannot call RPCs');
  perform test.as_superuser();
end $$;

-- Registration cap (free-tier capacity guard).
do $$
declare n integer := (select count(*) from public.profiles);
begin
  -- The cap applies to public registration (0031); invitations are not capped.
  update private.platform_config set registration_mode = 'public', registration_cap = n;
  perform test.throws($q$insert into auth.users (id, email, raw_user_meta_data) values
    (gen_random_uuid(), 'overflow_10@test.local', '{"username": "overflow_10"}')$q$, 'registration_closed', 'cap enforced');
  update private.platform_config set registration_mode = 'invite_only', registration_cap = 1000;
end $$;

-- Settings are private to their owner.
do $$
declare a uuid := (select id from public.profiles where username = 'alice_10');
        b uuid := (select id from public.profiles where username = 'bob_10');
begin
  perform test.as_user(b);
  perform test.ok((select count(*) from public.user_settings where user_id = a) = 0, 'cannot read others settings');
  perform test.as_user(a);
  update public.user_settings set appearance = '{"mode":"amoled","accent":"#22c55e"}' where user_id = a;
  perform test.ok((select appearance->>'mode' from public.user_settings where user_id = a) = 'amoled',
                  'appearance persists');
  perform test.as_superuser();
end $$;

-- No relationship/owner probing helpers are exposed through the API surface.
do $$
declare a uuid := (select id from public.profiles where username = 'alice_10');
begin
  perform test.as_user(a);
  perform test.ok(not has_function_privilege('authenticated', 'public.janitor_claim_deletions(integer)', 'execute'),
                  'janitor not callable by users');
  perform test.ok(not has_function_privilege('anon', 'public.chat_list()', 'execute'), 'anon cannot call chat_list');
  perform test.ok(not exists (select 1 from pg_proc p join pg_namespace n on n.oid = p.pronamespace
                              where n.nspname = 'public' and p.proname in ('are_friends','is_blocked_either','is_member','is_owner')),
                  'probing helpers are not in the exposed schema');
  perform test.as_superuser();
end $$;
