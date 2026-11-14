-- PULSE 0018 — a Snap view counts only once its bytes were actually served.
-- open_snap starts a session; if media-url never released the bytes (egress limit, rate
-- limit, network) and the viewer closes the session, the view is given back instead of
-- destroying the Snap unseen. Opening without fetching shows nothing, so this is safe.

alter table public.snap_recipients add column if not exists session_served boolean not null default false;

-- New sessions start unserved.
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
  if not private.is_member(r.conversation_id, v_uid) then perform private.fail('snap_not_found'); end if;
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
  -- Do not use up a view that the egress limits would then refuse to show.
  if private.egress_would_exceed((select byte_size from public.media_assets where id = s.media_asset_id)) then
    perform private.fail('egress_quota_exceeded');
  end if;

  v_len := case
    when s.media_kind = 'video' then make_interval(secs => s.video_seconds::double precision + 3)
    when s.view_seconds is null then (private.config()).unlimited_view_max
    else make_interval(secs => s.view_seconds + 2) end;

  update public.snap_recipients
     set views_used = r.views_used + 1,
         status = case when r.views_used = 0 then 'opened'::public.snap_status else 'replayed' end,
         opened_at = coalesce(r.opened_at, now()),
         session_id = v_session, session_started_at = now(), session_deadline = now() + v_len,
         session_served = false
   where snap_id = r.snap_id and recipient_id = v_uid;

  return query select v_session, (r.views_used + 1)::smallint, now() + v_len, s.view_seconds,
                      (s.media_kind = 'photo' and s.view_seconds is null), s.allow_saving;
end $$;

-- Mark the session as served when the bytes are released.
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
     or private.is_blocked_either(v_uid, v_sender)
     or not private.is_member(r.conversation_id, v_uid) then
    perform private.fail('snap_session_invalid');
  end if;
  select m.* into a from public.snaps s join public.media_assets m on m.id = s.media_asset_id
   where s.id = p_snap and m.status = 'uploaded';
  if a.id is null then perform private.fail('snap_expired'); end if;
  perform private.charge_egress_for(a.id, a.byte_size);
  update public.snap_recipients set session_served = true
   where snap_id = p_snap and recipient_id = v_uid and session_id = p_session;
  return query select a.bucket, a.object_path, a.mime_type,
    least(60, greatest(1, ceil(extract(epoch from r.session_deadline - now()))::integer));
end $$;

-- Closing an unserved session refunds the view.
create or replace function public.close_snap_view(p_snap uuid, p_session uuid)
returns public.snap_status
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); r public.snap_recipients; v_status public.snap_status;
begin
  if v_uid is null then perform private.fail('not_authenticated'); end if;
  perform private.assert_mfa();
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
