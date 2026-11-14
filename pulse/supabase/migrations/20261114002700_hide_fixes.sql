-- PULSE 0027 — fixes from the review of the per-person chat hide (0025) and of 0024.
--
-- 1. A removed chat that comes back stays back: any new (non-system) message clears
--    hidden_at for everyone in the chat. Before, visibility was recomputed from whichever
--    newer messages still existed, so the chat vanished again when they expired or were
--    unsent, and re-blocking hid it at once. Clearing the member row also lets the other
--    devices pick the change up live, and a settings notice no longer brings it back.
-- 2. Blocking someone again shows the chat as Blocked (with its ×) even if it had been
--    removed during an earlier block.
-- 3. Blocking no longer deletes the other person's saves and reactions in the direct
--    chat (only in shared groups, as intended): a save is what keeps a disappearing message,
--    so deleting it purged history that must stay untouched.
-- 4. block_user takes the chat locks before deleting rows, like every membership change,
--    so it can no longer deadlock with a member leaving or being removed.
-- 5. The per-person download share really becomes 25 MiB: 0024 only changed rows still at
--    40 MiB, but 0017 had already raised them to 64 MiB. The check made before a Snap is
--    opened now follows the same "first download of the day is always allowed" rule as the
--    charge itself (0023), so the two cannot disagree.

create or replace function private.unhide_on_new_message()
returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  update public.conversation_members set hidden_at = null
   where conversation_id = new.conversation_id and hidden_at is not null;
  return null;
end $$;
revoke execute on function private.unhide_on_new_message() from public, anon, authenticated;
drop trigger if exists messages_unhide on public.messages;
create trigger messages_unhide after insert on public.messages
  for each row when (new.kind <> 'system') execute function private.unhide_on_new_message();

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
  -- blocked, until I remove it from my list (hide_chat). A removed chat comes back when a
  -- new message is posted in it (trigger below) or I open it again from Friends.
  where not (c.kind = 'direct' and om.user_id is not null and exists (
               select 1 from public.blocks b where b.blocker_id = om.user_id and b.blocked_id = v_uid))
    and mine.hidden_at is null
  order by mine.pinned_rank nulls last, 8 desc;
end $$;
revoke execute on function public.chat_list() from public, anon;
grant execute on function public.chat_list() to authenticated;

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
  -- Chat locks first, in a fixed order, as every membership change and read does
  -- (deleting rows below and then expiring would otherwise deadlock with a leave/removal).
  perform private.lock_conv(x.conversation_id) from (
    select a.conversation_id from public.conversation_members a
      join public.conversation_members b on b.conversation_id = a.conversation_id and b.user_id = p_target
     where a.user_id = v_uid order by a.conversation_id) x;
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
  -- Groups only: a direct chat is hidden from the blocked person while the block lasts, and
  -- its saves and reactions are part of each person's own history, which stays untouched.
  delete from public.saved_messages s using public.messages m, public.conversations c
   where m.id = s.message_id and c.id = m.conversation_id and c.kind = 'group'
     and ((s.user_id = v_uid and m.sender_id = p_target) or (s.user_id = p_target and m.sender_id = v_uid));
  delete from public.message_reactions x using public.messages m, public.conversations c
   where m.id = x.message_id and c.id = m.conversation_id and c.kind = 'group'
     and ((x.user_id = v_uid and m.sender_id = p_target) or (x.user_id = p_target and m.sender_id = v_uid));
  -- Blocking shows the chat in my list again (marked Blocked, with its ×), even if I had
  -- removed it during an earlier block.
  update public.conversation_members cm set hidden_at = null
    from public.conversations c
   where c.id = cm.conversation_id and c.kind = 'direct' and cm.user_id = v_uid and cm.hidden_at is not null
     and exists (select 1 from public.conversation_members o where o.conversation_id = cm.conversation_id and o.user_id = p_target);
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
revoke execute on function public.block_user(uuid) from public, anon;
grant execute on function public.block_user(uuid) to authenticated;

update private.platform_config set daily_egress_user_bytes = 26214400
 where daily_egress_user_bytes in (41943040, 67108864);

create or replace function private.egress_would_exceed(p_bytes bigint)
returns boolean
language sql stable security definer set search_path = '' as $$
  with used as (
    select coalesce((select egress_bytes from private.usage_daily
                      where user_id = auth.uid() and day = (now() at time zone 'utc')::date), 0) as mine,
           coalesce((select bytes from private.egress_daily
                      where day = (now() at time zone 'utc')::date), 0) as everyone)
  select (used.mine > 0 and used.mine + p_bytes > (private.config()).daily_egress_user_bytes)
      or used.everyone + p_bytes > (private.config()).daily_egress_budget_bytes
    from used
$$;
revoke execute on function private.egress_would_exceed(bigint) from public, anon, authenticated;
