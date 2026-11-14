-- PULSE 0005 — conversations, groups, messages, reads, expiry, reactions, saves, pins,
-- chat list (no previews), participants, search and shared-media gallery.

create type public.conversation_kind as enum ('direct', 'group');
create type public.member_role as enum ('owner', 'admin', 'member');
create type public.expiry_mode as enum ('after_view', 'after_view_24h', 'after_view_7d', 'never');
create type public.message_kind as enum ('text', 'photo', 'video', 'voice', 'snap', 'system');

create table public.conversations (
  id uuid primary key default gen_random_uuid(),
  kind public.conversation_kind not null,
  direct_key text unique,                       -- "<lower uuid>:<higher uuid>" for direct chats
  name text check (char_length(btrim(name)) between 1 and 50),
  description text check (char_length(description) <= 200),
  icon_asset_id uuid references public.media_assets(id) on delete set null,
  theme jsonb not null default '{}'::jsonb check (pg_column_size(theme) <= 2048),
  expiry_mode public.expiry_mode not null default 'after_view',
  created_by uuid references public.profiles(id) on delete set null,
  created_at timestamptz not null default now(),
  last_message_at timestamptz not null default now(),
  check ((kind = 'direct') = (direct_key is not null)),
  check (kind = 'group' or name is null)
);

create table public.conversation_members (
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  role public.member_role not null default 'member',
  joined_at timestamptz not null default now(),
  left_at timestamptz,
  last_read_at timestamptz,
  muted_until timestamptz,
  pinned_rank smallint check (pinned_rank between 1 and 3),
  wallpaper jsonb check (pg_column_size(wallpaper) <= 2048),
  primary key (conversation_id, user_id)
);
-- At most three pins per user (ranks 1..3 are unique per user).
create unique index members_pin_rank on public.conversation_members (user_id, pinned_rank)
  where pinned_rank is not null;
create index members_user_active on public.conversation_members (user_id) where left_at is null;
create unique index members_one_owner on public.conversation_members (conversation_id)
  where role = 'owner' and left_at is null;

create table public.messages (
  id uuid primary key default gen_random_uuid(),
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  sender_id uuid not null references public.profiles(id) on delete cascade,
  kind public.message_kind not null,
  body text check (char_length(body) <= 4000),
  media_asset_id uuid references public.media_assets(id) on delete set null,
  snap_id uuid,                                  -- FK added in 0006
  reply_to_id uuid references public.messages(id) on delete set null,
  client_msg_id uuid not null,
  created_at timestamptz not null default now(),
  edited_at timestamptz,
  deleted_at timestamptz,
  expires_at timestamptz,
  unique (sender_id, client_msg_id)              -- duplicate prevention on retries
);
create index messages_conv_created on public.messages (conversation_id, created_at desc);
create index messages_expiry on public.messages (expires_at) where expires_at is not null;

create table public.message_reads (
  message_id uuid not null references public.messages(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  read_at timestamptz not null default now(),
  primary key (message_id, user_id)
);

create table public.saved_messages (
  message_id uuid not null references public.messages(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  saved_at timestamptz not null default now(),
  primary key (message_id, user_id)
);

create table public.message_reactions (
  message_id uuid not null references public.messages(id) on delete cascade,
  user_id uuid not null references public.profiles(id) on delete cascade,
  emoji text not null check (char_length(emoji) between 1 and 16 and emoji !~ '[[:alnum:][:space:]]'),
  created_at timestamptz not null default now(),
  primary key (message_id, user_id, emoji)
);

-- Edit history is retained only for the sender's own audit; never exposed to others.
create table private.message_edits (
  id bigserial primary key,
  message_id uuid not null references public.messages(id) on delete cascade,
  previous_body text,
  edited_at timestamptz not null default now()
);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
create or replace function private.is_member(p_conv uuid, p_user uuid default null)
returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.conversation_members
                 where conversation_id = p_conv and user_id = coalesce(p_user, auth.uid())
                   and left_at is null)
$$;
grant execute on function private.is_member(uuid, uuid) to authenticated;

create or replace function private.member_role(p_conv uuid, p_user uuid)
returns public.member_role
language sql stable security definer set search_path = '' as $$
  select role from public.conversation_members
   where conversation_id = p_conv and user_id = p_user and left_at is null
$$;

-- True when a direct conversation's two members have a block between them.
create or replace function private.direct_blocked(p_conv uuid)
returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.conversations c
    join public.conversation_members a on a.conversation_id = c.id
    join public.conversation_members b on b.conversation_id = c.id and b.user_id <> a.user_id
    where c.id = p_conv and c.kind = 'direct' and private.is_blocked_either(a.user_id, b.user_id))
