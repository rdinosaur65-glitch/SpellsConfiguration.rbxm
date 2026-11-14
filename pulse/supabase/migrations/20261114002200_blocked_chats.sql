-- PULSE 0022 — blocked chats stay visible to the person who blocked, with a way to erase
-- them. The blocked person still sees nothing (the chat is hidden from them as before).

drop function if exists public.chat_list();
create or replace function public.chat_list()
returns table (conversation_id uuid, kind public.conversation_kind, title text,
               other_user_id uuid, title_color text, label text, unread boolean,
               last_activity timestamptz, pinned_rank smallint, muted boolean, blocked boolean)
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
  -- blocked, so I can delete it.
  where not (c.kind = 'direct' and om.user_id is not null and exists (
               select 1 from public.blocks b where b.blocker_id = om.user_id and b.blocked_id = v_uid))
  order by mine.pinned_rank nulls last, 8 desc;
end $$;
revoke execute on function public.chat_list() from public, anon;
grant execute on function public.chat_list() to authenticated;

-- Permanently erase a direct chat with someone the caller has blocked: messages, receipts,
-- reactions, saves, Snap deliveries and media, for both people. Reports keep their own
-- evidence snapshot (their links to the chat become null), so moderation is unaffected.
create or replace function public.delete_blocked_chat(p_conv uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); c public.conversations; v_other uuid; v_assets uuid[];
        v_snaps uuid[]; v_snap_assets uuid[];
begin
  perform private.rate_limit_hit('delete_blocked_chat', 30, interval '1 hour');
  select * into c from public.conversations where id = p_conv for update;
  if c.id is null or c.kind <> 'direct' or not exists (
       select 1 from public.conversation_members where conversation_id = p_conv and user_id = v_uid) then
    perform private.fail('not_a_member');
  end if;
  select user_id into v_other from public.conversation_members where conversation_id = p_conv and user_id <> v_uid;
  if not exists (select 1 from public.blocks where blocker_id = v_uid and blocked_id = v_other) then
    perform private.fail('not_allowed');           -- only the person who blocked can erase it
  end if;
  select coalesce(array_agg(distinct media_asset_id) filter (where media_asset_id is not null), '{}')
    into v_assets from public.messages where conversation_id = p_conv;
  select coalesce(array_agg(distinct snap_id), '{}') into v_snaps
    from public.snap_recipients where conversation_id = p_conv;
  delete from public.conversations where id = p_conv;   -- cascades to every row of the chat
  -- Snaps that were only delivered in this chat go too (with their media); a Snap also sent
  -- to other people stays for them.
  with gone as (
    delete from public.snaps s where s.id = any (v_snaps)
       and not exists (select 1 from public.snap_recipients r where r.snap_id = s.id)
    returning s.media_asset_id)
  select coalesce(array_agg(media_asset_id) filter (where media_asset_id is not null), '{}') into v_snap_assets from gone;
  perform private.release_asset_if_unreferenced(x) from unnest(v_assets || v_snap_assets) x;
end $$;
revoke execute on function public.delete_blocked_chat(uuid) from public, anon;
grant execute on function public.delete_blocked_chat(uuid) to authenticated;
