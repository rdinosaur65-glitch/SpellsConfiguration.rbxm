-- PULSE 0014 — hardening from the multi-agent review (schema, guards, indexes, RLS).
-- RPC rewrites that use these pieces are in 0015.
--
-- Highlights:
--  * Database-size guard (refuse text writes above 90% of the 500 MB budget) and a
--    per-user daily text quota, so one account cannot fill the free database.
--  * Per-user egress share, and no double charge for re-fetching the same asset.
--  * Indexes for every foreign key with an ON DELETE action (purges were quadratic).
--  * RLS rewritten around an indexable "my conversations" predicate; direct_blocked()
--    is O(1). Co-members no longer see each other's member rows, saves or read times.
--  * Restrictive "active_gate": banned, suspended and deleting accounts lose table,
--    Storage and Realtime access at once, not when their JWT expires.
--  * Storage: uploads must match the reserved size and type; no owner read policy
--    (downloads always go through media-url, which charges egress and signs ≤60 s).
--  * Realtime no longer publishes DELETE events (they bypass RLS).

-- ---------------------------------------------------------------------------
-- Configuration
-- ---------------------------------------------------------------------------
alter table private.platform_config
  add column if not exists database_budget_bytes bigint not null default 524288000,
  add column if not exists db_write_threshold numeric not null default 0.9
    check (db_write_threshold > 0 and db_write_threshold <= 1),
  add column if not exists daily_text_bytes_per_user bigint not null default 2097152,
  add column if not exists daily_egress_user_bytes bigint not null default 41943040,
  add column if not exists ephemeral_user_quota_bytes bigint not null default 52428800,
  add column if not exists profile_user_quota_bytes bigint not null default 15728640,
  add column if not exists max_pending_uploads integer not null default 5,
  add column if not exists pending_upload_ttl interval not null default interval '15 minutes',
  add column if not exists after_view_grace interval not null default interval '5 minutes',
  add column if not exists expired_retention interval not null default interval '1 hour',
  add column if not exists unconfirmed_signup_ttl interval not null default interval '6 hours',
  add column if not exists max_edits_per_message integer not null default 5;

-- ---------------------------------------------------------------------------
-- Usage accounting tables (private; never exposed)
-- ---------------------------------------------------------------------------
create table if not exists private.platform_usage (
  id boolean primary key default true check (id),
  db_bytes bigint not null,
  measured_at timestamptz not null
);

create table if not exists private.usage_daily (
  user_id uuid not null,
  day date not null,
  text_bytes bigint not null default 0,
  egress_bytes bigint not null default 0,
  primary key (user_id, day)
);

create table if not exists private.egress_recent (
  user_id uuid not null,
  asset_id uuid not null,
  charged_at timestamptz not null default now(),
  primary key (user_id, asset_id)
);

-- Objects of deleted accounts, drained by the storage-janitor (the media_assets rows
-- are gone by then, so the account can be hard-deleted without waiting for Storage).
create table if not exists private.storage_trash (
  id uuid primary key,
  bucket text not null,
  object_path text not null,
  queued_at timestamptz not null default now()
);

-- Usernames of deleted accounts stay unavailable for a while (no impersonation).
create table if not exists private.retired_usernames (
  username extensions.citext primary key,
  retired_until timestamptz not null
);

alter table private.deletion_queue
  add column if not exists attempts integer not null default 0,
  add column if not exists last_error text;

-- ---------------------------------------------------------------------------
-- Guards
-- ---------------------------------------------------------------------------
create or replace function private.refresh_db_usage()
returns bigint
language sql security definer set search_path = '' as $$
  insert into private.platform_usage (id, db_bytes, measured_at)
  values (true, pg_database_size(current_database()), now())
  on conflict (id) do update set db_bytes = excluded.db_bytes, measured_at = excluded.measured_at
  returning db_bytes
$$;

-- Refuses new text/metadata writes once the database passes the configured share of
-- its budget. The size is cached (refreshed by maintenance, or here when stale).
create or replace function private.assert_db_headroom()
returns void
language plpgsql security definer set search_path = '' as $$
declare v_cfg private.platform_config := private.config(); v_bytes bigint; v_at timestamptz;
begin
  select db_bytes, measured_at into v_bytes, v_at from private.platform_usage where id;
  if v_at is null or v_at < now() - interval '10 minutes' then
    v_bytes := private.refresh_db_usage();
  end if;
  if v_bytes > v_cfg.database_budget_bytes * v_cfg.db_write_threshold then
    perform private.fail('storage_full');
  end if;
end $$;

