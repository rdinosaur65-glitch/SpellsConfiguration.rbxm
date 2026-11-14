-- PULSE 0020 — third pass: guards and limits on every remaining write path, and reads
-- marked by message id.
--  * Reports go through the database-size guard and the daily text quota, and reporting the
--    same message or account again returns the existing open report.
--  * Rate limits on the remaining client write RPCs (test 80 now enforces this), no-op
--    suppression for role changes and Snap saves.
--  * mark_conversation_read(p_conv, p_ids): marks exactly the messages the client rendered.

-- Report guards: database size, text quota, one open report per target.
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
  select id into v_id from public.reports
   where reporter_id = v_uid and target_type = 'user' and target_user_id = p_user and status = 'open' limit 1;
  if v_id is not null then return v_id; end if;            -- already reported: no duplicate rows
  perform private.assert_db_headroom();
  perform private.charge_text(octet_length(coalesce(p_details, '')) + 200);
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

-- Report guards: database size, text quota, one open report per message.
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
  select id into v_id from public.reports
   where reporter_id = v_uid and target_message_id = m.id and status = 'open' limit 1;
  if v_id is not null then return v_id; end if;
  perform private.assert_db_headroom();
  perform private.charge_text(octet_length(coalesce(p_details, '')) + octet_length(coalesce(m.body, '')));
  insert into public.reports (reporter_id, target_type, target_user_id, target_message_id,
                              target_conversation_id, reason, details, evidence)
  values (v_uid, 'message', m.sender_id, m.id, m.conversation_id, p_reason, p_details,
          jsonb_build_object('kind', m.kind, 'body', m.body, 'sent_at', m.created_at,
                             'media_asset_id', m.media_asset_id, 'captured_at', now()))
  returning id into v_id;
  return v_id;
end $$;

