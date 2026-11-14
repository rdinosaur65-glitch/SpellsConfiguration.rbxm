-- PULSE 0004 — media assets, quotas, storage pools, egress budget, private bucket.
--
-- Flow: client compresses media → authorize_upload() reserves quota and returns a path
-- → client uploads to the private "media" bucket (storage policy only accepts paths
-- that match a pending asset of that user) → confirm_upload() verifies the stored size
-- and MIME type. Downloads never use public URLs: the media-url Edge Function calls
-- authorize_media_access() with the viewer's JWT, then signs a 60-second URL.

create type public.media_purpose as enum
  ('snap', 'story', 'chat', 'memory_backup', 'vault_backup', 'profile', 'group_icon');
create type public.media_status as enum ('pending', 'uploaded', 'deleting', 'deleted');

create table public.media_assets (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null references public.profiles(id) on delete cascade,
  purpose public.media_purpose not null,
  bucket text not null default 'media',
  object_path text not null unique,
  mime_type text not null,
  byte_size bigint not null check (byte_size > 0),
  content_sha256 text not null check (content_sha256 ~ '^[0-9a-f]{64}$'),
  duration_seconds numeric(7,2) check (duration_seconds is null or duration_seconds > 0),
  width integer check (width is null or width between 1 and 8192),
  height integer check (height is null or height between 1 and 8192),
  status public.media_status not null default 'pending',
  created_at timestamptz not null default now(),
  uploaded_at timestamptz,
  delete_requested_at timestamptz
);
create unique index media_assets_dedupe on public.media_assets (owner_id, purpose, content_sha256)
  where status in ('pending', 'uploaded');
create index media_assets_owner on public.media_assets (owner_id, purpose) where status = 'uploaded';
create index media_assets_deleting on public.media_assets (delete_requested_at) where status = 'deleting';
create index media_assets_pending on public.media_assets (created_at) where status = 'pending';

alter table public.media_assets enable row level security;
revoke all on public.media_assets from anon, authenticated;
grant select on public.media_assets to authenticated;
create policy media_owner_select on public.media_assets for select to authenticated
  using (owner_id = auth.uid());

-- ---------------------------------------------------------------------------
-- Upload rules per purpose (documented limits; see docs/INFRASTRUCTURE_ZERO_COST.md)
-- ---------------------------------------------------------------------------
create or replace function private.pool_for(p public.media_purpose)
returns text language sql immutable as $$
  select case
    when p in ('snap','story','chat') then 'ephemeral'
    when p in ('memory_backup','vault_backup') then 'memories'
    else 'profile' end
$$;

create or replace function private.validate_media(
  p_purpose public.media_purpose, p_mime text, p_bytes bigint, p_duration numeric)
returns void
language plpgsql immutable as $$
declare
  v_kind text := split_part(p_mime, '/', 1);
  v_max_bytes bigint;
  v_max_duration numeric;
begin
  if p_purpose = 'vault_backup' then
    if p_mime <> 'application/octet-stream' then perform private.fail('invalid_media_type'); end if;
    v_max_bytes := 52428800;
  elsif p_mime in ('image/jpeg', 'image/webp', 'image/png') then
    if p_purpose = 'memory_backup' then v_max_bytes := 10485760; else v_max_bytes := 5242880; end if;
  elsif p_mime in ('video/mp4', 'video/webm') then
    if p_purpose in ('profile','group_icon') then perform private.fail('invalid_media_type'); end if;
    if p_purpose = 'memory_backup' then v_max_bytes := 52428800; v_max_duration := 300;
    else v_max_bytes := 20971520; v_max_duration := 60; end if;
  elsif p_mime in ('audio/webm', 'audio/mp4', 'audio/ogg') then
    if p_purpose not in ('chat') then perform private.fail('invalid_media_type'); end if;
    v_max_bytes := 3145728; v_max_duration := 300;
  else
    perform private.fail('invalid_media_type');
  end if;

  if p_bytes is null or p_bytes <= 0 or p_bytes > v_max_bytes then
    perform private.fail('media_too_large', v_max_bytes::text);
  end if;
  if v_kind in ('video', 'audio') then
    if p_duration is null or p_duration <= 0 then perform private.fail('duration_required'); end if;
    if p_duration > v_max_duration then perform private.fail('media_too_long', v_max_duration::text); end if;
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- authorize_upload: validate, deduplicate, enforce user quota and pool ceilings.
-- ---------------------------------------------------------------------------
create or replace function public.authorize_upload(
  p_purpose public.media_purpose,
  p_mime text,
  p_bytes bigint,
  p_sha256 text,
  p_duration numeric default null,
  p_width integer default null,
  p_height integer default null)
