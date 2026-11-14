-- PULSE 0015 — RPC fixes from the multi-agent review (uses the helpers from 0014).
-- Each function below replaces an earlier definition; comments name the problem fixed.

-- ===========================================================================
-- Accounts
-- ===========================================================================

-- Owner status is not revealed to a password-only (aal1) session of a 2FA account.
create or replace function public.am_i_owner()
returns boolean language sql stable security definer set search_path = '' as $$
  select private.mfa_satisfied() and private.is_owner(auth.uid())
$$;

create or replace function private.assert_owner()
returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then perform private.fail('forbidden'); end if;
  perform private.assert_mfa();
  if not private.is_owner(v_uid) then perform private.fail('forbidden'); end if;
  return v_uid;
end $$;

-- The signed-in user's own profile, including moderation state (friends cannot read
-- account_state any more). Works for suspended accounts so the app can explain why.
create or replace function public.my_profile()
returns table (id uuid, username text, display_name text, bio text, status_text text,
               account_state public.account_state, username_changed_at timestamptz,
               created_at timestamptz, avatar_asset_id uuid)
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then perform private.fail('not_authenticated'); end if;
  perform private.assert_mfa();
  return query select p.id, p.username::text, p.display_name, p.bio,
                      case when p.status_expires_at is null or p.status_expires_at > now()
                           then p.status_text end,
                      p.account_state, p.username_changed_at, p.created_at, p.avatar_asset_id
                 from public.profiles p where p.id = v_uid;
end $$;

create or replace function private.username_unavailable(p_name text, p_self uuid default null)
returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from private.retired_usernames
                 where username = p_name::extensions.citext and retired_until > now())
      or exists (select 1 from private.username_reservations
                 where username = p_name::extensions.citext and reserved_until > now()
                   and user_id is distinct from p_self)
$$;

-- Signup: 'deleting' accounts no longer hold registration slots; retired names refused.
create or replace function private.handle_new_user()
returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_cfg private.platform_config := private.config();
  v_username text;
  v_display text;
  v_count integer;
begin
  perform pg_advisory_xact_lock(hashtext('pulse_registration'));
  select count(*) into v_count from public.profiles where account_state <> 'deleting';
  if v_count >= v_cfg.registration_cap and new.id is distinct from v_cfg.owner_user_id then
    perform private.fail('registration_closed', 'free-tier capacity reached');
  end if;

  v_username := private.validate_username(new.raw_user_meta_data ->> 'username');
  if private.username_unavailable(v_username) then perform private.fail('username_taken'); end if;
  if exists (select 1 from public.profiles where username = v_username::extensions.citext) then
    perform private.fail('username_taken');
  end if;

  v_display := coalesce(nullif(btrim(new.raw_user_meta_data ->> 'display_name'), ''), v_username);
  insert into public.profiles (id, username, display_name)
  values (new.id, v_username, left(v_display, 40));
  insert into public.user_settings (user_id) values (new.id);
  insert into private.presence (user_id) values (new.id);
  return new;
end $$;

create or replace function public.change_username(p_new text)
returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.assert_active();
  v_cfg private.platform_config := private.config();
  v_new text := private.validate_username(p_new);
  v_old extensions.citext;
  v_changed timestamptz;
