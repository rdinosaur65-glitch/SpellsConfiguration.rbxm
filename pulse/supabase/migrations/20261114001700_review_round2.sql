-- PULSE 0017 — second review round (verification of 0014-0016 and the media pipeline).
-- Each block names the problem fixed. Highlights:
--  * Storage accounting: bytes stay counted (per user and per pool) until the janitor has
--    really removed the object, so upload→delete churn cannot get around the quotas.
--  * Egress: every authorisation is charged (no free re-fetch window) and media-url now
--    streams the bytes itself, so one authorisation is exactly one download.
--  * Group blocks no longer stop disappearing messages from expiring; expiry decisions are
--    serialised with leaves/removals; removed members lose group Snaps.
--  * Snap sends are de-duplicated and counted; mode-change notices are limited and guarded.

-- The 0007 zero-argument version was left as an overload by 0015.
drop function if exists private.process_account_deletions();

-- Objects of deleted accounts keep their size until the janitor removes them.
alter table private.storage_trash
  add column if not exists pool text,
  add column if not exists byte_size bigint not null default 0;

-- Snap recipient rows carry the sender, so Realtime can filter "my sent Snaps".
alter table public.snap_recipients add column if not exists sender_id uuid;
update public.snap_recipients r set sender_id = s.sender_id from public.snaps s
 where s.id = r.snap_id and r.sender_id is null;
alter table public.snap_recipients alter column sender_id set not null;
create index if not exists snap_recipients_sender on public.snap_recipients (sender_id);

-- The per-user egress share must fit the largest allowed file (50 MB backups).
alter table private.platform_config alter column daily_egress_user_bytes set default 67108864;
update private.platform_config set daily_egress_user_bytes = 67108864 where daily_egress_user_bytes < 67108864;

-- Would charging p_bytes now exceed the caller's share or the platform budget?
create or replace function private.egress_would_exceed(p_bytes bigint)
returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((select egress_bytes from private.usage_daily
                    where user_id = auth.uid() and day = (now() at time zone 'utc')::date), 0) + p_bytes
           > (private.config()).daily_egress_user_bytes
      or coalesce((select bytes from private.egress_daily
                    where day = (now() at time zone 'utc')::date), 0) + p_bytes
           > (private.config()).daily_egress_budget_bytes
$$;
revoke execute on function private.egress_would_exceed(bigint) from public, anon, authenticated;

-- Read receipts: a sender who left the chat (or is blocked) no longer sees new receipts.
drop policy if exists reads_visible on public.message_reads;
create policy reads_visible on public.message_reads for select to authenticated
  using (user_id = (select auth.uid())
         or (sender_id = (select auth.uid())
             and user_id <> all ((select private.my_block_peers())::uuid[])
             and private.can_read_message(message_id, (select auth.uid()))));

