-- Test helpers (local only). Loaded before every test file.
set client_min_messages = warning;
reset role;
create schema if not exists test;
grant usage on schema test to authenticated, anon, service_role;

update private.platform_config set registration_cap = 1000;

-- Create a user through the real signup trigger. Returns the new id.
create or replace function test.new_user(p_username text, p_display text default null)
returns uuid language plpgsql as $$
declare v uuid;
begin
  -- Real Supabase auth.users.id has no default, so supply one (works with the shim too).
  insert into auth.users (id, email, email_confirmed_at, raw_user_meta_data)
  values (gen_random_uuid(), p_username || '.' || gen_random_uuid() || '@test.local', now(),
          jsonb_build_object('username', p_username, 'display_name', coalesce(p_display, p_username)))
  returning id into v;
  return v;
end $$;

-- Switch the session to an authenticated user (claims as Supabase would provide them).
create or replace function test.as_user(p_uid uuid, p_extra jsonb default '{}'::jsonb)
returns void language plpgsql as $$
begin
  perform set_config('role', 'none', false);
  perform set_config('request.jwt.claims',
    (jsonb_build_object('sub', p_uid, 'role', 'authenticated') || p_extra)::text, false);
  perform set_config('role', 'authenticated', false);
end $$;

create or replace function test.as_anon() returns void language plpgsql as $$
begin
  perform set_config('role', 'none', false);
  perform set_config('request.jwt.claims', '{"role":"anon"}', false);
  perform set_config('role', 'anon', false);
end $$;

create or replace function test.as_superuser() returns void language plpgsql as $$
begin
  perform set_config('role', 'none', false);
  perform set_config('request.jwt.claims', '', false);
end $$;

create or replace function test.ok(p_cond boolean, p_label text) returns void language plpgsql as $$
begin
  if p_cond is distinct from true then raise exception 'ASSERTION FAILED: %', p_label; end if;
end $$;

-- Run SQL and require it to fail with the given error message (our private.fail codes)
-- or SQLSTATE (prefix "sqlstate:").
create or replace function test.throws(p_sql text, p_expect text, p_label text default null)
returns void language plpgsql as $$
declare v_msg text; v_state text;
begin
  begin
    execute p_sql;
  exception when others then
    get stacked diagnostics v_msg = message_text, v_state = returned_sqlstate;
    if p_expect like 'sqlstate:%' then
      if v_state <> substr(p_expect, 10) then
        raise exception 'ASSERTION FAILED (%): expected sqlstate %, got % (%)',
          coalesce(p_label, p_sql), substr(p_expect, 10), v_state, v_msg;
      end if;
    elsif v_msg <> p_expect then
      raise exception 'ASSERTION FAILED (%): expected error "%", got "%"',
        coalesce(p_label, p_sql), p_expect, v_msg;
    end if;
    return;
  end;
  raise exception 'ASSERTION FAILED (%): expected error "%", but it succeeded',
    coalesce(p_label, p_sql), p_expect;
end $$;

-- Make two users friends via the real request/accept RPCs.
create or replace function test.befriend(p_a uuid, p_b uuid) returns void language plpgsql as $$
declare v_req uuid;
begin
  perform test.as_user(p_a);
  v_req := public.send_friend_request(p_b);
  perform test.as_user(p_b);
  perform public.respond_friend_request(v_req, true);
  perform test.as_superuser();
end $$;

-- Simulate a completed upload: reserve via RPC, insert the storage object as the Storage
-- API would, confirm via RPC. Returns the asset id.
create or replace function test.upload(p_uid uuid, p_purpose public.media_purpose, p_mime text,
                                       p_bytes bigint, p_duration numeric default null)
returns uuid language plpgsql as $$
declare v_asset uuid; v_path text; v_hash text;
begin
  v_hash := encode(extensions.digest(gen_random_uuid()::text, 'sha256'), 'hex');
  perform test.as_user(p_uid);
  select asset_id, object_path into v_asset, v_path
    from public.authorize_upload(p_purpose, p_mime, p_bytes, v_hash, p_duration);
  insert into storage.objects (bucket_id, name, owner, metadata)
  values ('media', v_path, p_uid, jsonb_build_object('size', p_bytes, 'mimetype', p_mime));
  perform test.ok(public.confirm_upload(v_asset), 'upload confirmed');
  perform test.as_superuser();
  return v_asset;
end $$;

grant execute on all functions in schema test to authenticated, anon, service_role;

-- Save and restore the egress settings around a test that changes them (restoring a
-- hard-coded number would silently leave the database on an outdated default).
create or replace function test.save_egress() returns void language plpgsql as $$
begin
  create temp table if not exists test_saved_egress (budget bigint, per_user bigint);
  delete from test_saved_egress;
  insert into test_saved_egress select daily_egress_budget_bytes, daily_egress_user_bytes from private.platform_config;
end $$;
create or replace function test.restore_egress() returns void language plpgsql as $$
begin
  update private.platform_config c set daily_egress_budget_bytes = s.budget, daily_egress_user_bytes = s.per_user
    from test_saved_egress s;
end $$;
