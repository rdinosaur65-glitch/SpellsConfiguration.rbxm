-- PULSE 0033 — fixes from the pre-launch security audit.
--
-- 1. delete_message / delete_media_asset need an ACTIVE account: during the hour a
--    suspended account's last access token stays valid, it can no longer erase what was
--    reported or might be.
-- 2. Profile avatar/banner may only point at the user's own uploaded profile picture
--    (pointing at a Snap kept its bytes alive past expiry).
-- 3. Friend nicknames can only be moved to another friend (update had no friendship check).
-- 4. A blocked sender no longer sees the blocker's Snap delivery/opened state.
-- 5. Presence of suspended or banned friends is not shown (list_friends already hid them).
-- 6. App error reports are purged after 14 days by a daily job, not only when a new one
--    arrives; the owner list shows only that window.
-- 7. A deleted account's username is cleared from the invitation it used.
-- 8. Push subscriptions: keys must be exactly a P-256 key + 16-byte secret; a device
--    another account is still signed in on cannot be taken over by saving its endpoint.

create or replace function public.delete_message(p_msg uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); m public.messages;
begin
  perform private.assert_active();   -- 0033: a suspended or banned account cannot erase evidence
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

create or replace function public.delete_media_asset(p_asset uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  perform private.assert_active();   -- 0033: a suspended or banned account cannot erase evidence
  perform private.rate_limit_hit('delete_media_asset', 60, interval '1 hour');
  if not exists (select 1 from public.media_assets where id = p_asset and owner_id = v_uid) then
    perform private.fail('asset_not_found');
  end if;
  perform private.request_asset_deletion(p_asset);
end $$;

-- 2.
create or replace function private.check_profile_media()
returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.avatar_asset_id is not null and new.avatar_asset_id is distinct from old.avatar_asset_id
     and not exists (select 1 from public.media_assets a where a.id = new.avatar_asset_id and a.owner_id = new.id
                       and a.purpose = 'profile' and a.status = 'uploaded') then
    perform private.fail('invalid_media');
  end if;
  if new.banner_asset_id is not null and new.banner_asset_id is distinct from old.banner_asset_id
     and not exists (select 1 from public.media_assets a where a.id = new.banner_asset_id and a.owner_id = new.id
                       and a.purpose = 'profile' and a.status = 'uploaded') then
    perform private.fail('invalid_media');
  end if;
  return new;
end $$;
drop trigger if exists profiles_check_media on public.profiles;
create trigger profiles_check_media before update of avatar_asset_id, banner_asset_id on public.profiles
  for each row execute function private.check_profile_media();

-- 3.
drop policy if exists nick_owner_update on public.friend_nicknames;
create policy nick_owner_update on public.friend_nicknames for update to authenticated
  using (owner_id = (select auth.uid()))
  with check (owner_id = (select auth.uid()) and private.are_friends(owner_id, friend_id));

-- 4.
drop policy if exists snap_recipients_visible on public.snap_recipients;
create policy snap_recipients_visible on public.snap_recipients for select to authenticated
  using (recipient_id = (select auth.uid())
         or (private.is_snap_sender(snap_id, (select auth.uid()))
             and not private.is_blocked_either((select auth.uid()), recipient_id)));

-- 5.
create or replace function public.get_friend_presence()
returns table (user_id uuid, online boolean, last_active_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active();
begin
  return query
    select p.user_id,
      case when s.ghost_mode or not s.show_online then null
           else p.last_active_at > now() - interval '2 minutes' end,
      case when s.ghost_mode or not s.show_last_active then null else p.last_active_at end
    from private.presence p
    join public.user_settings s on s.user_id = p.user_id
    join public.profiles pr on pr.id = p.user_id and pr.account_state = 'active'
    where p.user_id <> v_uid
      and private.are_friends(v_uid, p.user_id)
      and not private.is_blocked_either(v_uid, p.user_id);
end $$;

-- 6.
create or replace function private.purge_client_errors()
returns integer
language plpgsql security definer set search_path = '' as $$
declare v_n integer;
begin
  delete from private.client_errors where created_at < now() - interval '14 days';
  get diagnostics v_n = row_count;
  return v_n;
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
     where e.created_at >= now() - interval '14 days'
     order by e.created_at desc limit greatest(1, least(p_limit, 200));
end $$;
do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'pulse-client-errors';
    perform cron.schedule('pulse-client-errors', '41 3 * * *', 'select private.purge_client_errors()');
  end if;
end $$;

-- 7.
create or replace function private.forget_invited_username()
returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update private.invitations set redeemed_username = null where redeemed_by = old.id;
  return null;
end $$;
drop trigger if exists profiles_forget_invite_name on public.profiles;
create trigger profiles_forget_invite_name after delete on public.profiles
  for each row execute function private.forget_invited_username();

-- 8.
alter table private.push_subscriptions drop constraint if exists push_subscriptions_p256dh_check;
alter table private.push_subscriptions drop constraint if exists push_subscriptions_auth_check;
delete from private.push_subscriptions where p256dh !~ '^[A-Za-z0-9_-]{87}$' or auth !~ '^[A-Za-z0-9_-]{22}$';
alter table private.push_subscriptions
  add constraint push_subscriptions_p256dh_check check (p256dh ~ '^[A-Za-z0-9_-]{87}$'),
  add constraint push_subscriptions_auth_check check (auth ~ '^[A-Za-z0-9_-]{22}$');
create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_session uuid := nullif(auth.jwt() ->> 'session_id', '')::uuid;
begin
  perform private.rate_limit_hit('save_push_subscription', 20, interval '1 hour');
  if p_endpoint is null or not private.push_endpoint_allowed(p_endpoint) then perform private.fail('push_endpoint_invalid'); end if;
  -- Exactly a 65-byte P-256 key and a 16-byte secret, unpadded base64url (0033).
  if p_p256dh !~ '^[A-Za-z0-9_-]{87}$' or p_auth !~ '^[A-Za-z0-9_-]{22}$' then perform private.fail('push_keys_invalid'); end if;
  insert into private.push_subscriptions (user_id, session_id, endpoint, p256dh, auth)
  values (v_uid, v_session, p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update
     set user_id = excluded.user_id, session_id = excluded.session_id, p256dh = excluded.p256dh,
         auth = excluded.auth, created_at = now()
   -- 0033: a device that another account is still signed in on cannot be taken over.
   where private.push_subscriptions.user_id = excluded.user_id
      or not exists (select 1 from auth.sessions s where s.id = private.push_subscriptions.session_id
                                                    and s.user_id = private.push_subscriptions.user_id);
  -- At most 10 devices per account: drop the oldest.
  delete from private.push_subscriptions where id in (
    select id from private.push_subscriptions where user_id = v_uid order by created_at desc offset 10);
end $$;

revoke execute on function private.check_profile_media(), private.purge_client_errors(), private.forget_invited_username()
  from public, anon, authenticated;
revoke execute on function public.delete_message(uuid), public.delete_media_asset(uuid), public.get_friend_presence(),
  public.admin_client_errors(integer), public.save_push_subscription(text, text, text) from public, anon;
grant execute on function public.delete_message(uuid), public.delete_media_asset(uuid), public.get_friend_presence(),
  public.admin_client_errors(integer), public.save_push_subscription(text, text, text) to authenticated;
