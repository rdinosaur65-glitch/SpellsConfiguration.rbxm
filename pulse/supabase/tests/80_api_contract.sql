-- API contract checks that mirror how PostgREST calls functions.
do $$
declare bad text; u uuid; v uuid;
begin
  -- 1. No STABLE/IMMUTABLE function callable by clients may write (PostgREST runs them
  --    read-only). Checks the function source for write paths.
  select string_agg(p.proname, ', ') into bad
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.provolatile in ('s', 'i')
    and has_function_privilege('authenticated', p.oid, 'execute')
    and p.prosrc ~* '(rate_limit_hit|private\.audit\(|charge_egress|\minsert\s+into|\mupdate\s+[a-z_.]+\s+set|\mdelete\s+from)';
  perform test.ok(bad is null, 'read-only-safe RPCs; offenders: ' || coalesce(bad, ''));

  -- 2. The search RPCs work inside a read-only transaction context as PostgREST would
  --    run a GET, i.e. they are not marked STABLE while writing. (Volatile functions are
  --    called in read-write transactions by PostgREST, so here we just assert volatility.)
  perform test.ok((select provolatile from pg_proc where oid = 'public.search_users(text)'::regprocedure) = 'v',
                  'search_users volatile');

  -- 3. Every function in public granted to authenticated is also closed to anon.
  select string_agg(p.proname, ', ') into bad
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and has_function_privilege('anon', p.oid, 'execute')
    and p.proname not like 'pg\_%'
    and p.proname <> 'registration_status';     -- the sign-up screen (signed out), 0031
  perform test.ok(bad is null, 'no public function executable by anon; offenders: ' || coalesce(bad, ''));

  -- 4. Every table in public has RLS enabled.
  select string_agg(c.relname, ', ') into bad
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;
  perform test.ok(bad is null, 'RLS on every public table; missing: ' || coalesce(bad, ''));

  -- 5. Every RLS table in public carries the restrictive 2FA gate (migration 0013).
  select string_agg(c.relname, ', ') into bad
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r'
    and not exists (select 1 from pg_policies p where p.schemaname = 'public' and p.tablename = c.relname
                    and p.policyname = 'mfa_gate' and p.permissive = 'RESTRICTIVE');
  perform test.ok(bad is null, 'mfa_gate on every table; missing: ' || coalesce(bad, ''));

  -- 6. Every RLS table in public carries the restrictive account-state gate (0014).
  select string_agg(c.relname, ', ') into bad
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r'
    and not exists (select 1 from pg_policies p where p.schemaname = 'public' and p.tablename = c.relname
                    and p.policyname = 'active_gate' and p.permissive = 'RESTRICTIVE');
  perform test.ok(bad is null, 'active_gate on every table; missing: ' || coalesce(bad, ''));

  -- 7. STABLE/IMMUTABLE client RPCs never call a VOLATILE function (other than the error
  --    helper), directly in their source. Catches indirect writes such as a STABLE RPC
  --    calling a rate-limited one.
  select string_agg(distinct p.proname || ' -> ' || mm.m[1] || '.' || mm.m[2], ', ') into bad
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  cross join lateral regexp_matches(p.prosrc, '(private|public)\.([a-z_0-9]+)\s*\(', 'g') as mm(m)
  join pg_namespace cn on cn.nspname = mm.m[1]
  join pg_proc callee on callee.pronamespace = cn.oid and callee.proname = mm.m[2]
  where n.nspname = 'public' and p.provolatile in ('s', 'i')
    and has_function_privilege('authenticated', p.oid, 'execute')
    and callee.provolatile = 'v' and callee.proname <> 'fail';
  perform test.ok(bad is null, 'STABLE RPCs call only STABLE helpers; offenders: ' || coalesce(bad, ''));

  -- 8. Every SECURITY DEFINER RPC open to clients checks the caller itself.
  select string_agg(p.proname, ', ') into bad
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.prosecdef
    and has_function_privilege('authenticated', p.oid, 'execute')
    and p.prosrc !~ '(assert_active|assert_mfa|assert_owner|mfa_satisfied)\('
    and p.proname <> 'registration_status';     -- meant for signed-out callers; reveals no account data
  perform test.ok(bad is null, 'definer RPCs check the caller; offenders: ' || coalesce(bad, ''));

  -- 9. Every foreign key with an ON DELETE action has an index on its columns, so
  --    purges and account deletion do not scan whole tables.
  select string_agg(format('%s.%s(%s)', n.nspname, c.relname,
           (select string_agg(a.attname, ',') from unnest(con.conkey) k
              join pg_attribute a on a.attrelid = con.conrelid and a.attnum = k)), ', ') into bad
  from pg_constraint con join pg_class c on c.oid = con.conrelid join pg_namespace n on n.oid = c.relnamespace
  where con.contype = 'f' and con.confdeltype in ('c', 'n', 'd') and n.nspname in ('public', 'private')
    and not exists (
      select 1 from pg_index i where i.indrelid = con.conrelid
        and (select array_agg(x order by x) from (
               select x from unnest(i.indkey::int2[]) with ordinality u(x, o)
                where o <= cardinality(con.conkey)) s)
            = (select array_agg(x order by x) from unnest(con.conkey) x));
  perform test.ok(bad is null, 'indexed foreign keys; missing: ' || coalesce(bad, ''));

  -- 10. Every client write RPC (VOLATILE, callable by users) is rate-limited, except the
  --     owner-only admin RPCs and the one-shot account deletion.
  select string_agg(p.proname, ', ') into bad
  from pg_proc p join pg_namespace n on n.oid = p.pronamespace
  where n.nspname = 'public' and p.provolatile = 'v'
    and has_function_privilege('authenticated', p.oid, 'execute')
    and p.prosrc !~ 'rate_limit_hit'
    and p.proname !~ '^admin_' and p.proname <> 'request_account_deletion';
  perform test.ok(bad is null, 'write RPCs rate-limited; missing: ' || coalesce(bad, ''));

  -- 11. Search works end-to-end for a signed-in user.
  u := test.new_user('rq_80a'); v := test.new_user('rq_80b');
  perform test.as_user(u);
  perform test.ok((select count(*) from public.search_users('rq_80')) = 1, 'search finds the other user');
  perform test.as_superuser();
end $$;
