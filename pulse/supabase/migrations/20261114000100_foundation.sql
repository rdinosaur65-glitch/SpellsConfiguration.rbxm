-- PULSE 0001 — foundation: extensions, private schema, platform config, rate limits.

create extension if not exists citext with schema extensions;
create extension if not exists pgcrypto with schema extensions;

-- Objects in "private" are never exposed through the Supabase Data API.
create schema if not exists private;
revoke all on schema private from public;
grant usage on schema private to authenticated, service_role;  -- needed to call helper fns
-- Tables in private stay inaccessible: no table grants are ever issued to API roles.

-- Remove default execute so every function must be granted explicitly.
alter default privileges in schema public revoke execute on functions from public;
alter default privileges in schema private revoke execute on functions from public;

-- ---------------------------------------------------------------------------
-- Platform configuration (singleton). The owner is identified by immutable UUID.
-- ---------------------------------------------------------------------------
create table private.platform_config (
  id boolean primary key default true check (id),
  owner_user_id uuid,                                   -- set once at deployment
  registration_cap integer not null default 50 check (registration_cap >= 0),
  memories_quota_bytes bigint not null default 52428800,  -- 50 MB per user
  daily_egress_budget_bytes bigint not null default 167772160, -- 160 MB / day
  username_cooldown interval not null default interval '48 hours',
  username_reservation interval not null default interval '30 days',
  message_edit_window interval not null default interval '15 minutes',
  unopened_snap_ttl interval not null default interval '30 days',
  unlimited_view_max interval not null default interval '15 minutes',
  story_ttl interval not null default interval '24 hours',
  updated_at timestamptz not null default now()
);
insert into private.platform_config default values;

create or replace function private.config()
returns private.platform_config
language sql stable security definer set search_path = '' as $$
  select * from private.platform_config where id
$$;

create or replace function private.is_owner(p_user uuid default null)
returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(
    (select owner_user_id from private.platform_config where id) = coalesce(p_user, auth.uid()),
    false)
$$;
grant execute on function private.is_owner(uuid) to authenticated;

-- Exposed variant takes no argument, so it cannot be used to probe who the owner is.
create or replace function public.am_i_owner()
returns boolean language sql stable security definer set search_path = '' as $$
  select private.is_owner(auth.uid())
$$;
grant execute on function public.am_i_owner() to authenticated;

-- ---------------------------------------------------------------------------
-- Error helper: raise a stable, machine-readable error code for the client.
-- ---------------------------------------------------------------------------
create or replace function private.fail(p_code text, p_detail text default null)
returns void language plpgsql as $$
begin
  raise exception using errcode = 'P0001', message = p_code, detail = coalesce(p_detail, '');
end $$;

-- ---------------------------------------------------------------------------
-- Rate limiting (fixed window, per user and action), enforced inside RPCs.
-- ---------------------------------------------------------------------------
create table private.rate_limits (
  user_id uuid not null,
  action text not null,
  window_start timestamptz not null,
  hits integer not null default 0,
  primary key (user_id, action, window_start)
);

create or replace function private.rate_limit_hit(p_action text, p_max integer, p_window interval)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := auth.uid();
  v_start timestamptz;
  v_hits integer;
begin
  if v_uid is null then perform private.fail('not_authenticated'); end if;
  v_start := to_timestamp(floor(extract(epoch from now()) / extract(epoch from p_window))
                          * extract(epoch from p_window));
  insert into private.rate_limits as r (user_id, action, window_start, hits)
  values (v_uid, p_action, v_start, 1)
  on conflict (user_id, action, window_start) do update set hits = r.hits + 1
  returning hits into v_hits;
  if v_hits > p_max then
    perform private.fail('rate_limited', p_action);
  end if;
end $$;

-- Daily egress accounting (bytes of media authorised for download).
create table private.egress_daily (
  day date primary key,
  bytes bigint not null default 0
);

-- Platform storage pools (hard ceilings inside the 1 GB Supabase Free allowance).
create table private.storage_pools (
  pool text primary key check (pool in ('ephemeral','memories','profile')),
  bytes_used bigint not null default 0 check (bytes_used >= 0),
  bytes_limit bigint not null check (bytes_limit > 0)
);
insert into private.storage_pools (pool, bytes_limit) values
  ('ephemeral', 419430400),  -- 400 MB: Snaps, Stories, chat media
  ('memories',  471859200),  -- 450 MB: optional Memories backup (+ Vault ciphertext)
  ('profile',    52428800);  -- 50 MB: avatars, banners, group icons
