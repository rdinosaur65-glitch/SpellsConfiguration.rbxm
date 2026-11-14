-- PULSE 0025 — removing a chat is a per-person visibility setting, not a deletion.
--
-- Replaces delete_blocked_chat (0022), which erased the chat for both people. Pressing ×
-- on a blocked chat now hides it from the presser's own list only (conversation_members.
-- hidden_at, which only that member can read). The conversation, every message, receipt,
-- Snap and file stay exactly as they were for the other person. Blocking itself is
-- unchanged: the blocked person still cannot see or use the chat while the block lasts.
-- The setting lives in the database, so it holds on every device and after signing in again.
-- A removed chat comes back for that person when something new is said in it later (after
-- an unblock and a new friendship) or when they open it again from Friends.

drop function if exists public.delete_blocked_chat(uuid);

alter table public.conversation_members add column if not exists hidden_at timestamptz;

create or replace function public.hide_chat(p_conv uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_other uuid;
begin
  perform private.rate_limit_hit('hide_chat', 60, interval '1 hour');
  if not exists (select 1 from public.conversation_members cm join public.conversations c on c.id = cm.conversation_id
                  where cm.conversation_id = p_conv and cm.user_id = v_uid and cm.left_at is null and c.kind = 'direct') then
    perform private.fail('not_a_member');
  end if;
  select user_id into v_other from public.conversation_members where conversation_id = p_conv and user_id <> v_uid;
  -- Only a chat with someone I have blocked shows the × (and can be removed this way).
  if not exists (select 1 from public.blocks where blocker_id = v_uid and blocked_id = v_other) then
    perform private.fail('not_allowed');
  end if;
  update public.conversation_members set hidden_at = now(), pinned_rank = null
   where conversation_id = p_conv and user_id = v_uid;
end $$;
revoke execute on function public.hide_chat(uuid) from public, anon;
grant execute on function public.hide_chat(uuid) to authenticated;

create or replace function public.chat_list()
returns table (conversation_id uuid, kind public.conversation_kind, title text,
               other_user_id uuid, title_color text, label text, unread boolean,
               last_activity timestamptz, pinned_rank smallint, muted boolean, blocked boolean)
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_peers uuid[] := private.my_block_peers();
begin
  return query
  with mine as (
    select cm.conversation_id, cm.pinned_rank, cm.muted_until, cm.joined_at, cm.hidden_at
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
      when c.kind = 'direct' and exists (select 1 from public.blocks b where b.blocker_id = v_uid and b.blocked_id = om.user_id)
        then 'Blocked'
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
    coalesce(st.is_unread, false) and not (c.kind = 'direct' and om.user_id is not null and exists (
       select 1 from public.blocks b where b.blocker_id = v_uid and b.blocked_id = om.user_id)),
    greatest(c.last_message_at, coalesce(st.created_at, c.created_at)),
    mine.pinned_rank,
    coalesce(mine.muted_until > now(), false),
    (c.kind = 'direct' and om.user_id is not null and exists (
       select 1 from public.blocks b where b.blocker_id = v_uid and b.blocked_id = om.user_id))
  from mine
  join public.conversations c on c.id = mine.conversation_id
  left join other_member om on om.conversation_id = c.id
  left join public.profiles p on p.id = om.user_id
  left join public.friend_nicknames n on n.owner_id = v_uid and n.friend_id = om.user_id
  left join state st on st.conversation_id = c.id
  -- A chat with someone who blocked me is hidden; one with someone I blocked stays, marked
  -- blocked, until I remove it from my list (hide_chat). A chat I removed comes back only
  -- when something new is said in it after that moment.
  where not (c.kind = 'direct' and om.user_id is not null and exists (
               select 1 from public.blocks b where b.blocker_id = om.user_id and b.blocked_id = v_uid))
    and (mine.hidden_at is null or exists (
           select 1 from public.messages m
            where m.conversation_id = c.id and m.created_at > mine.hidden_at
              and m.deleted_at is null and m.sender_id <> all (v_peers)))
  order by mine.pinned_rank nulls last, 8 desc;
end $$;
revoke execute on function public.chat_list() from public, anon;
grant execute on function public.chat_list() to authenticated;

create or replace function public.create_direct_conversation(p_friend uuid)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_conv uuid;
begin
  perform private.rate_limit_hit('create_direct_conversation', 120, interval '1 hour');
  if p_friend = v_uid then perform private.fail('invalid_target'); end if;
  if not private.are_friends(v_uid, p_friend) then perform private.fail('not_friends'); end if;
  perform private.assert_can_interact(v_uid, p_friend);
  v_conv := private.ensure_direct_conversation(v_uid, p_friend);
  -- Opening the chat again (from Friends) puts it back in my list if I had removed it.
  update public.conversation_members set hidden_at = null
   where conversation_id = v_conv and user_id = v_uid and hidden_at is not null;
  return v_conv;
end $$;
revoke execute on function public.create_direct_conversation(uuid) from public, anon;
grant execute on function public.create_direct_conversation(uuid) to authenticated;