returns table (asset_id uuid, bucket text, object_path text, deduplicated boolean)
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.assert_active();
  v_cfg private.platform_config := private.config();
  v_pool text := private.pool_for(p_purpose);
  v_existing public.media_assets;
  v_used bigint;
  v_limit bigint;
  v_user_used bigint;
  v_id uuid := gen_random_uuid();
  v_path text;
begin
  perform private.rate_limit_hit('authorize_upload', 120, interval '1 hour');
  perform private.validate_media(p_purpose, p_mime, p_bytes, p_duration);
  if p_sha256 is null or p_sha256 !~ '^[0-9a-f]{64}$' then perform private.fail('invalid_hash'); end if;

  -- Duplicate-upload prevention (retries, re-sends of the same file).
  select * into v_existing from public.media_assets m
   where m.owner_id = v_uid and m.purpose = p_purpose and m.content_sha256 = p_sha256
     and m.status in ('pending', 'uploaded');
  if v_existing.id is not null then
    return query select v_existing.id, v_existing.bucket, v_existing.object_path, true;
    return;
  end if;

  -- Lock the pool row: concurrent uploads cannot jointly exceed the ceiling.
  select bytes_used, bytes_limit into v_used, v_limit
    from private.storage_pools where pool = v_pool for update;
  if v_used + p_bytes > v_limit then
    perform private.fail('storage_pool_full', v_pool);
  end if;

  if v_pool = 'memories' then
    perform pg_advisory_xact_lock(hashtext('pulse_user_quota'), hashtext(v_uid::text));
    select coalesce(sum(m.byte_size), 0) into v_user_used from public.media_assets m
     where m.owner_id = v_uid and m.purpose in ('memory_backup','vault_backup')
       and m.status in ('pending','uploaded');
    if v_user_used + p_bytes > v_cfg.memories_quota_bytes then
      perform private.fail('memories_quota_full');
    end if;
  end if;

  v_path := v_uid::text || '/' || p_purpose::text || '/' || v_id::text;
  insert into public.media_assets (id, owner_id, purpose, object_path, mime_type, byte_size,
                                   content_sha256, duration_seconds, width, height)
  values (v_id, v_uid, p_purpose, v_path, p_mime, p_bytes, p_sha256, p_duration, p_width, p_height);
  update private.storage_pools set bytes_used = bytes_used + p_bytes where pool = v_pool;

  return query select v_id, 'media'::text, v_path, false;
end $$;

-- confirm_upload: the stored object must exist and match the declared size and type.
-- Returns true when accepted; false when rejected (the asset is then queued for deletion
-- and its quota released — returned rather than raised so the cleanup is not rolled back).
create or replace function public.confirm_upload(p_asset uuid)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.assert_active();
  a public.media_assets;
  o storage.objects;
  v_size bigint;
begin
  select * into a from public.media_assets where id = p_asset for update;
  if a.id is null or a.owner_id <> v_uid then perform private.fail('asset_not_found'); end if;
  if a.status = 'uploaded' then return true; end if;       -- idempotent
  if a.status <> 'pending' then perform private.fail('asset_not_pending'); end if;

  select * into o from storage.objects where bucket_id = a.bucket and name = a.object_path;
  if o.id is null then perform private.fail('upload_missing'); end if;
  v_size := nullif(o.metadata ->> 'size', '')::bigint;
  if v_size is null or v_size > a.byte_size
     or coalesce(o.metadata ->> 'mimetype', '') <> a.mime_type then
    perform private.request_asset_deletion(a.id);
    return false;
  end if;

  -- Re-account with the real size (never more than reserved).
  update private.storage_pools set bytes_used = bytes_used - (a.byte_size - v_size)
   where pool = private.pool_for(a.purpose);
  update public.media_assets set status = 'uploaded', uploaded_at = now(), byte_size = v_size
   where id = a.id;
  return true;