$$;

-- Content visibility: not deleted, not expired (unless someone saved it).
create or replace function private.message_content_visible(p_msg uuid)
returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.messages m
    where m.id = p_msg and m.deleted_at is null
      and (m.expires_at is null or m.expires_at > now()
           or exists (select 1 from public.saved_messages s where s.message_id = m.id)))
$$;

create or replace function private.can_read_message(p_msg uuid, p_user uuid)
returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (
    select 1 from public.messages m
    join public.conversation_members cm
      on cm.conversation_id = m.conversation_id and cm.user_id = p_user and cm.left_at is null
    where m.id = p_msg and m.created_at >= cm.joined_at
      and not private.direct_blocked(m.conversation_id))
$$;

-- ---------------------------------------------------------------------------
-- RLS (reads only; every write is an RPC)
-- ---------------------------------------------------------------------------
alter table public.conversations enable row level security;
alter table public.conversation_members enable row level security;
alter table public.messages enable row level security;
alter table public.message_reads enable row level security;
alter table public.saved_messages enable row level security;
alter table public.message_reactions enable row level security;

revoke all on public.conversations, public.conversation_members, public.messages,
  public.message_reads, public.saved_messages, public.message_reactions from anon, authenticated;
grant select on public.conversations, public.conversation_members, public.messages,
  public.message_reads, public.saved_messages, public.message_reactions to authenticated;

create policy conv_member on public.conversations for select to authenticated
  using (private.is_member(id));
create policy members_of_my_convs on public.conversation_members for select to authenticated
  using (private.is_member(conversation_id));
-- Members see visible messages, plus content-free tombstones of deleted ones so that
-- deletions propagate to every device through Realtime.
create policy messages_member on public.messages for select to authenticated
  using (private.can_read_message(id, auth.uid())
         and (deleted_at is not null or private.message_content_visible(id)));
create policy reads_member on public.message_reads for select to authenticated
  using (private.can_read_message(message_id, auth.uid()));
create policy saved_member on public.saved_messages for select to authenticated
  using (private.can_read_message(message_id, auth.uid()));
create policy reactions_member on public.message_reactions for select to authenticated
  using (private.can_read_message(message_id, auth.uid())
         and private.message_content_visible(message_id));

-- ---------------------------------------------------------------------------
-- Conversation management
-- ---------------------------------------------------------------------------
create or replace function public.create_direct_conversation(p_friend uuid)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_key text; v_id uuid;
begin
  if p_friend = v_uid then perform private.fail('invalid_target'); end if;
  perform private.assert_can_interact(v_uid, p_friend);
  if not private.are_friends(v_uid, p_friend) then perform private.fail('not_friends'); end if;
  v_key := least(v_uid, p_friend)::text || ':' || greatest(v_uid, p_friend)::text;
  insert into public.conversations (kind, direct_key, created_by) values ('direct', v_key, v_uid)
  on conflict (direct_key) do update set direct_key = excluded.direct_key
  returning id into v_id;
  insert into public.conversation_members (conversation_id, user_id) values (v_id, v_uid), (v_id, p_friend)
  on conflict (conversation_id, user_id) do update set left_at = null;
  return v_id;
end $$;

