-- PULSE 0008 — maintenance jobs (expiry, purge, cleanup), storage-janitor contract,
-- Realtime publication and Realtime Authorization for broadcast channels.

create or replace function private.run_maintenance()
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_snaps integer; v_msgs integer; v_orphans integer; v_tomb integer; v_del integer;
begin
  -- 1. Snap recipients whose views are exhausted (session over) or whose Snap timed out.
  update public.snap_recipients r set status = 'expired', expired_at = now(),
         session_id = null, session_deadline = null
    from public.snaps s
   where s.id = r.snap_id and r.status <> 'expired'
     and ((r.views_used >= 2 and (r.session_deadline is null or r.session_deadline <= now()))
          or (s.expires_at <= now() and (r.session_deadline is null or r.session_deadline <= now())));

  -- 2. Snaps no recipient can still view: release media, then drop the Snap after a day.
  with dead as (
    select s.id, s.media_asset_id from public.snaps s
    join public.media_assets a on a.id = s.media_asset_id and a.status in ('pending', 'uploaded')
    where true
      and not exists (select 1 from public.snap_recipients r
                      where r.snap_id = s.id and r.status <> 'expired')
  )
  select count(*) into v_snaps from (
    select private.request_asset_deletion(d.media_asset_id) from dead d
  ) x;
  delete from public.snaps s
   where s.created_at < now() - interval '1 day'
     and not exists (select 1 from public.snap_recipients r
                     where r.snap_id = s.id and r.status <> 'expired');

  -- 3. Expired, unsaved chat messages: delete media and rows (reactions cascade).
  perform private.request_asset_deletion(m.media_asset_id)
     from public.messages m
    where m.expires_at <= now() and m.media_asset_id is not null
      and not exists (select 1 from public.saved_messages s where s.message_id = m.id);
  delete from public.messages m
   where m.expires_at <= now() and m.kind <> 'snap'
     and not exists (select 1 from public.saved_messages s where s.message_id = m.id);
  get diagnostics v_msgs = row_count;

  -- 4. Deletion tombstones have propagated; remove them after 7 days.
  delete from public.messages where deleted_at < now() - interval '7 days';
  get diagnostics v_tomb = row_count;

  -- 5. Abandoned uploads (reserved but never confirmed).
  select count(*) into v_orphans from (
    select private.request_asset_deletion(id) from public.media_assets
     where status = 'pending' and created_at < now() - interval '1 hour') x;

  -- 6. Housekeeping.
  delete from private.rate_limits where window_start < now() - interval '1 day';
  delete from private.username_reservations where reserved_until < now();
  delete from private.egress_daily where day < (now() at time zone 'utc')::date - 90;

  -- 7. Account deletions whose media is gone.
  v_del := private.process_account_deletions();

  return jsonb_build_object('snaps_released', v_snaps, 'messages_purged', v_msgs,
    'tombstones_purged', v_tomb, 'orphans', v_orphans, 'accounts_deleted', v_del);
end $$;

-- ---------------------------------------------------------------------------
-- Storage janitor contract (service_role only — called by the storage-janitor Edge
-- Function, which deletes objects through the Storage API and then confirms here).
-- ---------------------------------------------------------------------------
create or replace function public.janitor_claim_deletions(p_limit integer default 100)
returns table (asset_id uuid, bucket text, object_path text)
language sql security definer set search_path = '' as $$
  select id, bucket, object_path from public.media_assets
   where status = 'deleting' order by delete_requested_at limit least(p_limit, 1000)
$$;

create or replace function public.janitor_mark_deleted(p_assets uuid[])
returns integer
language plpgsql security definer set search_path = '' as $$
declare v_n integer;
begin
  update public.media_assets set status = 'deleted'
   where id = any (p_assets) and status = 'deleting';
  get diagnostics v_n = row_count;
  return v_n;
end $$;

revoke execute on function public.janitor_claim_deletions(integer), public.janitor_mark_deleted(uuid[])
  from public, anon, authenticated;
grant execute on function public.janitor_claim_deletions(integer), public.janitor_mark_deleted(uuid[])
  to service_role;

-- ---------------------------------------------------------------------------
-- Scheduling: pg_cron when available (it is on Supabase; not in local test clusters).
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_available_extensions where name = 'pg_cron') then
    execute 'create extension if not exists pg_cron';
    execute $cron$select cron.schedule('pulse-maintenance', '*/5 * * * *',
                                       'select private.run_maintenance()')$cron$;
  else
    raise notice 'pg_cron not available: schedule private.run_maintenance() externally';
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Realtime: Postgres changes respect RLS for each subscriber.
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime add table
      public.messages, public.message_reactions, public.message_reads,
      public.conversation_members, public.snap_recipients, public.friend_requests;
  end if;
end $$;

-- Realtime Authorization for private broadcast channels (typing, recording, call
-- signalling). Topic format: "conv:<conversation uuid>". Membership required.
create or replace function private.try_uuid(p text)
returns uuid language plpgsql immutable as $$
begin return p::uuid; exception when others then return null; end $$;

create or replace function private.can_use_topic(p_topic text)
returns boolean
language sql stable security definer set search_path = '' as $$
  select p_topic like 'conv:%'
     and private.is_member(private.try_uuid(substr(p_topic, 6)), auth.uid())
     and not private.direct_blocked(private.try_uuid(substr(p_topic, 6)))
     and exists (select 1 from public.profiles where id = auth.uid() and account_state = 'active')
$$;
grant execute on function private.can_use_topic(text) to authenticated;
grant execute on function private.try_uuid(text) to authenticated;

do $$
begin
  if exists (select 1 from information_schema.tables
             where table_schema = 'realtime' and table_name = 'messages') then
    execute $p$create policy pulse_broadcast_read on realtime.messages for select to authenticated
               using (private.can_use_topic(realtime.topic()))$p$;
    execute $p$create policy pulse_broadcast_write on realtime.messages for insert to authenticated
               with check (private.can_use_topic(realtime.topic()))$p$;
  end if;
end $$;
