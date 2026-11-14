-- PULSE 0024 — fixes from the final review.
--
-- 1. Snap views: authorize_snap_media now locks the recipient row (as open_snap and
--    close_snap_view do). Before, a close racing an authorisation could refund a view
--    whose bytes were being served, so a scripted client could watch a Snap without it
--    ever counting or showing as opened.
-- 2. Lock order: everything that changes a chat's membership takes the chat's read lock
--    first, the same order as mark_conversation_read, so a removal/leave racing a read can
--    no longer deadlock.
-- 3. Owner powers need a two-step-verified session (aal2) — the owner must have 2FA on.
--    A stolen owner password alone no longer opens moderation or 2FA resets.
-- 4. Download budget: media passes through media-url, so each view leaves Supabase twice
--    (Storage → function → browser). The daily budget is lowered to leave room for that
--    and for API/realtime traffic within the Free plan's ~5 GB a month.

-- 1 ---------------------------------------------------------------------------------
create or replace function public.authorize_snap_media(p_snap uuid, p_session uuid)
returns table (bucket text, object_path text, mime_type text, valid_seconds integer)
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); r public.snap_recipients; a public.media_assets;
        v_sender uuid;
begin
  perform private.rate_limit_hit('authorize_snap_media', 30, interval '1 minute');
  -- Locked: a concurrent close_snap_view waits, then sees the view was served.
  select * into r from public.snap_recipients where snap_id = p_snap and recipient_id = v_uid for update;
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
  if not r.session_served then          -- no repeated writes to a Realtime-published row
    update public.snap_recipients set session_served = true
     where snap_id = p_snap and recipient_id = v_uid and session_id = p_session;
  end if;
  return query select a.bucket, a.object_path, a.mime_type,
    least(60, greatest(1, ceil(extract(epoch from r.session_deadline - now()))::integer));
end $$;

-- 2 ---------------------------------------------------------------------------------
create or replace function private.lock_conv(p_conv uuid)
returns void
language sql volatile set search_path = '' as $$
  select pg_advisory_xact_lock(hashtext('pulse_conv_read'), hashtext(p_conv::text))
$$;
revoke execute on function private.lock_conv(uuid) from public, anon, authenticated;

create or replace function private.detach_member(p_conv uuid, p_user uuid)
returns void
language plpgsql security definer set search_path = '' as $$
begin
  perform private.lock_conv(p_conv);           -- before any member row, as readers do
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

create or replace function public.remove_group_member(p_conv uuid, p_user uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_mine public.member_role; v_theirs public.member_role;
begin
  perform private.rate_limit_hit('group_admin', 60, interval '1 hour');
  perform private.lock_conv(p_conv);
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

create or replace function public.leave_group(p_conv uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_role public.member_role; v_others integer;
begin
  perform private.rate_limit_hit('leave_group', 30, interval '1 hour');
  perform private.lock_conv(p_conv);
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

-- 3 ---------------------------------------------------------------------------------
create or replace function private.assert_owner()
returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then perform private.fail('forbidden'); end if;
  perform private.assert_mfa();
  if not private.is_owner(v_uid) then perform private.fail('forbidden'); end if;
  -- Owner powers always need a session verified with the owner's own second factor.
  if coalesce(auth.jwt() ->> 'aal', 'aal1') <> 'aal2' then perform private.fail('owner_mfa_required'); end if;
  return v_uid;
end $$;

-- 4 ---------------------------------------------------------------------------------
alter table private.platform_config
  alter column daily_egress_budget_bytes set default 73400320,     -- 70 MiB a day
  alter column daily_egress_user_bytes set default 26214400;       -- 25 MiB a person after their first download
update private.platform_config set daily_egress_budget_bytes = 73400320 where daily_egress_budget_bytes = 167772160;
update private.platform_config set daily_egress_user_bytes = 26214400 where daily_egress_user_bytes = 41943040;