-- Pool bytes are released by janitor_mark_deleted, not when deletion is requested.
create or replace function private.request_asset_deletion(p_asset uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare a public.media_assets;
begin
  select * into a from public.media_assets where id = p_asset for update;
  if a.id is null or a.status in ('deleting', 'deleted') then return; end if;
  -- The bytes stay counted against the pool until the janitor has removed the object.
  update public.media_assets set status = 'deleting', delete_requested_at = now() where id = a.id;
end $$;

-- Removing an object releases its pool bytes (assets and deleted accounts' trash).
create or replace function public.janitor_mark_deleted(p_assets uuid[])
returns integer
language plpgsql security definer set search_path = '' as $$
declare v_assets integer; v_trash integer;
begin
  -- Assets: 'deleting' → 'deleted', releasing their bytes from the pool.
  with done as (
    update public.media_assets set status = 'deleted'
     where id = any (p_assets) and status = 'deleting'
    returning private.pool_for(purpose) as pool, byte_size
  ), counted as (
    select count(*) as n from done
  ), freed as (
    select pool, sum(byte_size) as bytes from done group by pool
  ), apply as (
    update private.storage_pools p set bytes_used = greatest(p.bytes_used - f.bytes, 0)
      from freed f where p.pool = f.pool
    returning 1
  )
  select n into v_assets from counted;
  -- Objects of deleted accounts.
  with gone as (
    delete from private.storage_trash where id = any (p_assets) returning pool, byte_size
  ), counted as (
    select count(*) as n from gone
  ), freed as (
    select pool, sum(byte_size) as bytes from gone where pool is not null group by pool
  ), apply as (
    update private.storage_pools p set bytes_used = greatest(p.bytes_used - f.bytes, 0)
      from freed f where p.pool = f.pool
    returning 1
  )
  select n into v_trash from counted;
  return coalesce(v_assets, 0) + coalesce(v_trash, 0);
end $$;

-- Rate-limited (upload/delete churn).
create or replace function public.delete_media_asset(p_asset uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then perform private.fail('not_authenticated'); end if;
  perform private.assert_mfa();
  perform private.rate_limit_hit('delete_media_asset', 60, interval '1 hour');
  if not exists (select 1 from public.media_assets where id = p_asset and owner_id = v_uid) then
    perform private.fail('asset_not_found');
  end if;
  perform private.request_asset_deletion(p_asset);
end $$;

-- Per-user shares and the pending cap count objects until they are really gone.
create or replace function public.authorize_upload(
  p_purpose public.media_purpose, p_mime text, p_bytes bigint, p_sha256 text,
  p_duration numeric default null, p_width integer default null, p_height integer default null)
returns table (asset_id uuid, bucket text, object_path text, deduplicated boolean)
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.assert_active();
  v_cfg private.platform_config := private.config();
  v_pool text := private.pool_for(p_purpose);
  v_existing public.media_assets;
  v_used bigint; v_limit bigint; v_user_used bigint; v_pending integer;
  v_id uuid := gen_random_uuid();
  v_path text;
begin
  perform private.rate_limit_hit('authorize_upload', 120, interval '1 hour');
  perform private.validate_media(p_purpose, p_mime, p_bytes, p_duration);
  if p_sha256 is null or p_sha256 !~ '^[0-9a-f]{64}$' then perform private.fail('invalid_hash'); end if;

  select * into v_existing from public.media_assets m
   where m.owner_id = v_uid and m.purpose = p_purpose and m.content_sha256 = p_sha256
     and m.status in ('pending', 'uploaded');
  if v_existing.id is not null then
    return query select v_existing.id, v_existing.bucket, v_existing.object_path, true;
    return;
  end if;

  perform private.assert_db_headroom();
  perform pg_advisory_xact_lock(hashtext('pulse_user_quota'), hashtext(v_uid::text));
  -- Reservations never confirmed still count while their bytes may exist in Storage.
  select count(*) into v_pending from public.media_assets m
   where m.owner_id = v_uid
     and (m.status = 'pending' or (m.status = 'deleting' and m.uploaded_at is null));
  if v_pending >= v_cfg.max_pending_uploads then perform private.fail('too_many_pending_uploads'); end if;

  select coalesce(sum(m.byte_size), 0) into v_user_used from public.media_assets m
   where m.owner_id = v_uid and private.pool_for(m.purpose) = v_pool
     and m.status in ('pending', 'uploaded', 'deleting');   -- 'deleting': not removed yet
  if v_pool = 'memories' and v_user_used + p_bytes > v_cfg.memories_quota_bytes then
    perform private.fail('memories_quota_full');
  elsif v_pool = 'ephemeral' and v_user_used + p_bytes > v_cfg.ephemeral_user_quota_bytes then
    perform private.fail('media_quota_full');
  elsif v_pool = 'profile' and v_user_used + p_bytes > v_cfg.profile_user_quota_bytes then
    perform private.fail('media_quota_full');
  end if;

  select bytes_used, bytes_limit into v_used, v_limit
    from private.storage_pools where pool = v_pool for update;
  if v_used + p_bytes > (case when v_pool = 'memories' then v_limit * 0.9 else v_limit end) then
    perform private.fail('storage_pool_full', v_pool);
  end if;

  v_path := v_uid::text || '/' || p_purpose::text || '/' || v_id::text;
  insert into public.media_assets (id, owner_id, purpose, object_path, mime_type, byte_size,
                                   content_sha256, duration_seconds, width, height)
  values (v_id, v_uid, p_purpose, v_path, p_mime, p_bytes, p_sha256, p_duration, p_width, p_height);
  update private.storage_pools set bytes_used = bytes_used + p_bytes where pool = v_pool;
  return query select v_id, 'media'::text, v_path, false;
end $$;

-- No free re-fetch window (with reusable URLs it allowed unlimited downloads).
create or replace function private.charge_egress_for(p_asset uuid, p_bytes bigint)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_user bigint;
begin
  -- Every authorisation is charged: media-url streams exactly one copy per call.
  insert into private.usage_daily as u (user_id, day, egress_bytes)
  values (v_uid, (now() at time zone 'utc')::date, p_bytes)
  on conflict (user_id, day) do update set egress_bytes = u.egress_bytes + excluded.egress_bytes
  returning egress_bytes into v_user;
  if v_user > (private.config()).daily_egress_user_bytes then
    perform private.fail('egress_quota_exceeded');
  end if;
  perform private.charge_egress(p_bytes);
end $$;

-- Members with a block towards the sender no longer hold back expiry; serialised.
create or replace function private.apply_expiry(p_conv uuid)
returns integer
language plpgsql security definer set search_path = '' as $$
declare v_n integer; v_grace interval := (private.config()).after_view_grace;
begin
  -- Serialised with readers and with membership changes of this chat, so a read racing a
  -- leave/removal/suspension cannot leave a message waiting for ever.
  perform pg_advisory_xact_lock(hashtext('pulse_conv_read'), hashtext(p_conv::text));
  update public.messages m
     set expires_at = case m.expiry_mode
           when 'after_view' then now() + v_grace
           when 'after_view_24h' then now() + interval '24 hours'
           when 'after_view_7d' then now() + interval '7 days' end
   where m.conversation_id = p_conv
     and m.expires_at is null and m.deleted_at is null
     and m.expiry_mode <> 'never' and m.kind <> 'snap'
     and exists (select 1 from public.message_reads r where r.message_id = m.id)
     and not exists (
       select 1 from public.conversation_members o
       join public.profiles p on p.id = o.user_id and p.account_state = 'active'
       where o.conversation_id = m.conversation_id and o.left_at is null
         and o.user_id <> m.sender_id and o.joined_at <= m.created_at
         and not private.is_blocked_either(o.user_id, m.sender_id)   -- they can never read it
         and not exists (select 1 from public.message_reads r
                         where r.message_id = m.id and r.user_id = o.user_id));
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- Leaving or removal also ends access to the group's Snaps.
create or replace function private.detach_member(p_conv uuid, p_user uuid)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.conversation_members set left_at = now(), pinned_rank = null, role = 'member'
   where conversation_id = p_conv and user_id = p_user and left_at is null;
  delete from public.saved_messages s using public.messages m
   where m.id = s.message_id and m.conversation_id = p_conv and s.user_id = p_user;
  delete from public.message_reactions where conversation_id = p_conv and user_id = p_user;
  -- Snaps sent to the group while they were in it are no longer theirs to open.
  update public.snap_recipients set status = 'expired', expired_at = now(), session_id = null, session_deadline = null
   where conversation_id = p_conv and recipient_id = p_user and status <> 'expired';
  perform private.release_snap_media_if_dead(r.snap_id)
     from public.snap_recipients r where r.conversation_id = p_conv and r.recipient_id = p_user;
  perform private.apply_expiry(p_conv);
end $$;

-- Mode-change notices are capped per day, counted as messages and stop at the DB-size guard.
create or replace function public.set_chat_expiry(p_conv uuid, p_mode public.expiry_mode)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_role public.member_role; c public.conversations;
begin
  perform private.rate_limit_hit('set_chat_expiry', 10, interval '1 minute');
  perform private.rate_limit_hit('set_chat_expiry_day', 30, interval '1 day');
  perform private.assert_can_post(p_conv, v_uid);
  select * into c from public.conversations where id = p_conv for update;
  v_role := private.member_role(p_conv, v_uid);
  if c.kind = 'group' and v_role = 'member' then perform private.fail('not_allowed'); end if;
  if c.expiry_mode = p_mode then return; end if;
  perform private.assert_db_headroom();
  perform private.rate_limit_hit('send_message_day', 2000, interval '1 day');   -- the notice is a message
  update public.conversations set expiry_mode = p_mode, last_message_at = now() where id = p_conv;
  insert into public.messages (conversation_id, sender_id, kind, body, client_msg_id, expiry_mode)
  values (p_conv, v_uid, 'system', 'expiry_mode:' || p_mode::text, gen_random_uuid(), p_mode);
end $$;

-- De-duplicated recipients/groups; every Snap message counts toward the daily message cap.
create or replace function public.send_snap(
  p_media_asset uuid, p_recipients uuid[], p_groups uuid[], p_view_seconds smallint,
  p_allow_saving boolean, p_client_id uuid)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.assert_active();
  a public.media_assets;
  v_snap uuid; v_kind text; r uuid; g uuid; v_conv uuid; v_count integer := 0;
  v_peers uuid[] := private.my_block_peers();
begin
  if p_client_id is null then perform private.fail('client_id_required'); end if;
  select id into v_snap from public.snaps where sender_id = v_uid and client_id = p_client_id;
  if v_snap is not null then return v_snap; end if;

  perform private.rate_limit_hit('send_snap', 60, interval '1 hour');
  perform private.assert_db_headroom();
  select * into a from public.media_assets where id = p_media_asset;
  if a.id is null or a.owner_id <> v_uid or a.purpose <> 'snap' or a.status <> 'uploaded' then
    perform private.fail('invalid_media');
  end if;
  v_kind := case when a.mime_type like 'video/%' then 'video' else 'photo' end;
  if v_kind = 'photo' and p_view_seconds is not null and p_view_seconds not between 1 and 10 then
    perform private.fail('invalid_view_seconds');
  end if;
  -- Each person and each group at most once (repeats used to write one message each).
  p_recipients := array(select distinct x from unnest(coalesce(p_recipients, '{}')) x where x is not null);
  p_groups := array(select distinct x from unnest(coalesce(p_groups, '{}')) x where x is not null);
  if coalesce(array_length(p_recipients, 1), 0) + coalesce(array_length(p_groups, 1), 0) > 50 then
    perform private.fail('too_many_recipients');
  end if;

  insert into public.snaps (sender_id, media_asset_id, media_kind, view_seconds, video_seconds,
                            allow_saving, client_id, expires_at)
  values (v_uid, a.id, v_kind, case when v_kind = 'photo' then p_view_seconds end,
          case when v_kind = 'video' then a.duration_seconds end,
          coalesce(p_allow_saving, false), p_client_id, now() + (private.config()).unopened_snap_ttl)
  on conflict (sender_id, client_id) do nothing
  returning id into v_snap;
  if v_snap is null then
    select id into v_snap from public.snaps where sender_id = v_uid and client_id = p_client_id;
    return v_snap;
  end if;

  foreach r in array coalesce(p_recipients, '{}') loop
    if r = v_uid then continue; end if;
    if not private.are_friends(v_uid, r) then perform private.fail('not_friends', r::text); end if;
    perform private.assert_can_interact(v_uid, r);
    v_conv := private.ensure_direct_conversation(v_uid, r);
    insert into public.snap_recipients (snap_id, recipient_id, conversation_id, sender_id)
    values (v_snap, r, v_conv, v_uid) on conflict do nothing;
    perform private.rate_limit_hit('send_message_day', 2000, interval '1 day');
    insert into public.messages (conversation_id, sender_id, kind, snap_id, client_msg_id, expiry_mode)
    values (v_conv, v_uid, 'snap', v_snap, gen_random_uuid(), 'never');
    update public.conversations set last_message_at = now() where id = v_conv;
    v_count := v_count + 1;
  end loop;

  foreach g in array coalesce(p_groups, '{}') loop
    if not private.is_member(g, v_uid)
       or (select kind from public.conversations where id = g) <> 'group' then
      perform private.fail('not_a_member', g::text);
    end if;
    perform private.rate_limit_hit('send_message_day', 2000, interval '1 day');
    insert into public.snap_recipients (snap_id, recipient_id, conversation_id, sender_id)
    select v_snap, cm.user_id, g, v_uid from public.conversation_members cm
     where cm.conversation_id = g and cm.left_at is null and cm.user_id <> v_uid
       and cm.user_id <> all (v_peers)
    on conflict do nothing;
    insert into public.messages (conversation_id, sender_id, kind, snap_id, client_msg_id, expiry_mode)
    values (g, v_uid, 'snap', v_snap, gen_random_uuid(), 'never');
    update public.conversations set last_message_at = now() where id = g;
    v_count := v_count + 1;
  end loop;

  if v_count = 0 then perform private.fail('no_recipients'); end if;
  return v_snap;
end $$;

-- Only current members can open; the egress share is checked before a view is used.
create or replace function public.open_snap(p_snap uuid)
returns table (session_id uuid, view_number smallint, deadline timestamptz,
               view_seconds smallint, unlimited boolean, allow_saving boolean)
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.assert_active();
  s public.snaps;
  r public.snap_recipients;
  v_len interval;
  v_session uuid := gen_random_uuid();
begin
  perform private.rate_limit_hit('open_snap', 120, interval '1 minute');
  select * into r from public.snap_recipients
   where snap_id = p_snap and recipient_id = v_uid for update;
  if r.snap_id is null then perform private.fail('snap_not_found'); end if;
  select * into s from public.snaps where id = p_snap;
  if private.is_blocked_either(v_uid, s.sender_id) then perform private.fail('snap_not_found'); end if;
  if not private.is_member(r.conversation_id, v_uid) then perform private.fail('snap_not_found'); end if;
  if not exists (select 1 from public.messages m where m.snap_id = p_snap
                 and m.conversation_id = r.conversation_id and m.deleted_at is null) then
    perform private.fail('snap_expired');
  end if;
  if r.status = 'expired' or s.expires_at <= now() or s.media_asset_id is null
     or not exists (select 1 from public.media_assets a where a.id = s.media_asset_id and a.status = 'uploaded') then
    perform private.fail('snap_expired');
  end if;
  if private.snap_session_live(r) then perform private.fail('session_active'); end if;
  if r.views_used >= 2 then perform private.fail('snap_expired'); end if;
  -- Do not use up a view that the egress limits would then refuse to show.
  if private.egress_would_exceed((select byte_size from public.media_assets where id = s.media_asset_id)) then
    perform private.fail('egress_quota_exceeded');
  end if;

  v_len := case
    when s.media_kind = 'video' then make_interval(secs => s.video_seconds::double precision + 3)
    when s.view_seconds is null then (private.config()).unlimited_view_max
    else make_interval(secs => s.view_seconds + 2) end;

  update public.snap_recipients
     set views_used = r.views_used + 1,
         status = case when r.views_used = 0 then 'opened'::public.snap_status else 'replayed' end,
         opened_at = coalesce(r.opened_at, now()),
         session_id = v_session, session_started_at = now(), session_deadline = now() + v_len
   where snap_id = r.snap_id and recipient_id = v_uid;

  return query select v_session, (r.views_used + 1)::smallint, now() + v_len, s.view_seconds,
                      (s.media_kind = 'photo' and s.view_seconds is null), s.allow_saving;
end $$;

-- Only current members get Snap bytes.
create or replace function public.authorize_snap_media(p_snap uuid, p_session uuid)
returns table (bucket text, object_path text, mime_type text, valid_seconds integer)
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); r public.snap_recipients; a public.media_assets;
        v_sender uuid;
begin
  perform private.rate_limit_hit('authorize_snap_media', 30, interval '1 minute');
  select * into r from public.snap_recipients where snap_id = p_snap and recipient_id = v_uid;
  select sender_id into v_sender from public.snaps where id = p_snap;
  if r.snap_id is null or r.session_id is distinct from p_session
     or not private.snap_session_live(r) or r.status = 'expired'
     or private.is_blocked_either(v_uid, v_sender)
     or not private.is_member(r.conversation_id, v_uid) then
    perform private.fail('snap_session_invalid');
  end if;
  select m.* into a from public.snaps s join public.media_assets m on m.id = s.media_asset_id
   where s.id = p_snap and m.status = 'uploaded';
  if a.id is null then perform private.fail('snap_expired'); end if;
  perform private.charge_egress_for(a.id, a.byte_size);
  return query select a.bucket, a.object_path, a.mime_type,
    least(60, greatest(1, ceil(extract(epoch from r.session_deadline - now()))::integer));
end $$;

-- Only current members can save; rate-limited.
create or replace function public.save_snap(p_snap uuid, p_session uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); r public.snap_recipients; s public.snaps;
begin
  select * into r from public.snap_recipients
   where snap_id = p_snap and recipient_id = v_uid for update;
  select * into s from public.snaps where id = p_snap;
  perform private.rate_limit_hit('save_snap', 60, interval '1 minute');
  if r.snap_id is null or private.is_blocked_either(v_uid, s.sender_id)
     or not private.is_member(r.conversation_id, v_uid) then
    perform private.fail('snap_not_found');
  end if;
  if not coalesce(s.allow_saving, false) then perform private.fail('saving_not_permitted'); end if;
  if r.session_id is distinct from p_session or not private.snap_session_live(r) then
    perform private.fail('snap_session_invalid');
  end if;
  update public.snap_recipients set saved_at = coalesce(saved_at, now())
   where snap_id = p_snap and recipient_id = v_uid;
end $$;

-- Rate-limited.
create or replace function public.delete_message(p_msg uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); m public.messages;
begin
  if v_uid is null then perform private.fail('not_authenticated'); end if;
  perform private.assert_mfa();
  perform private.rate_limit_hit('delete_message', 120, interval '1 minute');
  select * into m from public.messages where id = p_msg for update;
  if m.id is null or m.sender_id <> v_uid or m.deleted_at is not null or m.kind = 'system' then
    perform private.fail('message_not_found');
  end if;
  update public.messages set deleted_at = now(), body = null, media_asset_id = null where id = m.id;
  delete from public.message_reactions where message_id = m.id;
  delete from public.saved_messages where message_id = m.id;
  delete from private.message_edits where message_id = m.id;
  if m.kind = 'snap' and m.snap_id is not null then
    update public.snap_recipients
       set status = 'expired', expired_at = now(), session_id = null, session_deadline = null
     where snap_id = m.snap_id and conversation_id = m.conversation_id and status <> 'expired';
    perform private.release_snap_media_if_dead(m.snap_id);
  end if;
  if m.media_asset_id is not null then perform private.release_asset_if_unreferenced(m.media_asset_id); end if;
end $$;

-- Saves are private: 'saved' means saved by me (anyone's save still keeps a message visible).
create or replace function public.search_messages(
  p_query text default null, p_sender uuid default null, p_from timestamptz default null,
  p_to timestamptz default null, p_saved_only boolean default false,
  p_kinds public.message_kind[] default null, p_conv uuid default null, p_limit integer default 50)
returns table (message_id uuid, conversation_id uuid, sender_id uuid, kind public.message_kind,
               body text, created_at timestamptz, saved boolean)
language plpgsql volatile security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_convs uuid[] := private.my_conversation_ids();
        v_peers uuid[] := private.my_block_peers();
begin
  perform private.rate_limit_hit('search_messages', 30, interval '1 minute');
  return query
    select m.id, m.conversation_id, m.sender_id, m.kind, m.body, m.created_at,
           exists (select 1 from public.saved_messages s where s.message_id = m.id and s.user_id = v_uid)
    from public.messages m
    join public.conversation_members cm
      on cm.conversation_id = m.conversation_id and cm.user_id = v_uid and cm.left_at is null
    where m.conversation_id = any (v_convs)
      and m.created_at >= cm.joined_at
      and m.deleted_at is null
      and m.kind not in ('snap', 'system')
      and m.sender_id <> all (v_peers)
      and (m.expires_at is null or m.expires_at > now()
           or exists (select 1 from public.saved_messages s where s.message_id = m.id))
      and (p_conv is null or m.conversation_id = p_conv)
      and (p_query is null or m.body ilike '%' || replace(replace(replace(p_query, '\', '\\'), '%', '\%'), '_', '\_') || '%')
      and (p_sender is null or m.sender_id = p_sender)
      and (p_from is null or m.created_at >= p_from)
      and (p_to is null or m.created_at < p_to)
      and (not p_saved_only or exists (select 1 from public.saved_messages s where s.message_id = m.id and s.user_id = v_uid))
      and (p_kinds is null or m.kind = any (p_kinds))
    order by m.created_at desc
    limit least(greatest(p_limit, 1), 100);
end $$;

-- Saves are private in the gallery too.
create or replace function public.conversation_gallery(p_conv uuid, p_filter text default 'all')
returns table (message_id uuid, kind public.message_kind, media_asset_id uuid, body text,
               created_at timestamptz, saved boolean)
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_peers uuid[] := private.my_block_peers();
        v_joined timestamptz;
begin
  perform private.assert_conv_access(p_conv, v_uid);
  if p_filter not in ('all','photos','videos','voice','links','saved') then
    perform private.fail('invalid_filter');
  end if;
  v_joined := private.member_joined_at(p_conv);
  return query
    select m.id, m.kind, m.media_asset_id, m.body, m.created_at,
           exists (select 1 from public.saved_messages s where s.message_id = m.id and s.user_id = v_uid)
    from public.messages m
    where m.conversation_id = p_conv and m.created_at >= v_joined
      and m.deleted_at is null and m.kind not in ('snap', 'system')
      and m.sender_id <> all (v_peers)
      and (m.expires_at is null or m.expires_at > now()
           or exists (select 1 from public.saved_messages s where s.message_id = m.id))
      and ((p_filter = 'all' and (m.media_asset_id is not null or m.body ~* 'https?://'))
        or (p_filter = 'photos' and m.kind = 'photo')
        or (p_filter = 'videos' and m.kind = 'video')
        or (p_filter = 'voice' and m.kind = 'voice')
        or (p_filter = 'links' and m.body ~* 'https?://')
        or (p_filter = 'saved' and exists (select 1 from public.saved_messages s where s.message_id = m.id and s.user_id = v_uid)))
    order by m.created_at desc
    limit 100;
end $$;

-- "Opened" does not wait for people with a block (they never see the message).
create or replace function public.chat_list()
returns table (conversation_id uuid, kind public.conversation_kind, title text,
               other_user_id uuid, title_color text, label text, unread boolean,
               last_activity timestamptz, pinned_rank smallint, muted boolean)
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_peers uuid[] := private.my_block_peers();
begin
  return query
  with mine as (
    select cm.conversation_id, cm.pinned_rank, cm.muted_until, cm.joined_at
    from public.conversation_members cm where cm.user_id = v_uid and cm.left_at is null
  ), other_member as (
    select mine.conversation_id, om.user_id
    from mine
    join public.conversations c on c.id = mine.conversation_id and c.kind = 'direct'
    join public.conversation_members om on om.conversation_id = c.id and om.user_id <> v_uid
  ), last_msg as (
    select distinct on (m.conversation_id) m.conversation_id, m.id, m.sender_id, m.kind, m.created_at
    from public.messages m join mine on mine.conversation_id = m.conversation_id
    where m.deleted_at is null and m.created_at >= mine.joined_at and m.kind <> 'system'
      and m.sender_id <> all (v_peers)
      and (m.expires_at is null or m.expires_at > now()
           or exists (select 1 from public.saved_messages s where s.message_id = m.id))
    order by m.conversation_id, m.created_at desc
  ), state as (
    select lm.*,
      (lm.sender_id <> v_uid
        and not exists (select 1 from public.message_reads r where r.message_id = lm.id and r.user_id = v_uid)
        and not (lm.kind = 'snap' and exists (
              select 1 from public.snap_recipients sr join public.messages sm on sm.snap_id = sr.snap_id
              where sm.id = lm.id and sr.recipient_id = v_uid and sr.status <> 'delivered'))) as is_unread
    from last_msg lm
  )
  select c.id, c.kind,
    case when c.kind = 'group' then c.name else coalesce(n.nickname, p.display_name) end,
    om.user_id,
    n.color,
    case
      when st.id is null then 'Start chatting'
      when st.is_unread then case when st.kind = 'snap' then 'New Snap' else 'New Chat' end
      when st.sender_id <> v_uid then 'Received'
      when not exists (
             select 1 from public.conversation_members o
             where o.conversation_id = c.id and o.user_id <> v_uid and o.left_at is null
               and o.joined_at <= st.created_at and o.user_id <> all (v_peers)
               and not exists (select 1 from public.message_reads r
                               where r.message_id = st.id and r.user_id = o.user_id)
               and not exists (select 1 from public.snap_recipients sr
                               join public.messages sm on sm.snap_id = sr.snap_id
                               where sm.id = st.id and sr.recipient_id = o.user_id
                                 and sr.status <> 'delivered'))
        then 'Opened'
      else 'Delivered'
    end,
    coalesce(st.is_unread, false),
    greatest(c.last_message_at, coalesce(st.created_at, c.created_at)),
    mine.pinned_rank,
    coalesce(mine.muted_until > now(), false)
  from mine
  join public.conversations c on c.id = mine.conversation_id
  left join other_member om on om.conversation_id = c.id
  left join public.profiles p on p.id = om.user_id
  left join public.friend_nicknames n on n.owner_id = v_uid and n.friend_id = om.user_id
  left join state st on st.conversation_id = c.id
  where not (c.kind = 'direct' and om.user_id is not null and private.is_blocked_either(v_uid, om.user_id))
  order by mine.pinned_rank nulls last, 8 desc;
end $$;

-- Blocking settles expiry in shared groups and removes saves/reactions between the two.
create or replace function public.block_user(p_target uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active();
begin
  perform private.rate_limit_hit('block_user', 60, interval '1 hour');
  if p_target = v_uid then perform private.fail('invalid_target'); end if;
  if not exists (select 1 from public.profiles where id = p_target) then
    perform private.fail('user_not_found');
  end if;
  perform private.lock_pair(v_uid, p_target);
  insert into public.blocks (blocker_id, blocked_id) values (v_uid, p_target) on conflict do nothing;
  update public.friend_requests
     set status = case when sender_id = v_uid then 'cancelled'::public.friend_request_status
                       else 'declined'::public.friend_request_status end,
         responded_at = now()
   where status = 'pending'
     and ((sender_id = v_uid and recipient_id = p_target)
       or (sender_id = p_target and recipient_id = v_uid));
  delete from public.friendships
   where user_a = least(v_uid, p_target) and user_b = greatest(v_uid, p_target);
  delete from public.friend_nicknames
   where (owner_id = v_uid and friend_id = p_target) or (owner_id = p_target and friend_id = v_uid);
  -- In shared groups: drop saves/reactions between the two on each other's messages, and
  -- let messages that waited for the other person's read start expiring.
  delete from public.saved_messages s using public.messages m
   where m.id = s.message_id
     and ((s.user_id = v_uid and m.sender_id = p_target) or (s.user_id = p_target and m.sender_id = v_uid));
  delete from public.message_reactions x using public.messages m
   where m.id = x.message_id
     and ((x.user_id = v_uid and m.sender_id = p_target) or (x.user_id = p_target and m.sender_id = v_uid));
  perform private.apply_expiry(a.conversation_id)
     from public.conversation_members a
     join public.conversation_members b on b.conversation_id = a.conversation_id
                                       and b.user_id = p_target and b.left_at is null
    where a.user_id = v_uid and a.left_at is null;
  update public.snap_recipients r set session_id = null, session_deadline = null
    from public.snaps s
   where s.id = r.snap_id and r.session_id is not null
     and ((s.sender_id = v_uid and r.recipient_id = p_target)
       or (s.sender_id = p_target and r.recipient_id = v_uid));
end $$;

-- Fallback heir, so a group is never left without an owner.
create or replace function private.transfer_ownership_on_delete(p_user uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare g record; v_heir uuid;
begin
  for g in select conversation_id from public.conversation_members
           where user_id = p_user and role = 'owner' and left_at is null loop
    -- Prefer an active member; otherwise anyone not being deleted (never leave it ownerless).
    select o.user_id into v_heir from public.conversation_members o
      join public.profiles p on p.id = o.user_id and p.account_state <> 'deleting'
     where o.conversation_id = g.conversation_id and o.user_id <> p_user and o.left_at is null
     order by (p.account_state = 'active') desc, (o.role = 'admin') desc, o.joined_at limit 1;
    update public.conversation_members set role = 'member'
     where conversation_id = g.conversation_id and user_id = p_user;
    if v_heir is not null then
      update public.conversation_members set role = 'owner'
       where conversation_id = g.conversation_id and user_id = v_heir;
    end if;
  end loop;
end $$;

-- Trash rows keep pool and size so the janitor releases the right bytes.
create or replace function private.process_account_deletions(p_limit integer default 10)
returns integer
language plpgsql security definer set search_path = '' as $$
declare q record; v_n integer := 0; v_conv uuid;
        v_reserve interval := (private.config()).username_reservation;
begin
  for q in select * from private.deletion_queue where processed_at is null
           order by requested_at limit p_limit loop
    begin
      perform private.transfer_ownership_on_delete(q.user_id);
      for v_conv in select conversation_id from public.conversation_members
                    where user_id = q.user_id and left_at is null loop
        perform private.detach_member(v_conv, q.user_id);
      end loop;
      insert into private.retired_usernames (username, retired_until)
      select username, now() + v_reserve from public.profiles where id = q.user_id
      union all
      select username, reserved_until from private.username_reservations
       where user_id = q.user_id and reserved_until > now()
      on conflict (username) do update set retired_until = greatest(private.retired_usernames.retired_until,
                                                                    excluded.retired_until);
      perform private.request_asset_deletion(id) from public.media_assets
       where owner_id = q.user_id and status in ('pending', 'uploaded');
      insert into private.storage_trash (id, bucket, object_path, pool, byte_size)
      select id, bucket, object_path, private.pool_for(purpose), byte_size from public.media_assets
       where owner_id = q.user_id and status <> 'deleted'
      on conflict (id) do nothing;
      delete from public.media_assets where owner_id = q.user_id;
      delete from auth.users where id = q.user_id;
      begin
        execute 'delete from auth.audit_log_entries where payload ->> ''actor_id'' = $1' using q.user_id::text;
      exception when others then null;   -- not present in local test clusters
      end;
      update private.deletion_queue set processed_at = now(), last_error = null where user_id = q.user_id;
      v_n := v_n + 1;
    exception when others then
      update private.deletion_queue set attempts = attempts + 1, last_error = left(sqlerrm, 500)
       where user_id = q.user_id;
    end;
  end loop;
  return v_n;
end $$;

-- Maintenance re-checks waiting disappearing messages.
create or replace function private.run_maintenance()
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_cfg private.platform_config := private.config();
  v_out jsonb := '{}'::jsonb;
  v_errors jsonb := '[]'::jsonb;
  v_n integer;
  v_assets uuid[];
begin
  -- 0. Database size for the write guard.
  begin
    v_out := v_out || jsonb_build_object('database_bytes', private.refresh_db_usage());
  exception when others then v_errors := v_errors || jsonb_build_object('step', 'db_usage', 'error', sqlerrm);
  end;

  -- 1. Snap recipients whose views are exhausted (session over) or whose Snap timed out.
  begin
    update public.snap_recipients r set status = 'expired', expired_at = now(),
           session_id = null, session_deadline = null
      from public.snaps s
     where s.id = r.snap_id and r.status <> 'expired'
       and ((r.views_used >= 2 and (r.session_deadline is null or r.session_deadline <= now()))
            or (s.expires_at <= now() and (r.session_deadline is null or r.session_deadline <= now())));
    get diagnostics v_n = row_count;
    v_out := v_out || jsonb_build_object('snap_views_expired', v_n);
  exception when others then v_errors := v_errors || jsonb_build_object('step', 'snap_expiry', 'error', sqlerrm);
  end;

  -- 2. Snaps nobody can still view: release media if unused elsewhere, drop after a day.
  begin
    select count(*) into v_n from (
      select private.release_asset_if_unreferenced(s.media_asset_id)
        from public.snaps s
        join public.media_assets a on a.id = s.media_asset_id and a.status in ('pending', 'uploaded')
       where not exists (select 1 from public.snap_recipients r
                         where r.snap_id = s.id and r.status <> 'expired')) x;
    delete from public.snaps s
     where s.created_at < now() - interval '1 day'
       and not exists (select 1 from public.snap_recipients r
                       where r.snap_id = s.id and r.status <> 'expired');
    v_out := v_out || jsonb_build_object('snaps_released', v_n);
  exception when others then v_errors := v_errors || jsonb_build_object('step', 'snaps', 'error', sqlerrm);
  end;

  -- 3. Expired, unsaved messages, once the report window has passed (batched).
  begin
    with doomed as (
      select m.id from public.messages m
       where m.expires_at <= now() - v_cfg.expired_retention and m.kind <> 'snap'
         and not exists (select 1 from public.saved_messages s where s.message_id = m.id)
       limit 5000
    ), gone as (
      delete from public.messages m using doomed d where m.id = d.id
      returning m.media_asset_id
    )
    select array_agg(distinct media_asset_id) filter (where media_asset_id is not null), count(*)
      into v_assets, v_n from gone;
    perform private.release_asset_if_unreferenced(x) from unnest(coalesce(v_assets, '{}')) x;
    v_out := v_out || jsonb_build_object('messages_purged', v_n);
  exception when others then v_errors := v_errors || jsonb_build_object('step', 'messages', 'error', sqlerrm);
  end;

  -- 4. Deletion tombstones have propagated; remove them after 7 days (batched).
  begin
    delete from public.messages where id in (
      select id from public.messages where deleted_at < now() - interval '7 days' limit 5000);
    get diagnostics v_n = row_count;
    v_out := v_out || jsonb_build_object('tombstones_purged', v_n);
  exception when others then v_errors := v_errors || jsonb_build_object('step', 'tombstones', 'error', sqlerrm);
  end;

  -- 5. Reservations never confirmed (the janitor removes any bytes that did arrive).
  begin
    select count(*) into v_n from (
      select private.request_asset_deletion(id) from public.media_assets
       where status = 'pending' and created_at < now() - v_cfg.pending_upload_ttl limit 1000) x;
    v_out := v_out || jsonb_build_object('abandoned_uploads', v_n);
  exception when others then v_errors := v_errors || jsonb_build_object('step', 'pending', 'error', sqlerrm);
  end;

  -- 6. Uploaded but never attached (or replaced avatars, banners and icons) after a day.
  begin
    select count(*) into v_n from (
      select private.request_asset_deletion(a.id) from public.media_assets a
       where a.status = 'uploaded' and a.uploaded_at < now() - interval '24 hours'
         and a.purpose in ('chat', 'snap', 'story', 'profile', 'group_icon')
         and not private.asset_referenced(a.id)
       limit 1000) x;
    v_out := v_out || jsonb_build_object('unattached_released', v_n);
  exception when others then v_errors := v_errors || jsonb_build_object('step', 'unattached', 'error', sqlerrm);
  end;

  -- 6b. Safety net: re-evaluate chats whose disappearing messages have been read but are
  --     still waiting (e.g. after a membership change that raced a read).
  begin
    select count(*) into v_n from (
      select private.apply_expiry(c.conversation_id)
        from (select distinct m.conversation_id from public.messages m
               where m.expires_at is null and m.deleted_at is null and m.expiry_mode <> 'never'
                 and m.kind <> 'snap' and m.created_at < now() - interval '10 minutes'
                 and exists (select 1 from public.message_reads r where r.message_id = m.id)
               limit 200) c) x;
    v_out := v_out || jsonb_build_object('expiry_rechecked', v_n);
  exception when others then v_errors := v_errors || jsonb_build_object('step', 'expiry_recheck', 'error', sqlerrm);
  end;

  -- 7. Housekeeping.
  begin
    delete from private.rate_limits where window_start < now() - interval '1 day';
    delete from private.username_reservations where reserved_until < now();
    delete from private.retired_usernames where retired_until < now();
    delete from private.egress_daily where day < (now() at time zone 'utc')::date - 90;
    delete from private.usage_daily where day < (now() at time zone 'utc')::date - 7;
    delete from private.egress_recent where charged_at < now() - interval '1 hour';
    delete from public.media_assets where status = 'deleted' and delete_requested_at < now() - interval '7 days';
    update public.profiles set status_text = null, status_expires_at = null
     where status_expires_at < now();
    delete from public.conversations c
     where c.kind = 'group' and c.created_at < now() - interval '1 hour'
       and not exists (select 1 from public.conversation_members m
                       where m.conversation_id = c.id and m.left_at is null);
  exception when others then v_errors := v_errors || jsonb_build_object('step', 'housekeeping', 'error', sqlerrm);
  end;

  -- 8. Account deletions (each account isolated inside).
  begin
    v_out := v_out || jsonb_build_object('accounts_deleted', private.process_account_deletions(10));
  exception when others then v_errors := v_errors || jsonb_build_object('step', 'accounts', 'error', sqlerrm);
  end;

  return v_out || jsonb_build_object('errors', v_errors);
end $$;

revoke execute on all functions in schema private from public, anon;
revoke execute on all functions in schema public from public, anon;
grant execute on function private.caller_active(), private.my_conversation_ids(), private.my_block_peers(),
  private.member_joined_at(uuid), private.is_saved(uuid), private.can_read_message(uuid, uuid),
  private.direct_blocked(uuid), private.can_post(uuid, uuid)
  to authenticated;
