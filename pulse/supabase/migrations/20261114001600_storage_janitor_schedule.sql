-- PULSE 0016 — run the storage-janitor Edge Function from the database.
-- pg_cron calls private.invoke_storage_janitor() every 10 minutes; it posts to the
-- function through pg_net with a shared secret, only when there is something to delete.
-- The function URL and the secret live in Supabase Vault (encrypted), set once by the
-- owner (docs/ENVIRONMENT.md):
--   select vault.create_secret('https://<ref>.supabase.co/functions/v1/storage-janitor', 'pulse_janitor_url');
--   select vault.create_secret('<long random string>', 'pulse_janitor_secret');
-- and the same secret for the function:  npx supabase secrets set JANITOR_SECRET=<same string>
-- Until both exist, the job is a no-op.

do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_net') then
    execute 'create extension if not exists pg_net';
  else
    raise notice 'pg_net not available: call the storage-janitor function externally';
  end if;
end $$;

create or replace function private.invoke_storage_janitor()
returns bigint
language plpgsql security definer set search_path = '' as $$
declare v_url text; v_secret text; v_id bigint;
begin
  if to_regclass('vault.decrypted_secrets') is null or to_regproc('net.http_post') is null then
    return null;
  end if;
  if not exists (select 1 from public.media_assets where status = 'deleting')
     and not exists (select 1 from private.storage_trash) then
    return null;   -- nothing to do: no HTTP call, no Edge Function invocation used
  end if;
  execute $q$select decrypted_secret from vault.decrypted_secrets where name = 'pulse_janitor_url'$q$ into v_url;
  execute $q$select decrypted_secret from vault.decrypted_secrets where name = 'pulse_janitor_secret'$q$ into v_secret;
  if v_url is null or v_secret is null then return null; end if;
  execute 'select net.http_post(url := $1, body := $2, headers := $3, timeout_milliseconds := 25000)'
     into v_id
    using v_url, '{}'::jsonb, jsonb_build_object('Content-Type', 'application/json', 'x-janitor-secret', v_secret);
  return v_id;
end $$;

revoke execute on function private.invoke_storage_janitor() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('pulse-storage-janitor', '*/10 * * * *', 'select private.invoke_storage_janitor()');
  end if;
end $$;