begin
  perform private.rate_limit_hit('change_username', 5, interval '1 hour');
  select username, username_changed_at into v_old, v_changed
    from public.profiles where id = v_uid for update;
  if v_old = v_new::extensions.citext then return v_old::text; end if;
  if not private.is_owner(v_uid) and v_changed is not null
     and v_changed > now() - v_cfg.username_cooldown then
    perform private.fail('username_cooldown',
      to_char(v_changed + v_cfg.username_cooldown, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  end if;
  if private.username_unavailable(v_new, v_uid) then perform private.fail('username_taken'); end if;
  begin
    update public.profiles set username = v_new, username_changed_at = now() where id = v_uid;
  exception when unique_violation then
    perform private.fail('username_taken');
  end;
  delete from private.username_reservations where username = v_new::extensions.citext;
  insert into private.username_reservations (username, user_id, reserved_until)
  values (v_old, v_uid, now() + v_cfg.username_reservation)
  on conflict (username) do update
    set user_id = excluded.user_id, reserved_until = excluded.reserved_until;
  return v_new;
end $$;

-- Delete never-confirmed signups. Keyed on the latest confirmation email (a resend
-- keeps the account), so a user holding a fresh link is never purged.
create or replace function private.purge_unconfirmed_signups(p_age interval default null)
returns integer
language plpgsql security definer set search_path = '' as $$
declare v_n integer; v_age interval := coalesce(p_age, (private.config()).unconfirmed_signup_ttl);
begin
  delete from auth.users u
   where u.email_confirmed_at is null
     and coalesce(u.confirmation_sent_at, u.created_at) < now() - v_age
     and u.id is distinct from (private.config()).owner_user_id
     and not exists (select 1 from public.media_assets a where a.owner_id = u.id);
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- ===========================================================================
-- Social
-- ===========================================================================

-- A block looks the same as a missing account (no block detection).
create or replace function private.assert_can_interact(p_me uuid, p_other uuid)
returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if private.is_blocked_either(p_me, p_other)
     or not exists (select 1 from public.profiles where id = p_other and account_state = 'active') then
    perform private.fail('user_not_found');
  end if;
end $$;

-- Unconfirmed signups are not searchable (no squatting on visible handles).
create or replace function public.search_users(p_query text)
returns table (id uuid, username text, display_name text, avatar_asset_id uuid,
               relationship text)
language plpgsql volatile security definer set search_path = '' as $$
declare
  v_uid uuid := private.assert_active();
  v_q text := private.normalize_username(ltrim(btrim(p_query), '@'));
  v_like text;
begin
  if v_q is null or char_length(v_q) < 3 then perform private.fail('query_too_short'); end if;
  if v_q !~ '^[a-z0-9._]+$' then return; end if;
  v_like := replace(v_q, '_', '\_');
  perform private.rate_limit_hit('search_users', 30, interval '1 minute');
  return query
    select p.id, p.username::text, p.display_name, p.avatar_asset_id,
      case
        when private.are_friends(v_uid, p.id) then 'friend'
        when exists (select 1 from public.friend_requests r where r.status = 'pending'
                     and r.sender_id = v_uid and r.recipient_id = p.id) then 'request_sent'
        when exists (select 1 from public.friend_requests r where r.status = 'pending'
                     and r.sender_id = p.id and r.recipient_id = v_uid) then 'request_received'
        else 'none'
      end
    from public.profiles p
    join auth.users u on u.id = p.id and u.email_confirmed_at is not null
    where p.id <> v_uid
      and p.account_state = 'active'
      and not private.is_blocked_either(v_uid, p.id)
      and p.username::text like '%' || v_like || '%'
    order by (p.username = v_q::extensions.citext) desc,
             (p.username::text like v_like || '%') desc,
             p.username
    limit 20;
end $$;

create or replace function public.send_friend_request(p_target uuid)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_id uuid; v_reverse uuid;
begin
  perform private.rate_limit_hit('send_friend_request', 30, interval '1 hour');
  if p_target = v_uid then perform private.fail('invalid_target'); end if;
  perform private.lock_pair(v_uid, p_target);
  perform private.assert_can_interact(v_uid, p_target);
  if not exists (select 1 from auth.users where id = p_target and email_confirmed_at is not null) then
    perform private.fail('user_not_found');
  end if;
  if private.are_friends(v_uid, p_target) then perform private.fail('already_friends'); end if;

  select id into v_reverse from public.friend_requests
   where sender_id = p_target and recipient_id = v_uid and status = 'pending' for update;
  if v_reverse is not null then
    perform public.respond_friend_request(v_reverse, true);
    return v_reverse;
  end if;

  begin
    insert into public.friend_requests (sender_id, recipient_id) values (v_uid, p_target)
    returning id into v_id;
  exception when unique_violation then
    perform private.fail('request_exists');
  end;
  return v_id;
end $$;

create or replace function public.respond_friend_request(p_request uuid, p_accept boolean)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); r public.friend_requests;
begin
  select * into r from public.friend_requests where id = p_request;
  if r.id is null or r.recipient_id <> v_uid then perform private.fail('request_not_found'); end if;
  perform private.lock_pair(r.sender_id, r.recipient_id);
  select * into r from public.friend_requests where id = p_request for update;
  if r.status <> 'pending' then perform private.fail('request_not_pending'); end if;
  if p_accept then
    perform private.assert_can_interact(v_uid, r.sender_id);
    update public.friend_requests set status = 'accepted', responded_at = now() where id = r.id;
    insert into public.friendships (user_a, user_b)
    values (least(r.sender_id, r.recipient_id), greatest(r.sender_id, r.recipient_id))
    on conflict do nothing;
  else
    update public.friend_requests set status = 'declined', responded_at = now() where id = r.id;
  end if;
end $$;

create or replace function public.remove_friend(p_friend uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active();
begin
  perform private.rate_limit_hit('remove_friend', 60, interval '1 hour');
  perform private.lock_pair(v_uid, p_friend);
  delete from public.friendships
   where user_a = least(v_uid, p_friend) and user_b = greatest(v_uid, p_friend);
  delete from public.friend_nicknames
   where (owner_id = v_uid and friend_id = p_friend) or (owner_id = p_friend and friend_id = v_uid);
end $$;

-- Requests from the blocked person read 'declined' (like an ordinary refusal), the
-- pair is locked so a concurrent accept cannot resurrect the friendship, and any live
-- Snap viewing session between the two ends.
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
  update public.snap_recipients r set session_id = null, session_deadline = null
    from public.snaps s
   where s.id = r.snap_id and r.session_id is not null
     and ((s.sender_id = v_uid and r.recipient_id = p_target)
       or (s.sender_id = p_target and r.recipient_id = v_uid));
end $$;

create or replace function public.unblock_user(p_target uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active();
begin
  perform private.rate_limit_hit('block_user', 60, interval '1 hour');
  perform private.lock_pair(v_uid, p_target);
  delete from public.blocks where blocker_id = v_uid and blocked_id = p_target;
end $$;

-- People the caller has blocked (minimal card), for the unblock list.
create or replace function public.my_blocked_users()
returns table (user_id uuid, username text, display_name text, blocked_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active();
begin
  return query select p.id, p.username::text, p.display_name, b.created_at
                 from public.blocks b join public.profiles p on p.id = b.blocked_id
                where b.blocker_id = v_uid order by b.created_at desc limit 500;
end $$;

-- ===========================================================================
-- Media
-- ===========================================================================

-- Per-user caps on every pool and on outstanding reservations; the memories pool
-- refuses at 90%, matching the documented guard and the UI's pool_full flag.
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
  select count(*) into v_pending from public.media_assets m
   where m.owner_id = v_uid and m.status = 'pending';
  if v_pending >= v_cfg.max_pending_uploads then perform private.fail('too_many_pending_uploads'); end if;

  select coalesce(sum(m.byte_size), 0) into v_user_used from public.media_assets m
   where m.owner_id = v_uid and private.pool_for(m.purpose) = v_pool
     and m.status in ('pending', 'uploaded');
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

-- Is anything still pointing at this asset? (Deduplicated uploads can be shared.)
create or replace function private.asset_referenced(p_asset uuid)
returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.messages m
                 where m.media_asset_id = p_asset and m.deleted_at is null
                   and (m.expires_at is null or m.expires_at > now()
                        or exists (select 1 from public.saved_messages s where s.message_id = m.id)))
      or exists (select 1 from public.snaps s join public.snap_recipients r on r.snap_id = s.id
                 where s.media_asset_id = p_asset and r.status <> 'expired')
      or exists (select 1 from public.profiles p join public.media_assets a on a.id = p_asset
                 where p.id = a.owner_id and (p.avatar_asset_id = p_asset or p.banner_asset_id = p_asset))
      or exists (select 1 from public.conversations c where c.icon_asset_id = p_asset)
$$;

create or replace function private.release_asset_if_unreferenced(p_asset uuid)
returns boolean
language plpgsql security definer set search_path = '' as $$
begin
  if p_asset is null or private.asset_referenced(p_asset) then return false; end if;
  perform private.request_asset_deletion(p_asset);
  return true;
end $$;

create or replace function private.release_snap_media_if_dead(p_snap uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_asset uuid;
begin
  select media_asset_id into v_asset from public.snaps where id = p_snap;
  if v_asset is not null and not exists (select 1 from public.snap_recipients
                                         where snap_id = p_snap and status <> 'expired') then
    perform private.release_asset_if_unreferenced(v_asset);
  end if;
end $$;

-- Owner downloads now go through here too (the Storage owner-read policy is gone).
create or replace function public.authorize_media_access(p_asset uuid)
returns table (bucket text, object_path text, mime_type text, valid_seconds integer)
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); a public.media_assets; v_ok boolean := false;
begin
  perform private.rate_limit_hit('authorize_media_access', 300, interval '1 minute');
  select * into a from public.media_assets where id = p_asset and status = 'uploaded';
  if a.id is null then perform private.fail('media_not_found'); end if;

  if a.owner_id = v_uid then
    v_ok := true;
  elsif a.purpose = 'chat' then
    v_ok := exists (select 1 from public.messages m
                    where m.media_asset_id = a.id
                      and private.can_read_message(m.id, v_uid)
                      and private.message_content_visible(m.id));
  elsif a.purpose = 'profile' then
    v_ok := exists (select 1 from public.profiles p
                    where p.id = a.owner_id and p.account_state = 'active'
                      and (p.avatar_asset_id = a.id or p.banner_asset_id = a.id)
                      and not private.is_blocked_either(v_uid, p.id)
                      and (p.avatar_asset_id = a.id or private.are_friends(v_uid, p.id)));
  elsif a.purpose = 'group_icon' then
    v_ok := exists (select 1 from public.conversations c
                    where c.icon_asset_id = a.id and private.is_member(c.id, v_uid));
  end if;

  if not v_ok then perform private.fail('media_not_found'); end if;
  perform private.charge_egress_for(a.id, a.byte_size);
  return query select a.bucket, a.object_path, a.mime_type, 60;
end $$;

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

-- ===========================================================================
-- Conversations
-- ===========================================================================

-- Starts the expiry timer for every disappearing message that all other active
-- members (who joined before it) have now read. Called after reads, and whenever the
-- set of members changes (leave, removal, suspension, deletion).
create or replace function private.apply_expiry(p_conv uuid)
returns integer
language plpgsql security definer set search_path = '' as $$
declare v_n integer; v_grace interval := (private.config()).after_view_grace;
begin
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
         and not exists (select 1 from public.message_reads r
                         where r.message_id = m.id and r.user_id = o.user_id));
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- Creates (or reuses) the direct chat between two users without no-op writes.
create or replace function private.ensure_direct_conversation(p_a uuid, p_b uuid)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_key text := least(p_a, p_b)::text || ':' || greatest(p_a, p_b)::text; v_id uuid;
begin
  select id into v_id from public.conversations where direct_key = v_key;
  if v_id is null then
    insert into public.conversations (kind, direct_key, created_by) values ('direct', v_key, p_a)
    on conflict (direct_key) do nothing
    returning id into v_id;
    if v_id is null then select id into v_id from public.conversations where direct_key = v_key; end if;
  end if;
  insert into public.conversation_members (conversation_id, user_id) values (v_id, p_a), (v_id, p_b)
  on conflict (conversation_id, user_id) do update set left_at = null
    where public.conversation_members.left_at is not null;
  return v_id;
end $$;

create or replace function public.create_direct_conversation(p_friend uuid)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active();
begin
  perform private.rate_limit_hit('create_direct_conversation', 120, interval '1 hour');
  if p_friend = v_uid then perform private.fail('invalid_target'); end if;
  if not private.are_friends(v_uid, p_friend) then perform private.fail('not_friends'); end if;
  perform private.assert_can_interact(v_uid, p_friend);
  return private.ensure_direct_conversation(v_uid, p_friend);
end $$;

-- A group needs at least one other member (no one-person storage groups).
create or replace function public.create_group(p_name text, p_members uuid[])
returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_id uuid; m uuid; v_added integer := 0;
begin
  perform private.rate_limit_hit('create_group', 20, interval '1 day');
  if coalesce(array_length(p_members, 1), 0) < 1 then perform private.fail('group_needs_members'); end if;
  if array_length(p_members, 1) > 31 then perform private.fail('group_too_large', '32'); end if;
  perform private.assert_db_headroom();
  insert into public.conversations (kind, name, created_by) values ('group', btrim(p_name), v_uid)
  returning id into v_id;
  insert into public.conversation_members (conversation_id, user_id, role) values (v_id, v_uid, 'owner');
  foreach m in array p_members loop
    if m = v_uid then continue; end if;
    if not private.are_friends(v_uid, m) then perform private.fail('not_friends', m::text); end if;
    perform private.assert_can_interact(v_uid, m);
    insert into public.conversation_members (conversation_id, user_id) values (v_id, m)
    on conflict do nothing;
    if found then v_added := v_added + 1; end if;
  end loop;
  if v_added = 0 then perform private.fail('group_needs_members'); end if;
  return v_id;
end $$;

create or replace function public.add_group_members(p_conv uuid, p_members uuid[])
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_role public.member_role; m uuid; v_count integer;
begin
  perform private.rate_limit_hit('add_group_members', 60, interval '1 hour');
  v_role := private.member_role(p_conv, v_uid);
  if v_role is null or v_role = 'member'
     or (select kind from public.conversations where id = p_conv) <> 'group' then
    perform private.fail('not_allowed');
  end if;
  foreach m in array p_members loop
    if not private.are_friends(v_uid, m) then perform private.fail('not_friends', m::text); end if;
    perform private.assert_can_interact(v_uid, m);
    insert into public.conversation_members (conversation_id, user_id) values (p_conv, m)
    on conflict (conversation_id, user_id) do update
      set left_at = null, joined_at = now(), role = 'member'
      where public.conversation_members.left_at is not null;
  end loop;
  select count(*) into v_count from public.conversation_members
   where conversation_id = p_conv and left_at is null;
  if v_count > 32 then perform private.fail('group_too_large', '32'); end if;
end $$;

-- Leaving members take their saves and reactions with them (a save by someone who has
-- left no longer keeps a message alive), and expiry is re-evaluated for the rest.
create or replace function private.detach_member(p_conv uuid, p_user uuid)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.conversation_members set left_at = now(), pinned_rank = null, role = 'member'
   where conversation_id = p_conv and user_id = p_user and left_at is null;
  delete from public.saved_messages s using public.messages m
   where m.id = s.message_id and m.conversation_id = p_conv and s.user_id = p_user;
  delete from public.message_reactions where conversation_id = p_conv and user_id = p_user;
  perform private.apply_expiry(p_conv);
end $$;

create or replace function public.remove_group_member(p_conv uuid, p_user uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_mine public.member_role; v_theirs public.member_role;
begin
  perform 1 from public.conversation_members
   where conversation_id = p_conv and user_id in (v_uid, p_user) order by user_id for update;
  v_mine := private.member_role(p_conv, v_uid);
  v_theirs := private.member_role(p_conv, p_user);
  if v_theirs is null then perform private.fail('not_a_member'); end if;
  if v_mine is null or p_user = v_uid or v_theirs = 'owner'
     or (v_mine = 'admin' and v_theirs <> 'member') or v_mine = 'member' then
    perform private.fail('not_allowed');
  end if;
  perform private.detach_member(p_conv, p_user);
end $$;

-- Both member rows are locked first, so a concurrent leave cannot leave the group
-- without an owner; the heir must still be an active member with an active account.
create or replace function public.transfer_group_ownership(p_conv uuid, p_new_owner uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active();
begin
  perform 1 from public.conversation_members
   where conversation_id = p_conv and user_id in (v_uid, p_new_owner) order by user_id for update;
  if private.member_role(p_conv, v_uid) is distinct from 'owner'::public.member_role
     or private.member_role(p_conv, p_new_owner) is null or p_new_owner = v_uid
     or not exists (select 1 from public.profiles where id = p_new_owner and account_state = 'active') then
    perform private.fail('not_allowed');
  end if;
  update public.conversation_members set role = 'admin'
   where conversation_id = p_conv and user_id = v_uid;
  update public.conversation_members set role = 'owner'
   where conversation_id = p_conv and user_id = p_new_owner and left_at is null;
  if not found then perform private.fail('not_allowed'); end if;
end $$;

create or replace function public.leave_group(p_conv uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_role public.member_role; v_others integer;
begin
  perform 1 from public.conversation_members
   where conversation_id = p_conv and user_id = v_uid for update;
  v_role := private.member_role(p_conv, v_uid);
  if v_role is null or (select kind from public.conversations where id = p_conv) <> 'group' then
    perform private.fail('not_allowed');
  end if;
  select count(*) into v_others from public.conversation_members
   where conversation_id = p_conv and left_at is null and user_id <> v_uid;
  if v_role = 'owner' and v_others > 0 then perform private.fail('transfer_ownership_first'); end if;
  perform private.detach_member(p_conv, v_uid);
end $$;

create or replace function public.update_group(p_conv uuid, p_name text, p_description text,
                                               p_theme jsonb default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_role public.member_role := private.member_role(p_conv, v_uid);
begin
  perform private.rate_limit_hit('update_group', 30, interval '1 hour');
  if v_role is null or v_role = 'member' then perform private.fail('not_allowed'); end if;
  update public.conversations
     set name = coalesce(btrim(p_name), name), description = p_description,
         theme = coalesce(p_theme, theme)
   where id = p_conv and kind = 'group'
     and (name, description, theme) is distinct from
         (coalesce(btrim(p_name), name), p_description, coalesce(p_theme, theme));
end $$;

-- Mode changes are announced in the chat as a system message, apply only to messages
-- sent afterwards, and are refused in blocked or ex-friend direct chats.
create or replace function public.set_chat_expiry(p_conv uuid, p_mode public.expiry_mode)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_role public.member_role; c public.conversations;
begin
  perform private.rate_limit_hit('set_chat_expiry', 10, interval '1 minute');
  perform private.assert_can_post(p_conv, v_uid);
  select * into c from public.conversations where id = p_conv for update;
  v_role := private.member_role(p_conv, v_uid);
  if c.kind = 'group' and v_role = 'member' then perform private.fail('not_allowed'); end if;
  if c.expiry_mode = p_mode then return; end if;
  update public.conversations set expiry_mode = p_mode, last_message_at = now() where id = p_conv;
  insert into public.messages (conversation_id, sender_id, kind, body, client_msg_id, expiry_mode)
  values (p_conv, v_uid, 'system', 'expiry_mode:' || p_mode::text, gen_random_uuid(), p_mode);
end $$;

-- ===========================================================================
-- Messages
-- ===========================================================================
create or replace function public.send_message(
  p_conv uuid, p_kind public.message_kind, p_body text, p_client_msg_id uuid,
  p_media_asset uuid default null, p_reply_to uuid default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.assert_active();
  v_id uuid;
  v_body text := nullif(btrim(p_body), '');
  v_mode public.expiry_mode;
  a public.media_assets;
begin
  if p_client_msg_id is null then perform private.fail('client_msg_id_required'); end if;
  select id into v_id from public.messages where sender_id = v_uid and client_msg_id = p_client_msg_id;
  if v_id is not null then return v_id; end if;

  perform private.rate_limit_hit('send_message', 60, interval '1 minute');
  perform private.rate_limit_hit('send_message_day', 2000, interval '1 day');
  perform private.assert_can_post(p_conv, v_uid);
  if p_kind in ('snap', 'system') then perform private.fail('invalid_kind'); end if;

  if p_kind = 'text' then
    if v_body is null then perform private.fail('empty_message'); end if;
    if p_media_asset is not null then perform private.fail('invalid_media'); end if;
  else
    select * into a from public.media_assets where id = p_media_asset;
    if a.id is null or a.owner_id <> v_uid or a.purpose <> 'chat' or a.status <> 'uploaded'
       or (p_kind = 'photo' and a.mime_type not like 'image/%')
       or (p_kind = 'video' and a.mime_type not like 'video/%')
       or (p_kind = 'voice' and a.mime_type not like 'audio/%') then
      perform private.fail('invalid_media');
    end if;
  end if;
  if char_length(v_body) > 4000 then perform private.fail('message_too_long'); end if;

  if p_reply_to is not null and not exists (
       select 1 from public.messages r where r.id = p_reply_to and r.conversation_id = p_conv
         and r.created_at >= private.member_joined_at(p_conv)
         and private.message_content_visible(r.id)) then
    perform private.fail('reply_target_unavailable');
  end if;

  perform private.assert_db_headroom();
  perform private.charge_text(octet_length(v_body));
  select expiry_mode into v_mode from public.conversations where id = p_conv;

  insert into public.messages (conversation_id, sender_id, kind, body, media_asset_id,
                               reply_to_id, client_msg_id, expiry_mode)
  values (p_conv, v_uid, p_kind, v_body, p_media_asset, p_reply_to, p_client_msg_id, v_mode)
  on conflict (sender_id, client_msg_id) do nothing
  returning id into v_id;
  if v_id is null then
    select id into v_id from public.messages where sender_id = v_uid and client_msg_id = p_client_msg_id;
    return v_id;
  end if;
  update public.conversations set last_message_at = now() where id = p_conv;
  return v_id;
end $$;

-- Rate-limited, at most N edits per message, no-op edits ignored, history bounded,
-- and only while the sender can still post in the chat.
create or replace function public.edit_message(p_msg uuid, p_body text)
returns void
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.assert_active();
  v_cfg private.platform_config := private.config();
  v_body text := btrim(p_body);
  m public.messages;
  v_edits integer;
begin
  perform private.rate_limit_hit('edit_message', 20, interval '1 minute');
  perform private.rate_limit_hit('edit_message_day', 300, interval '1 day');
  select * into m from public.messages where id = p_msg for update;
  if m.id is null or m.sender_id <> v_uid or not private.message_content_visible(m.id) then
    perform private.fail('message_not_found');
  end if;
  perform private.assert_can_post(m.conversation_id, v_uid);
  if m.kind <> 'text' then perform private.fail('not_editable'); end if;
  if m.created_at < now() - v_cfg.message_edit_window then perform private.fail('edit_window_closed'); end if;
  if v_body is null or char_length(v_body) = 0 then perform private.fail('empty_message'); end if;
  if char_length(v_body) > 4000 then perform private.fail('message_too_long'); end if;
  if v_body = m.body then return; end if;
  select count(*) into v_edits from private.message_edits where message_id = m.id;
  if v_edits >= v_cfg.max_edits_per_message then perform private.fail('edit_limit_reached'); end if;
  perform private.assert_db_headroom();
  perform private.charge_text(octet_length(v_body));
  insert into private.message_edits (message_id, previous_body) values (m.id, m.body);
  update public.messages set body = v_body, edited_at = now() where id = m.id;
end $$;

-- 'Delete for everyone' on a Snap message also unsends that Snap in this chat, and
-- shared (deduplicated) media is only released when nothing else uses it.
create or replace function public.delete_message(p_msg uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); m public.messages;
begin
  if v_uid is null then perform private.fail('not_authenticated'); end if;
  perform private.assert_mfa();
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

-- Marks read only what the client has actually rendered (p_from..p_up_to), serialises
-- concurrent readers of one chat (so expiry is never skipped), and writes nothing when
-- there was nothing new.
drop function if exists public.mark_conversation_read(uuid);
create or replace function public.mark_conversation_read(
  p_conv uuid, p_up_to timestamptz default null, p_from timestamptz default null)
returns integer
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_new integer; v_n integer := 0;
        v_peers uuid[] := private.my_block_peers();
begin
  perform private.rate_limit_hit('mark_read', 120, interval '1 minute');
  perform private.assert_conv_access(p_conv, v_uid);
  perform pg_advisory_xact_lock(hashtext('pulse_conv_read'), hashtext(p_conv::text));

  insert into public.message_reads (message_id, user_id, sender_id)
  select m.id, v_uid, m.sender_id from public.messages m
  join public.conversation_members cm on cm.conversation_id = m.conversation_id and cm.user_id = v_uid
  where m.conversation_id = p_conv and m.sender_id <> v_uid and m.deleted_at is null
    and m.created_at >= cm.joined_at and m.kind <> 'snap'
    and (m.expires_at is null or m.expires_at > now())
    and (p_up_to is null or m.created_at <= p_up_to)
    and (p_from is null or m.created_at >= p_from)
    and m.sender_id <> all (v_peers)
  on conflict do nothing;
  get diagnostics v_new = row_count;
  if v_new > 0 then
    v_n := private.apply_expiry(p_conv);
    update public.conversation_members set last_read_at = now()
     where conversation_id = p_conv and user_id = v_uid;
  end if;
  return v_n;
end $$;

-- One reaction per person per message (tapping another emoji replaces it).
create or replace function public.toggle_reaction(p_msg uuid, p_emoji text)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_conv uuid; v_existing text;
begin
  perform private.rate_limit_hit('toggle_reaction', 60, interval '1 minute');
  if not private.can_read_message(p_msg, v_uid) or not private.message_content_visible(p_msg) then
    perform private.fail('message_not_found');
  end if;
  select conversation_id into v_conv from public.messages where id = p_msg;
  perform private.assert_can_post(v_conv, v_uid);
  select emoji into v_existing from public.message_reactions
   where message_id = p_msg and user_id = v_uid for update;
  if v_existing = p_emoji then
    delete from public.message_reactions where message_id = p_msg and user_id = v_uid;
    return false;
  end if;
  insert into public.message_reactions (message_id, user_id, emoji, conversation_id)
  values (p_msg, v_uid, p_emoji, v_conv)
  on conflict (message_id, user_id) do update set emoji = excluded.emoji, created_at = now();
  return true;
end $$;

create or replace function public.set_message_saved(p_msg uuid, p_saved boolean)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_kind public.message_kind;
begin
  perform private.rate_limit_hit('set_message_saved', 60, interval '1 minute');
  if not private.can_read_message(p_msg, v_uid) or not private.message_content_visible(p_msg) then
    perform private.fail('message_not_found');
  end if;
  select kind into v_kind from public.messages where id = p_msg;
  if v_kind = 'snap' then perform private.fail('use_save_snap'); end if;
  if p_saved then
    insert into public.saved_messages (message_id, user_id) values (p_msg, v_uid) on conflict do nothing;
  else
    delete from public.saved_messages where message_id = p_msg and user_id = v_uid;
  end if;
end $$;

create or replace function public.set_pin(p_conv uuid, p_rank smallint)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_old smallint;
begin
  perform private.rate_limit_hit('set_pin', 30, interval '1 minute');
  perform private.assert_conv_access(p_conv, v_uid);
  if p_rank is not null and p_rank not between 1 and 3 then perform private.fail('max_three_pins'); end if;
  select pinned_rank into v_old from public.conversation_members
   where conversation_id = p_conv and user_id = v_uid for update;
  if v_old is not distinct from p_rank then return; end if;
  update public.conversation_members set pinned_rank = null
   where conversation_id = p_conv and user_id = v_uid;
  if p_rank is not null then
    update public.conversation_members set pinned_rank = v_old
     where user_id = v_uid and pinned_rank = p_rank;
    update public.conversation_members set pinned_rank = p_rank
     where conversation_id = p_conv and user_id = v_uid;
  end if;
end $$;

create or replace function public.set_mute(p_conv uuid, p_until timestamptz)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active();
begin
  perform private.rate_limit_hit('set_mute', 30, interval '1 minute');
  perform private.assert_conv_access(p_conv, v_uid);
  update public.conversation_members set muted_until = p_until
   where conversation_id = p_conv and user_id = v_uid and left_at is null
     and muted_until is distinct from p_until;
end $$;

-- Chat list: an opened Snap is no longer 'unread'; 'Opened' only waits for members
-- who were there when the message was sent; system notices and blocked people's
-- messages are not used for the label.
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
               and o.joined_at <= st.created_at
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

-- Nothing for blocked direct chats; blocked people are left out of group rosters.
create or replace function public.conversation_participants(p_conv uuid)
returns table (user_id uuid, username text, display_name text, nickname text,
               nickname_color text, avatar_asset_id uuid, role public.member_role)
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_peers uuid[] := private.my_block_peers();
begin
  perform private.assert_conv_access(p_conv, v_uid);
  return query
    select p.id, p.username::text, p.display_name, n.nickname, n.color, p.avatar_asset_id, cm.role
    from public.conversation_members cm
    join public.profiles p on p.id = cm.user_id
    left join public.friend_nicknames n on n.owner_id = v_uid and n.friend_id = p.id
    where cm.conversation_id = p_conv and cm.left_at is null and cm.user_id <> all (v_peers)
    order by cm.role, p.username;
end $$;

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
           exists (select 1 from public.saved_messages s where s.message_id = m.id)
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
      and (not p_saved_only or exists (select 1 from public.saved_messages s where s.message_id = m.id))
      and (p_kinds is null or m.kind = any (p_kinds))
    order by m.created_at desc
    limit least(greatest(p_limit, 1), 100);
end $$;

-- Gallery filters before the limit and no longer goes through the rate-limited
-- search_messages (which made this STABLE function fail through PostgREST).
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
           exists (select 1 from public.saved_messages s where s.message_id = m.id)
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
        or (p_filter = 'saved' and exists (select 1 from public.saved_messages s where s.message_id = m.id)))
    order by m.created_at desc
    limit 100;
end $$;

-- ===========================================================================
-- Snaps
-- ===========================================================================

-- Idempotent under concurrent retries; group fan-out skips people with a block.
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
    insert into public.snap_recipients (snap_id, recipient_id, conversation_id)
    values (v_snap, r, v_conv) on conflict do nothing;
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
    insert into public.snap_recipients (snap_id, recipient_id, conversation_id)
    select v_snap, cm.user_id, g from public.conversation_members cm
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

-- A view is not used up when the Snap was unsent (message deleted) or its media is gone.
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
     or private.is_blocked_either(v_uid, v_sender) then
    perform private.fail('snap_session_invalid');
  end if;
  select m.* into a from public.snaps s join public.media_assets m on m.id = s.media_asset_id
   where s.id = p_snap and m.status = 'uploaded';
  if a.id is null then perform private.fail('snap_expired'); end if;
  perform private.charge_egress_for(a.id, a.byte_size);
  return query select a.bucket, a.object_path, a.mime_type,
    least(60, greatest(1, ceil(extract(epoch from r.session_deadline - now()))::integer));
end $$;

create or replace function public.save_snap(p_snap uuid, p_session uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); r public.snap_recipients; s public.snaps;
begin
  select * into r from public.snap_recipients
   where snap_id = p_snap and recipient_id = v_uid for update;
  select * into s from public.snaps where id = p_snap;
  if r.snap_id is null or private.is_blocked_either(v_uid, s.sender_id) then
    perform private.fail('snap_not_found');
  end if;
  if not coalesce(s.allow_saving, false) then perform private.fail('saving_not_permitted'); end if;
  if r.session_id is distinct from p_session or not private.snap_session_live(r) then
    perform private.fail('snap_session_invalid');
  end if;
  update public.snap_recipients set saved_at = coalesce(saved_at, now())
   where snap_id = p_snap and recipient_id = v_uid;
end $$;

-- ===========================================================================
-- Realtime topics: members only, not blocked, still friends in direct chats,
-- active account, 2FA satisfied.
-- ===========================================================================
create or replace function private.can_use_topic(p_topic text)
returns boolean
language sql stable security definer set search_path = '' as $$
  select p_topic like 'conv:%'
     and private.can_post(private.try_uuid(substr(p_topic, 6)), auth.uid())
     and private.caller_active()
     and private.mfa_satisfied()
$$;

-- ===========================================================================
-- Reports
-- ===========================================================================

-- Evidence holds only what the reporter could see (strangers get the minimal card).
create or replace function public.report_user(p_user uuid, p_reason public.report_reason,
                                              p_details text default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_id uuid; v_friend boolean;
begin
  perform private.rate_limit_hit('report', 20, interval '1 hour');
  if p_user = v_uid or not exists (select 1 from public.profiles where id = p_user) then
    perform private.fail('user_not_found');
  end if;
  v_friend := private.are_friends(v_uid, p_user);
  insert into public.reports (reporter_id, target_type, target_user_id, reason, details, evidence)
  select v_uid, 'user', p.id, p_reason, p_details,
         jsonb_strip_nulls(jsonb_build_object(
           'username', p.username, 'display_name', p.display_name,
           'bio', case when v_friend then p.bio end, 'captured_at', now()))
  from public.profiles p where p.id = p_user
  returning id into v_id;
  return v_id;
end $$;

-- A message the reporter has read can still be reported after it disappeared, until
-- the purge (expired_retention); blocking the sender does not prevent reporting.
create or replace function public.report_message(p_msg uuid, p_reason public.report_reason,
                                                 p_details text default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); m public.messages; v_id uuid;
        v_retention interval := (private.config()).expired_retention;
begin
  perform private.rate_limit_hit('report', 20, interval '1 hour');
  select * into m from public.messages where id = p_msg;
  if m.id is null or m.sender_id = v_uid or m.deleted_at is not null or m.kind = 'system'
     or not exists (select 1 from public.conversation_members cm
                    where cm.conversation_id = m.conversation_id and cm.user_id = v_uid
                      and cm.left_at is null and cm.joined_at <= m.created_at)
     or not (private.message_content_visible(m.id)
             or (m.expires_at > now() - v_retention
                 and exists (select 1 from public.message_reads r
                             where r.message_id = m.id and r.user_id = v_uid))) then
    perform private.fail('message_not_found');
  end if;
  insert into public.reports (reporter_id, target_type, target_user_id, target_message_id,
                              target_conversation_id, reason, details, evidence)
  values (v_uid, 'message', m.sender_id, m.id, m.conversation_id, p_reason, p_details,
          jsonb_build_object('kind', m.kind, 'body', m.body, 'sent_at', m.created_at,
                             'media_asset_id', m.media_asset_id, 'captured_at', now()))
  returning id into v_id;
  return v_id;
end $$;

-- ===========================================================================
-- Owner administration
-- ===========================================================================

-- No 'restore' of an account being deleted; bans use a finite date GoTrue can read;
-- a suspended member no longer holds back disappearing messages for others.
create or replace function public.admin_set_account_state(p_user uuid, p_state public.account_state,
                                                          p_reason text)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_owner uuid := private.assert_owner(); v_current public.account_state; v_conv uuid;
begin
  if p_user = v_owner then perform private.fail('cannot_moderate_owner'); end if;
  if p_state = 'deleting' then perform private.fail('use_deletion_flow'); end if;
  if p_reason is null or char_length(btrim(p_reason)) = 0 then perform private.fail('reason_required'); end if;
  select account_state into v_current from public.profiles where id = p_user for update;
  if v_current is null then perform private.fail('user_not_found'); end if;
  if v_current = 'deleting' then perform private.fail('account_deleting'); end if;
  update public.profiles set account_state = p_state where id = p_user;
  update auth.users
     set banned_until = case when p_state = 'active' then null else now() + interval '100 years' end
   where id = p_user;
  if p_state <> 'active' then
    perform private.revoke_sessions(p_user);
    for v_conv in select conversation_id from public.conversation_members
                  where user_id = p_user and left_at is null loop
      perform private.apply_expiry(v_conv);
    end loop;
  end if;
  perform private.audit('account.set_state', p_user, jsonb_build_object('state', p_state, 'reason', p_reason));
end $$;

-- Owner-initiated deletion (e.g. of a banned account that can no longer sign in).
create or replace function public.admin_delete_account(p_user uuid, p_reason text)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_owner uuid := private.assert_owner();
begin
  if p_user = v_owner then perform private.fail('cannot_moderate_owner'); end if;
  if p_reason is null or char_length(btrim(p_reason)) = 0 then perform private.fail('reason_required'); end if;
  if not exists (select 1 from public.profiles where id = p_user) then perform private.fail('user_not_found'); end if;
  perform private.queue_account_deletion(p_user);
  perform private.audit('account.deletion_by_owner', p_user, jsonb_build_object('reason', p_reason));
end $$;

-- ===========================================================================
-- Account deletion
-- ===========================================================================

-- Re-authentication means a password sign-in in the last N minutes. Verifying or
-- enrolling a TOTP factor (or a token refresh) does not count.
create or replace function private.recently_authenticated(p_max_age interval)
returns boolean
language sql stable as $$
  select coalesce(
    (select max((e ->> 'timestamp')::bigint)
       from jsonb_array_elements(coalesce(auth.jwt() -> 'amr', '[]'::jsonb)) e
      where e ->> 'method' = 'password')
      >= extract(epoch from now() - p_max_age), false)
$$;

create or replace function private.queue_account_deletion(p_user uuid)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  update public.profiles set account_state = 'deleting' where id = p_user;
  update auth.users set banned_until = now() + interval '100 years' where id = p_user;
  perform private.revoke_sessions(p_user);
  insert into private.deletion_queue (user_id) values (p_user) on conflict do nothing;
  perform private.request_asset_deletion(id) from public.media_assets
   where owner_id = p_user and status in ('pending', 'uploaded');
end $$;

create or replace function public.request_account_deletion()
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then perform private.fail('not_authenticated'); end if;
  perform private.assert_mfa();
  if exists (select 1 from private.deletion_queue where user_id = v_uid) then return; end if;
  if private.is_owner(v_uid) then perform private.fail('owner_account_protected'); end if;
  if not private.recently_authenticated(interval '10 minutes') then
    perform private.fail('reauthentication_required');
  end if;
  perform private.queue_account_deletion(v_uid);
  perform private.audit('account.deletion_requested', v_uid, '{}'::jsonb);
end $$;

-- Heirs must be active accounts.
create or replace function private.transfer_ownership_on_delete(p_user uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare g record; v_heir uuid;
begin
  for g in select conversation_id from public.conversation_members
           where user_id = p_user and role = 'owner' and left_at is null loop
    select o.user_id into v_heir from public.conversation_members o
      join public.profiles p on p.id = o.user_id and p.account_state = 'active'
     where o.conversation_id = g.conversation_id and o.user_id <> p_user and o.left_at is null
     order by (o.role = 'admin') desc, o.joined_at limit 1;
    update public.conversation_members set role = 'member'
     where conversation_id = g.conversation_id and user_id = p_user;
    if v_heir is not null then
      update public.conversation_members set role = 'owner'
       where conversation_id = g.conversation_id and user_id = v_heir;
    end if;
  end loop;
end $$;

-- Hard delete no longer waits for the storage-janitor (object paths go to
-- storage_trash first). Each account is processed in its own subtransaction, so one
-- failure is recorded and retried without blocking the others or other maintenance.
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
      insert into private.storage_trash (id, bucket, object_path)
      select id, bucket, object_path from public.media_assets
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

-- ===========================================================================
-- Storage janitor contract: assets marked 'deleting' plus objects of deleted accounts.
-- ===========================================================================
create or replace function public.janitor_claim_deletions(p_limit integer default 100)
returns table (asset_id uuid, bucket text, object_path text)
language sql security definer set search_path = '' as $$
  (select id, bucket, object_path from public.media_assets
    where status = 'deleting' order by delete_requested_at limit least(p_limit, 1000))
  union all
  (select id, bucket, object_path from private.storage_trash
    order by queued_at limit least(p_limit, 1000))
$$;

create or replace function public.janitor_mark_deleted(p_assets uuid[])
returns integer
language plpgsql security definer set search_path = '' as $$
declare v_n integer; v_t integer;
begin
  update public.media_assets set status = 'deleted'
   where id = any (p_assets) and status = 'deleting';
  get diagnostics v_n = row_count;
  delete from private.storage_trash where id = any (p_assets);
  get diagnostics v_t = row_count;
  return v_n + v_t;
end $$;

-- ===========================================================================
-- Maintenance: every step is isolated (a failure is reported, the rest still runs),
-- purges are batched, and media is released only when nothing references it.
-- ===========================================================================
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

-- ===========================================================================
-- Privileges
-- ===========================================================================
revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema private from public, anon;

grant execute on function
  public.my_profile(), public.my_blocked_users(),
  public.mark_conversation_read(uuid, timestamptz, timestamptz),
  public.admin_delete_account(uuid, text)
  to authenticated;
revoke execute on function public.janitor_claim_deletions(integer), public.janitor_mark_deleted(uuid[])
  from authenticated;
grant execute on function public.janitor_claim_deletions(integer), public.janitor_mark_deleted(uuid[])
  to service_role;
revoke execute on function
  private.username_unavailable(text, uuid), private.asset_referenced(uuid),
  private.release_asset_if_unreferenced(uuid), private.release_snap_media_if_dead(uuid),
  private.apply_expiry(uuid), private.ensure_direct_conversation(uuid, uuid),
  private.detach_member(uuid, uuid), private.queue_account_deletion(uuid),
  private.process_account_deletions(integer), private.run_maintenance(),
  private.purge_unconfirmed_signups(interval)
  from authenticated;