create or replace function public.create_group(p_name text, p_members uuid[])
returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_id uuid; m uuid;
begin
  perform private.rate_limit_hit('create_group', 20, interval '1 day');
  if coalesce(array_length(p_members, 1), 0) < 1 then perform private.fail('group_needs_members'); end if;
  if array_length(p_members, 1) > 31 then perform private.fail('group_too_large', '32'); end if;
  insert into public.conversations (kind, name, created_by) values ('group', btrim(p_name), v_uid)
  returning id into v_id;
  insert into public.conversation_members (conversation_id, user_id, role) values (v_id, v_uid, 'owner');
  foreach m in array p_members loop
    if m = v_uid then continue; end if;
    perform private.assert_can_interact(v_uid, m);
    if not private.are_friends(v_uid, m) then perform private.fail('not_friends', m::text); end if;
    insert into public.conversation_members (conversation_id, user_id) values (v_id, m)
    on conflict do nothing;
  end loop;
  return v_id;
end $$;

create or replace function public.add_group_members(p_conv uuid, p_members uuid[])
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_role public.member_role; m uuid; v_count integer;
begin
  v_role := private.member_role(p_conv, v_uid);
  if v_role is null or v_role = 'member'
     or (select kind from public.conversations where id = p_conv) <> 'group' then
    perform private.fail('not_allowed');
  end if;
  foreach m in array p_members loop
    perform private.assert_can_interact(v_uid, m);
    if not private.are_friends(v_uid, m) then perform private.fail('not_friends', m::text); end if;
    insert into public.conversation_members (conversation_id, user_id) values (p_conv, m)
    on conflict (conversation_id, user_id) do update
      set left_at = null, joined_at = now(), role = 'member'
      where public.conversation_members.left_at is not null;
  end loop;
  select count(*) into v_count from public.conversation_members
   where conversation_id = p_conv and left_at is null;
  if v_count > 32 then perform private.fail('group_too_large', '32'); end if;
end $$;