-- Report guards for groups.
create or replace function public.report_group(p_conv uuid, p_reason public.report_reason,
                                               p_details text default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_id uuid;
begin
  perform private.rate_limit_hit('report', 20, interval '1 hour');
  if not private.is_member(p_conv, v_uid)
     or (select kind from public.conversations where id = p_conv) <> 'group' then
    perform private.fail('not_a_member');
  end if;
  select id into v_id from public.reports
   where reporter_id = v_uid and target_type = 'group' and target_conversation_id = p_conv and status = 'open' limit 1;
  if v_id is not null then return v_id; end if;
  perform private.assert_db_headroom();
  perform private.charge_text(octet_length(coalesce(p_details, '')) + 200);
  insert into public.reports (reporter_id, target_type, target_conversation_id, reason, details, evidence)
  select v_uid, 'group', c.id, p_reason, p_details,
         jsonb_build_object('name', c.name, 'description', c.description, 'captured_at', now())
  from public.conversations c where c.id = p_conv
  returning id into v_id;
  return v_id;
end $$;

-- Rate-limited; no-op role changes write nothing.
create or replace function public.set_group_role(p_conv uuid, p_user uuid, p_role public.member_role)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active();
begin
  perform private.rate_limit_hit('group_admin', 60, interval '1 hour');
  if private.member_role(p_conv, v_uid) is distinct from 'owner'::public.member_role
     or p_role = 'owner' or p_user = v_uid or private.member_role(p_conv, p_user) is null then
    perform private.fail('not_allowed');
  end if;
  update public.conversation_members set role = p_role
   where conversation_id = p_conv and user_id = p_user and left_at is null and role <> p_role;
end $$;

-- Rate-limited.
create or replace function public.remove_group_member(p_conv uuid, p_user uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_mine public.member_role; v_theirs public.member_role;
begin
  perform private.rate_limit_hit('group_admin', 60, interval '1 hour');
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

-- Rate-limited.
create or replace function public.transfer_group_ownership(p_conv uuid, p_new_owner uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active();
begin
  perform private.rate_limit_hit('group_admin', 60, interval '1 hour');
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

-- Rate-limited.
create or replace function public.leave_group(p_conv uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_role public.member_role; v_others integer;
begin
  perform private.rate_limit_hit('leave_group', 30, interval '1 hour');
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

-- Rate-limited.
create or replace function public.respond_friend_request(p_request uuid, p_accept boolean)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); r public.friend_requests;
begin
  perform private.rate_limit_hit('respond_friend_request', 120, interval '1 hour');
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

-- Rate-limited.
create or replace function public.cancel_friend_request(p_request uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_n integer;
begin
  perform private.rate_limit_hit('cancel_friend_request', 120, interval '1 hour');
  update public.friend_requests set status = 'cancelled', responded_at = now()
   where id = p_request and sender_id = v_uid and status = 'pending';
  get diagnostics v_n = row_count;
  if v_n = 0 then perform private.fail('request_not_found'); end if;
end $$;

-- Rate-limited.
create or replace function public.confirm_upload(p_asset uuid)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.assert_active();
  a public.media_assets;
  o storage.objects;
  v_size bigint;
begin
  perform private.rate_limit_hit('confirm_upload', 240, interval '1 hour');
  select * into a from public.media_assets where id = p_asset for update;
  if a.id is null or a.owner_id <> v_uid then perform private.fail('asset_not_found'); end if;
  if a.status = 'uploaded' then return true; end if;       -- idempotent
  if a.status <> 'pending' then perform private.fail('asset_not_pending'); end if;

  select * into o from storage.objects where bucket_id = a.bucket and name = a.object_path;
  if o.id is null then perform private.fail('upload_missing'); end if;
  v_size := nullif(o.metadata ->> 'size', '')::bigint;
  if v_size is null or v_size > a.byte_size
     or coalesce(o.metadata ->> 'mimetype', '') <> a.mime_type then
    perform private.request_asset_deletion(a.id);
    return false;
  end if;

  -- Re-account with the real size (never more than reserved).
  update private.storage_pools set bytes_used = bytes_used - (a.byte_size - v_size)
   where pool = private.pool_for(a.purpose);
  update public.media_assets set status = 'uploaded', uploaded_at = now(), byte_size = v_size
   where id = a.id;
  return true;
end $$;

-- Rate-limited.
create or replace function public.close_snap_view(p_snap uuid, p_session uuid)
returns public.snap_status
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); r public.snap_recipients; v_status public.snap_status;
begin
  if v_uid is null then perform private.fail('not_authenticated'); end if;
  perform private.assert_mfa();
  perform private.rate_limit_hit('close_snap_view', 240, interval '1 minute');
  select * into r from public.snap_recipients
   where snap_id = p_snap and recipient_id = v_uid for update;
  if r.snap_id is null then perform private.fail('snap_not_found'); end if;
  if r.session_id is distinct from p_session then return r.status; end if;   -- stale/duplicate
  if not r.session_served then
    -- Nothing was shown: give the view back.
    update public.snap_recipients
       set session_id = null, session_deadline = null, views_used = greatest(r.views_used - 1, 0),
           status = case when r.views_used <= 1 then 'delivered'::public.snap_status else 'opened'::public.snap_status end,
           opened_at = case when r.views_used <= 1 then null else opened_at end
     where snap_id = p_snap and recipient_id = v_uid
    returning status into v_status;
    return v_status;
  end if;
  v_status := case when r.views_used >= 2 then 'expired'::public.snap_status else r.status end;
  update public.snap_recipients
     set session_id = null, session_deadline = null, status = v_status,
         expired_at = case when v_status = 'expired' then now() else expired_at end
   where snap_id = p_snap and recipient_id = v_uid;
  return v_status;
end $$;

-- Rate-limited.
create or replace function public.revoke_session(p_session uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then perform private.fail('not_authenticated'); end if;
  perform private.assert_mfa();
  perform private.rate_limit_hit('revoke_session', 60, interval '1 hour');
  delete from auth.sessions where id = p_session and user_id = v_uid;
  if not found then perform private.fail('session_not_found'); end if;
end $$;

-- Rate-limited.
create or replace function public.revoke_other_sessions()
returns integer
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then perform private.fail('not_authenticated'); end if;
  perform private.assert_mfa();
  perform private.rate_limit_hit('revoke_session', 60, interval '1 hour');
  return private.revoke_sessions(v_uid, nullif(auth.jwt() ->> 'session_id', '')::uuid);
end $$;

-- Saving twice writes nothing.
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
  update public.snap_recipients set saved_at = now()
   where snap_id = p_snap and recipient_id = v_uid and saved_at is null;   -- no repeated writes
end $$;

-- Reads can name the exact messages that were rendered (no timestamp-range guesses).
drop function if exists public.mark_conversation_read(uuid, timestamptz, timestamptz);
create or replace function public.mark_conversation_read(
  p_conv uuid, p_up_to timestamptz default null, p_from timestamptz default null, p_ids uuid[] default null)
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
    and (p_ids is null or m.id = any (p_ids))            -- exactly what the client rendered
  on conflict do nothing;
  get diagnostics v_new = row_count;
  if v_new > 0 then
    v_n := private.apply_expiry(p_conv);
    update public.conversation_members set last_read_at = now()
     where conversation_id = p_conv and user_id = v_uid;
  end if;
  return v_n;
end $$;
grant execute on function public.mark_conversation_read(uuid, timestamptz, timestamptz, uuid[]) to authenticated;

revoke execute on all functions in schema public from public, anon;
revoke execute on all functions in schema private from public, anon;
