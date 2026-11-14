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
    and p.proname not like 'pg\_%';
  perform test.ok(bad is null, 'no public function executable by anon; offenders: ' || coalesce(bad, ''));

  -- 4. Every table in public has RLS enabled.
  select string_agg(c.relname, ', ') into bad
  from pg_class c join pg_namespace n on n.oid = c.relnamespace
  where n.nspname = 'public' and c.relkind = 'r' and not c.relrowsecurity;
  perform test.ok(bad is null, 'RLS on every public table; missing: ' || coalesce(bad, ''));

  -- 5. Search works end-to-end for a signed-in user.
  u := test.new_user('rq_80a'); v := test.new_user('rq_80b');
  perform test.as_user(u);
  perform test.ok((select count(*) from public.search_users('rq_80')) = 1, 'search finds the other user');
  perform test.as_superuser();
end $$;