create or replace function private.charge_text(p_bytes bigint)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_total bigint;
begin
  if coalesce(p_bytes, 0) <= 0 then return; end if;
  insert into private.usage_daily as u (user_id, day, text_bytes)
  values (auth.uid(), (now() at time zone 'utc')::date, p_bytes)
  on conflict (user_id, day) do update set text_bytes = u.text_bytes + excluded.text_bytes
  returning text_bytes into v_total;
  if v_total > (private.config()).daily_text_bytes_per_user then
    perform private.fail('text_quota_exceeded');
  end if;
end $$;

-- Per-user share of the daily egress budget; re-fetching the same asset within ten
-- minutes (cache miss, replay) is not charged again.
create or replace function private.charge_egress_for(p_asset uuid, p_bytes bigint)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_last timestamptz; v_user bigint;
begin
  select charged_at into v_last from private.egress_recent where user_id = v_uid and asset_id = p_asset;
  if v_last is not null and v_last > now() - interval '10 minutes' then return; end if;
  insert into private.usage_daily as u (user_id, day, egress_bytes)
  values (v_uid, (now() at time zone 'utc')::date, p_bytes)
  on conflict (user_id, day) do update set egress_bytes = u.egress_bytes + excluded.egress_bytes
  returning egress_bytes into v_user;
  if v_user > (private.config()).daily_egress_user_bytes then
    perform private.fail('egress_quota_exceeded');
  end if;
  perform private.charge_egress(p_bytes);
  insert into private.egress_recent (user_id, asset_id, charged_at) values (v_uid, p_asset, now())
  on conflict (user_id, asset_id) do update set charged_at = excluded.charged_at;
end $$;

-- Serialises friend-request, friendship and block changes for one pair of users.
create or replace function private.lock_pair(p_a uuid, p_b uuid)
returns void
language sql as $$
  select pg_advisory_xact_lock(hashtext('pulse_pair'),
                               hashtext(least(p_a, p_b)::text || greatest(p_a, p_b)::text))
$$;

create or replace function private.caller_active()
returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.profiles where id = auth.uid() and account_state = 'active')
$$;

-- ---------------------------------------------------------------------------
-- Conversation helpers (all O(1) per call, or once per statement via "(select ...)")
-- ---------------------------------------------------------------------------
create or replace function private.direct_blocked(p_conv uuid)
returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce((
    select private.is_blocked_either(split_part(c.direct_key, ':', 1)::uuid,
                                     split_part(c.direct_key, ':', 2)::uuid)
    from public.conversations c where c.id = p_conv and c.kind = 'direct'), false)
$$;

-- The caller's active conversations, excluding direct chats with a block.
create or replace function private.my_conversation_ids()
returns uuid[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(cm.conversation_id), '{}'::uuid[])
  from public.conversation_members cm
  where cm.user_id = auth.uid() and cm.left_at is null
    and not private.direct_blocked(cm.conversation_id)
$$;

-- Users the caller blocked, and users who blocked the caller.
create or replace function private.my_block_peers()
returns uuid[]
language sql stable security definer set search_path = '' as $$
  select coalesce(array_agg(x), '{}'::uuid[]) from (
    select blocked_id as x from public.blocks where blocker_id = auth.uid()
    union
    select blocker_id from public.blocks where blocked_id = auth.uid()) s
$$;

create or replace function private.member_joined_at(p_conv uuid)
returns timestamptz
language sql stable security definer set search_path = '' as $$
  select joined_at from public.conversation_members
   where conversation_id = p_conv and user_id = auth.uid() and left_at is null
$$;

create or replace function private.is_saved(p_msg uuid)
returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.saved_messages where message_id = p_msg)
$$;

create or replace function private.can_read_message(p_msg uuid, p_user uuid)
returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.messages m
    join public.conversation_members cm
      on cm.conversation_id = m.conversation_id and cm.user_id = p_user and cm.left_at is null
    where m.id = p_msg and m.created_at >= cm.joined_at
      and not private.direct_blocked(m.conversation_id)
      and not private.is_blocked_either(p_user, m.sender_id))
$$;

-- Member, not blocked, and (direct chats) still friends with the other person.
create or replace function private.can_post(p_conv uuid, p_user uuid)
returns boolean
language sql stable security definer set search_path = '' as $$
  select private.is_member(p_conv, p_user) and exists (
    select 1 from public.conversations c
    where c.id = p_conv
      and (c.kind = 'group'
           or (not private.is_blocked_either(split_part(c.direct_key, ':', 1)::uuid,
                                             split_part(c.direct_key, ':', 2)::uuid)
               and private.are_friends(split_part(c.direct_key, ':', 1)::uuid,
                                       split_part(c.direct_key, ':', 2)::uuid))))
$$;

create or replace function private.assert_conv_access(p_conv uuid, p_user uuid)
returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.is_member(p_conv, p_user) or private.direct_blocked(p_conv) then
    perform private.fail('not_a_member');
  end if;
end $$;

