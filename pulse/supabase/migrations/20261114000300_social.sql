-- PULSE 0003 — friends, requests, blocks, private nicknames, user search, presence.

create type public.friend_request_status as enum ('pending', 'accepted', 'declined', 'cancelled');

create table public.friend_requests (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  status public.friend_request_status not null default 'pending',
  created_at timestamptz not null default now(),
  responded_at timestamptz,
  check (sender_id <> recipient_id)
);
create unique index friend_requests_one_pending
  on public.friend_requests (least(sender_id, recipient_id), greatest(sender_id, recipient_id))
  where status = 'pending';
create index friend_requests_recipient on public.friend_requests (recipient_id) where status = 'pending';

-- One row per friendship, canonical ordering user_a < user_b.
create table public.friendships (
  user_a uuid not null references public.profiles(id) on delete cascade,
  user_b uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (user_a, user_b),
  check (user_a < user_b)
);
create index friendships_user_b on public.friendships (user_b);

create table public.blocks (
  blocker_id uuid not null references public.profiles(id) on delete cascade,
  blocked_id uuid not null references public.profiles(id) on delete cascade,
  created_at timestamptz not null default now(),
  primary key (blocker_id, blocked_id),
  check (blocker_id <> blocked_id)
);
create index blocks_blocked on public.blocks (blocked_id);

create table public.friend_nicknames (
  owner_id uuid not null references public.profiles(id) on delete cascade,
  friend_id uuid not null references public.profiles(id) on delete cascade,
  nickname text not null check (char_length(btrim(nickname)) between 1 and 40),
  color text check (color ~ '^#[0-9A-Fa-f]{6}$'),
  updated_at timestamptz not null default now(),
  primary key (owner_id, friend_id),
  check (owner_id <> friend_id)
);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
create or replace function private.are_friends(p_a uuid, p_b uuid)
returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.friendships
                 where user_a = least(p_a, p_b) and user_b = greatest(p_a, p_b))
$$;

create or replace function private.is_blocked_either(p_a uuid, p_b uuid)
returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.blocks
                 where (blocker_id = p_a and blocked_id = p_b)
                    or (blocker_id = p_b and blocked_id = p_a))
$$;

create or replace function private.assert_can_interact(p_me uuid, p_other uuid)
returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if private.is_blocked_either(p_me, p_other) then perform private.fail('not_allowed'); end if;
  if not exists (select 1 from public.profiles where id = p_other and account_state = 'active') then
    perform private.fail('user_not_found');
  end if;
end $$;

grant execute on function private.are_friends(uuid, uuid) to authenticated;
grant execute on function private.is_blocked_either(uuid, uuid) to authenticated;

-- ---------------------------------------------------------------------------
-- Profile visibility: yourself, accepted friends, and the owner (for admin).
-- Non-friends see only the minimal card returned by search_users().
-- ---------------------------------------------------------------------------
create policy profiles_visible on public.profiles
  for select to authenticated
  using (
    id = auth.uid()
    or (private.are_friends(auth.uid(), id) and not private.is_blocked_either(auth.uid(), id))
  );
create policy profiles_self_update on public.profiles
  for update to authenticated using (id = auth.uid()) with check (id = auth.uid());

-- ---------------------------------------------------------------------------
-- RLS on social tables (reads only; all writes go through RPCs)
-- ---------------------------------------------------------------------------
alter table public.friend_requests enable row level security;
alter table public.friendships enable row level security;
alter table public.blocks enable row level security;
alter table public.friend_nicknames enable row level security;

revoke all on public.friend_requests, public.friendships, public.blocks, public.friend_nicknames
  from anon, authenticated;
grant select on public.friend_requests, public.friendships, public.blocks to authenticated;
grant select, insert, update, delete on public.friend_nicknames to authenticated;

create policy fr_participants on public.friend_requests for select to authenticated
  using (sender_id = auth.uid() or recipient_id = auth.uid());
create policy friendships_member on public.friendships for select to authenticated
  using (user_a = auth.uid() or user_b = auth.uid());
-- A blocked user can never learn who blocked them.
create policy blocks_own on public.blocks for select to authenticated
  using (blocker_id = auth.uid());