end $$;

-- Mark an asset for deletion and release its quota. Object removal is performed by
-- the storage-janitor Edge Function (Supabase requires the Storage API for deletes).
create or replace function private.request_asset_deletion(p_asset uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare a public.media_assets;
begin
  select * into a from public.media_assets where id = p_asset for update;
  if a.id is null or a.status in ('deleting', 'deleted') then return; end if;
  update public.media_assets set status = 'deleting', delete_requested_at = now() where id = a.id;
  update private.storage_pools set bytes_used = greatest(bytes_used - a.byte_size, 0)
   where pool = private.pool_for(a.purpose);
end $$;

create or replace function public.delete_media_asset(p_asset uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then perform private.fail('not_authenticated'); end if;
  if not exists (select 1 from public.media_assets where id = p_asset and owner_id = v_uid) then
    perform private.fail('asset_not_found');
  end if;
  perform private.request_asset_deletion(p_asset);
end $$;

-- Egress accounting; refuses when today's free-tier budget is spent.
create or replace function private.charge_egress(p_bytes bigint)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_total bigint; v_budget bigint := (private.config()).daily_egress_budget_bytes;
begin
  insert into private.egress_daily as e (day, bytes) values ((now() at time zone 'utc')::date, p_bytes)
  on conflict (day) do update set bytes = e.bytes + excluded.bytes
  returning bytes into v_total;
  if v_total > v_budget then
    perform private.fail('egress_budget_exhausted');
  end if;
end $$;

-- Storage-usage summary for the signed-in user (Memories meter: 80/90/100% warnings).
create or replace function public.my_storage_usage()
returns table (memories_bytes_used bigint, memories_quota_bytes bigint, percent numeric,
               pool_full boolean)
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_quota bigint := (private.config()).memories_quota_bytes;
begin
  return query
    select u.used, v_quota, round(100.0 * u.used / v_quota, 1),
           (select bytes_used >= bytes_limit * 0.9 from private.storage_pools where pool = 'memories')
    from (select coalesce(sum(byte_size), 0)::bigint as used from public.media_assets
          where owner_id = v_uid and purpose in ('memory_backup','vault_backup')
            and status in ('pending','uploaded')) u;
end $$;

grant execute on function
  public.authorize_upload(public.media_purpose, text, bigint, text, numeric, integer, integer),
  public.confirm_upload(uuid), public.delete_media_asset(uuid), public.my_storage_usage()
  to authenticated;

-- ---------------------------------------------------------------------------
-- Private bucket + storage policies
-- ---------------------------------------------------------------------------
insert into storage.buckets (id, name, public, file_size_limit, allowed_mime_types)
values ('media', 'media', false, 52428800,
        array['image/jpeg','image/webp','image/png','video/mp4','video/webm',
              'audio/webm','audio/mp4','audio/ogg','application/octet-stream'])
on conflict (id) do update set public = false, file_size_limit = excluded.file_size_limit,
  allowed_mime_types = excluded.allowed_mime_types;

-- Upload only into a path reserved by authorize_upload() for this user.
create policy media_insert_reserved on storage.objects for insert to authenticated
  with check (
    bucket_id = 'media'
    and (storage.foldername(name))[1] = auth.uid()::text
    and exists (select 1 from public.media_assets m
                where m.object_path = name and m.owner_id = auth.uid() and m.status = 'pending')
  );
-- Owners may read their own objects directly; everyone else goes through media-url.
create policy media_owner_read on storage.objects for select to authenticated
  using (bucket_id = 'media' and (storage.foldername(name))[1] = auth.uid()::text);
-- No client UPDATE or DELETE policies: objects are immutable; deletion is server-side.