create or replace function private.assert_can_post(p_conv uuid, p_user uuid)
returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  perform private.assert_conv_access(p_conv, p_user);
  if not private.can_post(p_conv, p_user) then perform private.fail('not_friends'); end if;
end $$;

-- ---------------------------------------------------------------------------
-- Schema changes
-- ---------------------------------------------------------------------------
-- Each message keeps the disappearing mode it was sent under, so toggling the chat's
-- mode later cannot make already-sent disappearing messages permanent.
alter table public.messages add column if not exists expiry_mode public.expiry_mode;
update public.messages m set expiry_mode = case when m.kind = 'snap' then 'never' else c.expiry_mode end
  from public.conversations c where c.id = m.conversation_id and m.expiry_mode is null;
alter table public.messages alter column expiry_mode set not null;

-- Read receipts are visible to the reader and the message's sender only.
alter table public.message_reads add column if not exists sender_id uuid;
update public.message_reads r set sender_id = m.sender_id
  from public.messages m where m.id = r.message_id and r.sender_id is null;
alter table public.message_reads alter column sender_id set not null;

-- Reactions carry their conversation so RLS can use an index; one reaction per user
-- per message (bounded rows).
alter table public.message_reactions add column if not exists conversation_id uuid;
update public.message_reactions x set conversation_id = m.conversation_id
  from public.messages m where m.id = x.message_id and x.conversation_id is null;
alter table public.message_reactions alter column conversation_id set not null;
delete from public.message_reactions x using public.message_reactions y
 where x.message_id = y.message_id and x.user_id = y.user_id
   and (x.created_at, x.emoji) < (y.created_at, y.emoji);
create unique index if not exists reactions_one_per_user on public.message_reactions (message_id, user_id);

alter table public.user_settings
  add constraint user_settings_notifications_shape
  check (jsonb_typeof(notifications) = 'object' and pg_column_size(notifications) <= 1024);

-- Display names may not hide control, zero-width or bidi-override characters.
alter table public.profiles
  add constraint profiles_display_name_visible
  check (display_name !~ '[[:cntrl:]­​-‏‪-‮⁠-⁩﻿]');

-- ---------------------------------------------------------------------------
-- Indexes: every FK with an ON DELETE action, plus the new RLS predicates
-- ---------------------------------------------------------------------------
create index if not exists messages_reply_to on public.messages (reply_to_id) where reply_to_id is not null;
create index if not exists messages_media on public.messages (media_asset_id) where media_asset_id is not null;
create index if not exists messages_pending_expiry on public.messages (conversation_id)
  where expires_at is null and deleted_at is null and expiry_mode <> 'never' and kind <> 'snap';
create index if not exists messages_deleted on public.messages (deleted_at) where deleted_at is not null;
create index if not exists message_reads_user on public.message_reads (user_id);
create index if not exists message_reads_sender on public.message_reads (sender_id);
create index if not exists saved_messages_user on public.saved_messages (user_id);
create index if not exists reactions_user on public.message_reactions (user_id);
create index if not exists reactions_conversation on public.message_reactions (conversation_id);
create index if not exists message_edits_message on private.message_edits (message_id);
create index if not exists username_reservations_user on private.username_reservations (user_id);
create index if not exists members_user on public.conversation_members (user_id);
create index if not exists conversations_created_by on public.conversations (created_by);
create index if not exists conversations_icon on public.conversations (icon_asset_id) where icon_asset_id is not null;
create index if not exists snaps_media on public.snaps (media_asset_id) where media_asset_id is not null;
create index if not exists snap_recipients_conversation on public.snap_recipients (conversation_id);
create index if not exists reports_reporter on public.reports (reporter_id);
create index if not exists reports_target_user on public.reports (target_user_id);
create index if not exists reports_target_message on public.reports (target_message_id);
create index if not exists reports_target_conversation on public.reports (target_conversation_id);
create index if not exists friend_requests_sender on public.friend_requests (sender_id);
create index if not exists friend_requests_recipient_all on public.friend_requests (recipient_id);
create index if not exists friend_nicknames_friend on public.friend_nicknames (friend_id);
create index if not exists media_assets_owner_all on public.media_assets (owner_id);
create index if not exists profiles_avatar on public.profiles (avatar_asset_id) where avatar_asset_id is not null;
create index if not exists profiles_banner on public.profiles (banner_asset_id) where banner_asset_id is not null;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
drop policy if exists conv_member on public.conversations;
create policy conv_member on public.conversations for select to authenticated
  using (id = any ((select private.my_conversation_ids())::uuid[]));

drop policy if exists members_of_my_convs on public.conversation_members;
create policy members_self on public.conversation_members for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists messages_member on public.messages;
create policy messages_member on public.messages for select to authenticated
  using (conversation_id = any ((select private.my_conversation_ids())::uuid[])
         and created_at >= private.member_joined_at(conversation_id)
         and sender_id <> all ((select private.my_block_peers())::uuid[])
         and (deleted_at is not null or expires_at is null or expires_at > now()
              or private.is_saved(id)));