-- Owners remove anyone but themselves; admins remove ordinary members only.
create or replace function public.remove_group_member(p_conv uuid, p_user uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_mine public.member_role; v_theirs public.member_role;
begin
  v_mine := private.member_role(p_conv, v_uid);
  v_theirs := private.member_role(p_conv, p_user);
  if v_theirs is null then perform private.fail('not_a_member'); end if;
  if v_mine is null or p_user = v_uid or v_theirs = 'owner'
     or (v_mine = 'admin' and v_theirs <> 'member') or v_mine = 'member' then
    perform private.fail('not_allowed');
  end if;
  update public.conversation_members set left_at = now(), pinned_rank = null, role = 'member'
   where conversation_id = p_conv and user_id = p_user;
end $$;

create or replace function public.set_group_role(p_conv uuid, p_user uuid, p_role public.member_role)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active();
begin
  if private.member_role(p_conv, v_uid) is distinct from 'owner'::public.member_role
     or p_role = 'owner' or p_user = v_uid or private.member_role(p_conv, p_user) is null then
    perform private.fail('not_allowed');
  end if;
  update public.conversation_members set role = p_role
   where conversation_id = p_conv and user_id = p_user and left_at is null;
end $$;

-- The only path by which ownership changes hands; initiated by the current owner.
create or replace function public.transfer_group_ownership(p_conv uuid, p_new_owner uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active();
begin
  if private.member_role(p_conv, v_uid) is distinct from 'owner'::public.member_role
     or private.member_role(p_conv, p_new_owner) is null or p_new_owner = v_uid then
    perform private.fail('not_allowed');
  end if;
  update public.conversation_members set role = 'admin'
   where conversation_id = p_conv and user_id = v_uid;
  update public.conversation_members set role = 'owner'
   where conversation_id = p_conv and user_id = p_new_owner;
end $$;

create or replace function public.leave_group(p_conv uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_role public.member_role; v_others integer;
begin
  v_role := private.member_role(p_conv, v_uid);
  if v_role is null or (select kind from public.conversations where id = p_conv) <> 'group' then
    perform private.fail('not_allowed');
  end if;
  select count(*) into v_others from public.conversation_members
   where conversation_id = p_conv and left_at is null and user_id <> v_uid;
  if v_role = 'owner' and v_others > 0 then perform private.fail('transfer_ownership_first'); end if;
  update public.conversation_members set left_at = now(), pinned_rank = null, role = 'member'
   where conversation_id = p_conv and user_id = v_uid;
end $$;

create or replace function public.update_group(p_conv uuid, p_name text, p_description text,
                                               p_theme jsonb default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_role public.member_role := private.member_role(p_conv, v_uid);
begin
  if v_role is null or v_role = 'member' then perform private.fail('not_allowed'); end if;
  update public.conversations
     set name = coalesce(btrim(p_name), name), description = p_description,
         theme = coalesce(p_theme, theme)
   where id = p_conv and kind = 'group';
end $$;

-- Direct chats: either member. Groups: owner/admin.
create or replace function public.set_chat_expiry(p_conv uuid, p_mode public.expiry_mode)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_role public.member_role := private.member_role(p_conv, v_uid);
        v_kind public.conversation_kind;
begin
  select kind into v_kind from public.conversations where id = p_conv;
  if v_role is null or (v_kind = 'group' and v_role = 'member') then
    perform private.fail('not_allowed');
  end if;
  update public.conversations set expiry_mode = p_mode where id = p_conv;
end $$;

-- ---------------------------------------------------------------------------
-- Messages
-- ---------------------------------------------------------------------------
create or replace function public.send_message(
  p_conv uuid, p_kind public.message_kind, p_body text, p_client_msg_id uuid,
  p_media_asset uuid default null, p_reply_to uuid default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.assert_active();
  v_id uuid;
  a public.media_assets;
begin
  if p_client_msg_id is null then perform private.fail('client_msg_id_required'); end if;
  -- Idempotent retry: return the message already created for this client id.
  select id into v_id from public.messages where sender_id = v_uid and client_msg_id = p_client_msg_id;
  if v_id is not null then return v_id; end if;

  perform private.rate_limit_hit('send_message', 60, interval '1 minute');
  if not private.is_member(p_conv, v_uid) then perform private.fail('not_a_member'); end if;
  if private.direct_blocked(p_conv) then perform private.fail('not_allowed'); end if;
  if p_kind in ('snap', 'system') then perform private.fail('invalid_kind'); end if;

  if p_kind = 'text' then
    if p_body is null or char_length(btrim(p_body)) = 0 then perform private.fail('empty_message'); end if;
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

  if p_reply_to is not null and not exists (
       select 1 from public.messages r where r.id = p_reply_to and r.conversation_id = p_conv
         and private.message_content_visible(r.id)) then
    perform private.fail('reply_target_unavailable');
  end if;

  insert into public.messages (conversation_id, sender_id, kind, body, media_asset_id,
                               reply_to_id, client_msg_id)
  values (p_conv, v_uid, p_kind, nullif(btrim(p_body), ''), p_media_asset, p_reply_to, p_client_msg_id)
  on conflict (sender_id, client_msg_id) do nothing
  returning id into v_id;
  if v_id is null then  -- lost a race with a concurrent identical retry
    select id into v_id from public.messages where sender_id = v_uid and client_msg_id = p_client_msg_id;
  end if;
  update public.conversations set last_message_at = now() where id = p_conv;
  return v_id;
end $$;

create or replace function public.edit_message(p_msg uuid, p_body text)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); m public.messages;
begin
  select * into m from public.messages where id = p_msg for update;
  if m.id is null or m.sender_id <> v_uid or not private.message_content_visible(m.id) then
    perform private.fail('message_not_found');
  end if;
  if m.kind <> 'text' then perform private.fail('not_editable'); end if;
  if m.created_at < now() - (private.config()).message_edit_window then
    perform private.fail('edit_window_closed');
  end if;
  if p_body is null or char_length(btrim(p_body)) = 0 then perform private.fail('empty_message'); end if;
  insert into private.message_edits (message_id, previous_body) values (m.id, m.body);
  update public.messages set body = btrim(p_body), edited_at = now() where id = m.id;
end $$;

-- Deletion leaves a content-free tombstone that propagates to all devices; the purge
-- job removes tombstones later. Report evidence snapshots are unaffected.
create or replace function public.delete_message(p_msg uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); m public.messages;
begin
  if v_uid is null then perform private.fail('not_authenticated'); end if;
  select * into m from public.messages where id = p_msg for update;
  if m.id is null or m.sender_id <> v_uid or m.deleted_at is not null then
    perform private.fail('message_not_found');
  end if;
  update public.messages set deleted_at = now(), body = null, media_asset_id = null where id = m.id;
  delete from public.message_reactions where message_id = m.id;
  delete from public.saved_messages where message_id = m.id;
  delete from private.message_edits where message_id = m.id;
  if m.media_asset_id is not null then perform private.request_asset_deletion(m.media_asset_id); end if;
end $$;

-- Marks everything visible in the conversation as read and starts expiry timers for
-- messages that every other member has now viewed.
create or replace function public.mark_conversation_read(p_conv uuid)
returns integer
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_mode public.expiry_mode; v_n integer;
begin
  if not private.is_member(p_conv, v_uid) then perform private.fail('not_a_member'); end if;
  select expiry_mode into v_mode from public.conversations where id = p_conv;

  with newly as (
    insert into public.message_reads (message_id, user_id)
    select m.id, v_uid from public.messages m
    join public.conversation_members cm on cm.conversation_id = m.conversation_id and cm.user_id = v_uid
    where m.conversation_id = p_conv and m.sender_id <> v_uid and m.deleted_at is null
      and m.created_at >= cm.joined_at and m.kind <> 'snap'
      and (m.expires_at is null or m.expires_at > now())
    on conflict do nothing
    returning message_id
  )
  update public.messages m
     set expires_at = case v_mode
           when 'after_view' then now()
           when 'after_view_24h' then now() + interval '24 hours'
           when 'after_view_7d' then now() + interval '7 days' end
   where m.id in (select message_id from newly)
     and v_mode <> 'never' and m.expires_at is null
     and not exists (  -- every other active member (who joined before it) has read it
       select 1 from public.conversation_members o
       where o.conversation_id = m.conversation_id and o.left_at is null
         and o.user_id <> m.sender_id and o.joined_at <= m.created_at
         and o.user_id <> v_uid
         and not exists (select 1 from public.message_reads r
                         where r.message_id = m.id and r.user_id = o.user_id));
  get diagnostics v_n = row_count;
  update public.conversation_members set last_read_at = now()
   where conversation_id = p_conv and user_id = v_uid;
  return v_n;
end $$;

create or replace function public.toggle_reaction(p_msg uuid, p_emoji text)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_n integer;
begin
  perform private.rate_limit_hit('toggle_reaction', 120, interval '1 minute');
  if not private.can_read_message(p_msg, v_uid) or not private.message_content_visible(p_msg) then
    perform private.fail('message_not_found');
  end if;
  delete from public.message_reactions where message_id = p_msg and user_id = v_uid and emoji = p_emoji;
  get diagnostics v_n = row_count;
  if v_n > 0 then return false; end if;
  insert into public.message_reactions (message_id, user_id, emoji) values (p_msg, v_uid, p_emoji);
  return true;
end $$;

create or replace function public.set_message_saved(p_msg uuid, p_saved boolean)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_kind public.message_kind;
begin
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

-- Pins are personal. Passing null unpins. Ranks 1..3 are swapped if occupied.
create or replace function public.set_pin(p_conv uuid, p_rank smallint)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_old smallint;
begin
  if not private.is_member(p_conv, v_uid) then perform private.fail('not_a_member'); end if;
  if p_rank is not null and p_rank not between 1 and 3 then perform private.fail('max_three_pins'); end if;
  select pinned_rank into v_old from public.conversation_members
   where conversation_id = p_conv and user_id = v_uid for update;
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
  update public.conversation_members set muted_until = p_until
   where conversation_id = p_conv and user_id = v_uid and left_at is null;
end $$;

-- ---------------------------------------------------------------------------
-- Chat list: status labels only — never message bodies.
-- ---------------------------------------------------------------------------
create or replace function public.chat_list()
returns table (conversation_id uuid, kind public.conversation_kind, title text,
               other_user_id uuid, title_color text, label text, unread boolean,
               last_activity timestamptz, pinned_rank smallint, muted boolean)
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active();
begin
  return query
  with mine as (
    select cm.conversation_id, cm.pinned_rank, cm.muted_until, cm.joined_at
    from public.conversation_members cm where cm.user_id = v_uid and cm.left_at is null
  ), other_member as (
    select c.id as conversation_id, om.user_id
    from public.conversations c
    join public.conversation_members om on om.conversation_id = c.id and om.user_id <> v_uid
    where c.kind = 'direct'
  ), last_msg as (
    select distinct on (m.conversation_id) m.conversation_id, m.id, m.sender_id, m.kind, m.created_at
    from public.messages m join mine on mine.conversation_id = m.conversation_id
    where m.deleted_at is null and m.created_at >= mine.joined_at
      and (m.expires_at is null or m.expires_at > now()
           or exists (select 1 from public.saved_messages s where s.message_id = m.id))
    order by m.conversation_id, m.created_at desc
  )
  select c.id, c.kind,
    case when c.kind = 'group' then c.name
         else coalesce(n.nickname, p.display_name) end,
    om.user_id,
    n.color,
    case
      when lm.id is null then 'Start chatting'
      when lm.sender_id <> v_uid and not exists (select 1 from public.message_reads r
             where r.message_id = lm.id and r.user_id = v_uid)
           and not (lm.kind = 'snap' and exists (select 1 from public.snap_recipients sr
             join public.messages sm on sm.snap_id = sr.snap_id
             where sm.id = lm.id and sr.recipient_id = v_uid and sr.status <> 'delivered'))
        then case when lm.kind = 'snap' then 'New Snap' else 'New Chat' end
      when lm.sender_id <> v_uid then 'Received'
      when not exists (
             select 1 from public.conversation_members o
             where o.conversation_id = c.id and o.user_id <> v_uid and o.left_at is null
               and not exists (select 1 from public.message_reads r
                               where r.message_id = lm.id and r.user_id = o.user_id)
               and not exists (select 1 from public.snap_recipients sr
                               join public.messages sm on sm.snap_id = sr.snap_id
                               where sm.id = lm.id and sr.recipient_id = o.user_id
                                 and sr.status <> 'delivered'))
        then 'Opened'
      else 'Delivered'
    end,
    lm.sender_id is not null and lm.sender_id <> v_uid and not exists (
      select 1 from public.message_reads r where r.message_id = lm.id and r.user_id = v_uid),
    greatest(c.last_message_at, coalesce(lm.created_at, c.created_at)),
    mine.pinned_rank,
    coalesce(mine.muted_until > now(), false)
  from mine
  join public.conversations c on c.id = mine.conversation_id
  left join other_member om on om.conversation_id = c.id
  left join public.profiles p on p.id = om.user_id
  left join public.friend_nicknames n on n.owner_id = v_uid and n.friend_id = om.user_id
  left join last_msg lm on lm.conversation_id = c.id
  where not (c.kind = 'direct' and om.user_id is not null and private.is_blocked_either(v_uid, om.user_id))
  order by mine.pinned_rank nulls last, 8 desc;
end $$;

-- Participants with the viewer's private nicknames applied.
create or replace function public.conversation_participants(p_conv uuid)
returns table (user_id uuid, username text, display_name text, nickname text,
               nickname_color text, avatar_asset_id uuid, role public.member_role)
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active();
begin
  if not private.is_member(p_conv, v_uid) then perform private.fail('not_a_member'); end if;
  return query
    select p.id, p.username::text, p.display_name, n.nickname, n.color, p.avatar_asset_id, cm.role
    from public.conversation_members cm
    join public.profiles p on p.id = cm.user_id
    left join public.friend_nicknames n on n.owner_id = v_uid and n.friend_id = p.id
    where cm.conversation_id = p_conv and cm.left_at is null
    order by cm.role, p.username;
end $$;

-- Search only what the caller can currently read; expired/deleted never return.
create or replace function public.search_messages(
  p_query text default null, p_sender uuid default null, p_from timestamptz default null,
  p_to timestamptz default null, p_saved_only boolean default false,
  p_kinds public.message_kind[] default null, p_conv uuid default null, p_limit integer default 50)
returns table (message_id uuid, conversation_id uuid, sender_id uuid, kind public.message_kind,
               body text, created_at timestamptz, saved boolean)
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active();
begin
  perform private.rate_limit_hit('search_messages', 30, interval '1 minute');
  return query
    select m.id, m.conversation_id, m.sender_id, m.kind, m.body, m.created_at,
           exists (select 1 from public.saved_messages s where s.message_id = m.id)
    from public.messages m
    join public.conversation_members cm
      on cm.conversation_id = m.conversation_id and cm.user_id = v_uid and cm.left_at is null
    where m.created_at >= cm.joined_at
      and m.deleted_at is null
      and m.kind <> 'snap'
      and (m.expires_at is null or m.expires_at > now()
           or exists (select 1 from public.saved_messages s where s.message_id = m.id))
      and not private.direct_blocked(m.conversation_id)
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

-- Shared media gallery: photos, videos, voice notes, links, saved messages.
create or replace function public.conversation_gallery(p_conv uuid, p_filter text default 'all')
returns table (message_id uuid, kind public.message_kind, media_asset_id uuid, body text,
               created_at timestamptz, saved boolean)
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active();
begin
  if not private.is_member(p_conv, v_uid) then perform private.fail('not_a_member'); end if;
  if p_filter not in ('all','photos','videos','voice','links','saved') then
    perform private.fail('invalid_filter');
  end if;
  return query
    select g.message_id, g.kind, m.media_asset_id, g.body, g.created_at, g.saved
    from public.search_messages(null, null, null, null, false, null, p_conv, 100) g
    join public.messages m on m.id = g.message_id
    where (p_filter = 'all' and (m.media_asset_id is not null or m.body ~* 'https?://'))
       or (p_filter = 'photos' and m.kind = 'photo')
       or (p_filter = 'videos' and m.kind = 'video')
       or (p_filter = 'voice' and m.kind = 'voice')
       or (p_filter = 'links' and m.body ~* 'https?://')
       or (p_filter = 'saved' and g.saved);
end $$;

grant execute on function
  public.create_direct_conversation(uuid), public.create_group(text, uuid[]),
  public.add_group_members(uuid, uuid[]), public.remove_group_member(uuid, uuid),
  public.set_group_role(uuid, uuid, public.member_role), public.transfer_group_ownership(uuid, uuid),
  public.leave_group(uuid), public.update_group(uuid, text, text, jsonb),
  public.set_chat_expiry(uuid, public.expiry_mode),
  public.send_message(uuid, public.message_kind, text, uuid, uuid, uuid),
  public.edit_message(uuid, text), public.delete_message(uuid),
  public.mark_conversation_read(uuid), public.toggle_reaction(uuid, text),
  public.set_message_saved(uuid, boolean), public.set_pin(uuid, smallint),
  public.set_mute(uuid, timestamptz), public.chat_list(), public.conversation_participants(uuid),
  public.search_messages(text, uuid, timestamptz, timestamptz, boolean, public.message_kind[], uuid, integer),
  public.conversation_gallery(uuid, text)
  to authenticated;
