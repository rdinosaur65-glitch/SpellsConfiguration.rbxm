-- PULSE 0029 — app error reports for the owner (free, inside the database).
-- Signed-in clients report uncaught errors (message, short stack, page path, browser),
-- truncated and rate-limited; kept 14 days; readable only by the owner (with 2FA) in the
-- Owner panel. No message text or media is collected on purpose; the client strips query
-- strings from the path.
create table if not exists private.client_errors (
  id bigserial primary key,
  user_id uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  message text not null check (char_length(message) <= 300),
  stack text check (char_length(stack) <= 2000),
  path text check (char_length(path) <= 200),
  user_agent text check (char_length(user_agent) <= 200),
  app_version text check (char_length(app_version) <= 40)
);
create index if not exists client_errors_created on private.client_errors (created_at desc);
create index if not exists client_errors_user on private.client_errors (user_id);

create or replace function public.report_client_error(p_message text, p_stack text, p_path text, p_user_agent text, p_app_version text)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active();
begin
  perform private.rate_limit_hit('report_client_error', 20, interval '1 hour');
  insert into private.client_errors (user_id, message, stack, path, user_agent, app_version)
  values (v_uid, left(coalesce(nullif(btrim(p_message), ''), 'unknown error'), 300), left(p_stack, 2000),
          left(split_part(coalesce(p_path, ''), '?', 1), 200), left(p_user_agent, 200), left(p_app_version, 40));
  delete from private.client_errors where created_at < now() - interval '14 days';
end $$;

create or replace function public.admin_client_errors(p_limit integer default 50)
returns table (id bigint, created_at timestamptz, username text, message text, stack text, path text,
               user_agent text, app_version text)
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.assert_owner();
  return query
    select e.id, e.created_at, p.username::text, e.message, e.stack, e.path, e.user_agent, e.app_version
      from private.client_errors e left join public.profiles p on p.id = e.user_id
     order by e.created_at desc limit greatest(1, least(p_limit, 200));
end $$;

revoke execute on function public.report_client_error(text, text, text, text, text), public.admin_client_errors(integer)
  from public, anon;
grant execute on function public.report_client_error(text, text, text, text, text), public.admin_client_errors(integer)
  to authenticated;