drop policy if exists reads_member on public.message_reads;
create policy reads_visible on public.message_reads for select to authenticated
  using (user_id = (select auth.uid())
         or (sender_id = (select auth.uid()) and user_id <> all ((select private.my_block_peers())::uuid[])));

drop policy if exists saved_member on public.saved_messages;
create policy saved_self on public.saved_messages for select to authenticated
  using (user_id = (select auth.uid()));

drop policy if exists reactions_member on public.message_reactions;
create policy reactions_member on public.message_reactions for select to authenticated
  using (conversation_id = any ((select private.my_conversation_ids())::uuid[])
         and user_id <> all ((select private.my_block_peers())::uuid[])
         and private.can_read_message(message_id, (select auth.uid()))
         and private.message_content_visible(message_id));

drop policy if exists snaps_sender_or_recipient on public.snaps;
create policy snaps_sender_or_recipient on public.snaps for select to authenticated
  using (sender_id = (select auth.uid()) or private.is_snap_recipient(id, (select auth.uid())));
drop policy if exists snap_recipients_visible on public.snap_recipients;
create policy snap_recipients_visible on public.snap_recipients for select to authenticated
  using (recipient_id = (select auth.uid()) or private.is_snap_sender(snap_id, (select auth.uid())));

-- Friends no longer see moderation state; the owner's own state comes from my_profile().
revoke select on public.profiles from authenticated;
grant select (id, username, display_name, avatar_asset_id, banner_asset_id, bio, status_text,
              status_expires_at, profile_theme, username_changed_at, created_at)
  on public.profiles to authenticated;

-- Reporters see the status of their reports, not the evidence snapshot or the note.
revoke select on public.reports from authenticated;
grant select (id, target_type, target_user_id, target_message_id, target_conversation_id,
              reason, details, status, created_at, resolved_at)
  on public.reports to authenticated;

-- Restrictive gate next to mfa_gate on every RLS table in public (test 80 checks it).
do $$
declare t record;
begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity loop
    execute format('drop policy if exists active_gate on public.%I', t.relname);
    execute format('create policy active_gate on public.%I as restrictive for all to authenticated
                    using ((select private.caller_active())) with check ((select private.caller_active()))',
                   t.relname);
  end loop;
end $$;

-- ---------------------------------------------------------------------------
-- Storage: the stored object must match the reservation (checked by the Storage API
-- with the real size and type after the bytes arrive). No client SELECT policy, so
-- clients cannot mint long-lived signed URLs or skip the egress budget.
-- ---------------------------------------------------------------------------
drop policy if exists media_owner_read on storage.objects;
drop policy if exists media_insert_reserved on storage.objects;
create policy media_insert_reserved on storage.objects for insert to authenticated
  with check (
    bucket_id = 'media'
    and (storage.foldername(name))[1] = auth.uid()::text
    and exists (select 1 from public.media_assets m
                where m.object_path = name and m.owner_id = auth.uid() and m.status = 'pending'
                  and (metadata ->> 'size' is null or (metadata ->> 'size')::bigint <= m.byte_size)
                  and (metadata ->> 'mimetype' is null or metadata ->> 'mimetype' = m.mime_type))
  );
drop policy if exists media_active_gate on storage.objects;
create policy media_active_gate on storage.objects as restrictive for all to authenticated
  using (bucket_id <> 'media' or (select private.caller_active()))
  with check (bucket_id <> 'media' or (select private.caller_active()));

-- ---------------------------------------------------------------------------
-- Realtime: DELETE events are not filtered by RLS, so do not publish them. Message
-- deletions already reach clients as tombstone UPDATEs.
-- ---------------------------------------------------------------------------
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime') then
    alter publication supabase_realtime set (publish = 'insert, update');
  end if;
end $$;

-- ---------------------------------------------------------------------------
-- Privileges for helpers that policies call as "authenticated"
-- ---------------------------------------------------------------------------
revoke execute on function
  private.refresh_db_usage(), private.assert_db_headroom(), private.charge_text(bigint),
  private.charge_egress_for(uuid, bigint), private.lock_pair(uuid, uuid), private.caller_active(),
  private.my_conversation_ids(), private.my_block_peers(), private.member_joined_at(uuid),
  private.is_saved(uuid), private.can_post(uuid, uuid), private.assert_conv_access(uuid, uuid),
  private.assert_can_post(uuid, uuid)
  from public, anon;
grant execute on function
  private.caller_active(), private.my_conversation_ids(), private.my_block_peers(),
  private.member_joined_at(uuid), private.is_saved(uuid), private.can_read_message(uuid, uuid),
  private.direct_blocked(uuid), private.can_post(uuid, uuid)
  to authenticated;