create policy nick_owner_select on public.friend_nicknames for select to authenticated
  using (owner_id = auth.uid());
create policy nick_owner_insert on public.friend_nicknames for insert to authenticated
  with check (owner_id = auth.uid() and private.are_friends(owner_id, friend_id));
create policy nick_owner_update on public.friend_nicknames for update to authenticated
  using (owner_id = auth.uid()) with check (owner_id = auth.uid());
create policy nick_owner_delete on public.friend_nicknames for delete to authenticated
  using (owner_id = auth.uid());

-- ---------------------------------------------------------------------------
-- RPCs
-- ---------------------------------------------------------------------------

-- Username search (exact or prefix/partial). Minimal card only; blocked users and
-- non-active accounts are invisible. Rate-limited against enumeration.
create or replace function public.search_users(p_query text)
returns table (id uuid, username text, display_name text, avatar_asset_id uuid,
               relationship text)
language plpgsql stable security definer set search_path = '' as $$
declare
  v_uid uuid := private.assert_active();
  v_q text := private.normalize_username(p_query);
  v_like text;
begin
  if v_q is null or char_length(v_q) < 3 then perform private.fail('query_too_short'); end if;
  if v_q !~ '^[a-z0-9._]+$' then return; end if;
  v_like := replace(v_q, '_', '\_');  -- only "_" is a LIKE wildcard in the allowed alphabet
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
    where p.id <> v_uid
      and p.account_state = 'active'
      and not private.is_blocked_either(v_uid, p.id)
      and p.username::text like '%' || v_like || '%'
    order by (p.username = v_q::extensions.citext) desc,
             (p.username::text like v_like || '%') desc,
             p.username
    limit 20;
end $$;
grant execute on function public.search_users(text) to authenticated;

create or replace function public.send_friend_request(p_target uuid)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_id uuid; v_reverse uuid;
begin
  perform private.rate_limit_hit('send_friend_request', 30, interval '1 hour');
  if p_target = v_uid then perform private.fail('invalid_target'); end if;
  perform private.assert_can_interact(v_uid, p_target);
  if private.are_friends(v_uid, p_target) then perform private.fail('already_friends'); end if;

  -- If the other person already asked us, sending a request accepts theirs.
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
  select * into r from public.friend_requests where id = p_request for update;
  if r.id is null or r.recipient_id <> v_uid then perform private.fail('request_not_found'); end if;
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

create or replace function public.cancel_friend_request(p_request uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_n integer;
begin
  update public.friend_requests set status = 'cancelled', responded_at = now()
   where id = p_request and sender_id = v_uid and status = 'pending';
  get diagnostics v_n = row_count;
  if v_n = 0 then perform private.fail('request_not_found'); end if;
end $$;

create or replace function public.remove_friend(p_friend uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active();
begin
  delete from public.friendships
   where user_a = least(v_uid, p_friend) and user_b = greatest(v_uid, p_friend);
  delete from public.friend_nicknames
   where (owner_id = v_uid and friend_id = p_friend) or (owner_id = p_friend and friend_id = v_uid);
end $$;

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
  insert into public.blocks (blocker_id, blocked_id) values (v_uid, p_target) on conflict do nothing;
  perform public.remove_friend(p_target);
  update public.friend_requests set status = 'cancelled', responded_at = now()
   where status = 'pending'
     and ((sender_id = v_uid and recipient_id = p_target)
       or (sender_id = p_target and recipient_id = v_uid));
end $$;

create or replace function public.unblock_user(p_target uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active();
begin
  delete from public.blocks where blocker_id = v_uid and blocked_id = p_target;
end $$;

-- Friend presence, filtered by each friend's Ghost Mode and visibility settings.
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
    where p.user_id <> v_uid
      and private.are_friends(v_uid, p.user_id)
      and not private.is_blocked_either(v_uid, p.user_id);
end $$;

grant execute on function
  public.send_friend_request(uuid), public.respond_friend_request(uuid, boolean),
  public.cancel_friend_request(uuid), public.remove_friend(uuid), public.block_user(uuid),
  public.unblock_user(uuid), public.get_friend_presence()
  to authenticated;
