-- PULSE 0006 — Snaps: delivery, server-enforced viewing sessions, single replay,
-- sender-controlled saving, expiry. The client timer is cosmetic; the server decides.
--
-- Lifecycle per recipient: delivered → opened (view 1) → replayed (view 2) → expired.
-- A view is a *session*. open_snap() starts one under a row lock, so two devices (or
-- two concurrent requests) can never obtain more than the allowed number of views.
-- Media bytes are only released by authorize_snap_media() while a session is live.

create type public.snap_status as enum ('delivered', 'opened', 'replayed', 'expired');

create table public.snaps (
  id uuid primary key default gen_random_uuid(),
  sender_id uuid not null references public.profiles(id) on delete cascade,
  media_asset_id uuid references public.media_assets(id) on delete set null,
  media_kind text not null check (media_kind in ('photo', 'video')),
  -- Photos: 1..10 seconds or NULL = unlimited (until the viewer closes the session).
  -- Videos: always play for their own duration.
  view_seconds smallint check (view_seconds between 1 and 10),
  video_seconds numeric(5,2) check (video_seconds is null or video_seconds between 0.1 and 60),
  allow_saving boolean not null default false,
  client_id uuid not null,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,               -- unopened snaps expire after 30 days
  unique (sender_id, client_id),
  check ((media_kind = 'video') = (video_seconds is not null)),
  check (media_kind = 'photo' or view_seconds is null)
);

create table public.snap_recipients (
  snap_id uuid not null references public.snaps(id) on delete cascade,
  recipient_id uuid not null references public.profiles(id) on delete cascade,
  conversation_id uuid not null references public.conversations(id) on delete cascade,
  status public.snap_status not null default 'delivered',
  views_used smallint not null default 0 check (views_used between 0 and 2),
  session_id uuid,
  session_started_at timestamptz,
  session_deadline timestamptz,                 -- hard end of the current session
  delivered_at timestamptz not null default now(),
  opened_at timestamptz,
  expired_at timestamptz,
  saved_at timestamptz,
  primary key (snap_id, recipient_id)
);
create index snap_recipients_recipient on public.snap_recipients (recipient_id, status);

alter table public.messages
  add constraint messages_snap_fk foreign key (snap_id) references public.snaps(id) on delete cascade;
create index messages_snap on public.messages (snap_id) where snap_id is not null;

alter table public.snaps enable row level security;
alter table public.snap_recipients enable row level security;
revoke all on public.snaps, public.snap_recipients from anon, authenticated;
grant select on public.snaps, public.snap_recipients to authenticated;

-- Definer helpers avoid mutually recursive policies between the two tables.
create or replace function private.is_snap_recipient(p_snap uuid, p_user uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.snap_recipients where snap_id = p_snap and recipient_id = p_user)
$$;
create or replace function private.is_snap_sender(p_snap uuid, p_user uuid)
returns boolean language sql stable security definer set search_path = '' as $$
  select exists (select 1 from public.snaps where id = p_snap and sender_id = p_user)
$$;

-- Sender sees their snaps; recipients see snap metadata (never the media path).
create policy snaps_sender_or_recipient on public.snaps for select to authenticated
  using (sender_id = auth.uid() or private.is_snap_recipient(id, auth.uid()));
create policy snap_recipients_visible on public.snap_recipients for select to authenticated
  using (recipient_id = auth.uid() or private.is_snap_sender(snap_id, auth.uid()));
-- Column privilege: recipients may not read media_asset_id directly.
revoke select on public.snaps from authenticated;
grant select (id, sender_id, media_kind, view_seconds, video_seconds, allow_saving, created_at, expires_at)
  on public.snaps to authenticated;

-- ---------------------------------------------------------------------------
-- send_snap: to friends directly and/or to groups the sender belongs to.
-- ---------------------------------------------------------------------------
create or replace function public.send_snap(
  p_media_asset uuid, p_recipients uuid[], p_groups uuid[], p_view_seconds smallint,
  p_allow_saving boolean, p_client_id uuid)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.assert_active();
  a public.media_assets;
  v_snap uuid;
  v_kind text;
  r uuid;
  g uuid;
  v_conv uuid;
  v_count integer := 0;
begin
  if p_client_id is null then perform private.fail('client_id_required'); end if;
  select id into v_snap from public.snaps where sender_id = v_uid and client_id = p_client_id;
  if v_snap is not null then return v_snap; end if;   -- idempotent retry

  perform private.rate_limit_hit('send_snap', 60, interval '1 hour');
  select * into a from public.media_assets where id = p_media_asset;
  if a.id is null or a.owner_id <> v_uid or a.purpose <> 'snap' or a.status <> 'uploaded' then
    perform private.fail('invalid_media');
  end if;
  v_kind := case when a.mime_type like 'video/%' then 'video' else 'photo' end;
  if v_kind = 'photo' and p_view_seconds is not null and p_view_seconds not between 1 and 10 then
    perform private.fail('invalid_view_seconds');
  end if;

  insert into public.snaps (sender_id, media_asset_id, media_kind, view_seconds, video_seconds,
                            allow_saving, client_id, expires_at)
  values (v_uid, a.id, v_kind, case when v_kind = 'photo' then p_view_seconds end,
          case when v_kind = 'video' then a.duration_seconds end,
          coalesce(p_allow_saving, false), p_client_id, now() + (private.config()).unopened_snap_ttl)
  returning id into v_snap;

  foreach r in array coalesce(p_recipients, '{}') loop
    if r = v_uid then continue; end if;
    perform private.assert_can_interact(v_uid, r);
    if not private.are_friends(v_uid, r) then perform private.fail('not_friends', r::text); end if;
    v_conv := public.create_direct_conversation(r);
    insert into public.snap_recipients (snap_id, recipient_id, conversation_id)
    values (v_snap, r, v_conv) on conflict do nothing;
    insert into public.messages (conversation_id, sender_id, kind, snap_id, client_msg_id)
    values (v_conv, v_uid, 'snap', v_snap, gen_random_uuid());
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
    on conflict do nothing;
    insert into public.messages (conversation_id, sender_id, kind, snap_id, client_msg_id)
    values (g, v_uid, 'snap', v_snap, gen_random_uuid());
    update public.conversations set last_message_at = now() where id = g;
    v_count := v_count + 1;
  end loop;

  if v_count = 0 then perform private.fail('no_recipients'); end if;
  return v_snap;
end $$;

-- ---------------------------------------------------------------------------
-- Viewing
-- ---------------------------------------------------------------------------
create or replace function private.snap_session_live(r public.snap_recipients)
returns boolean language sql stable as $$
  select r.session_id is not null and r.session_deadline > now()
$$;

-- Opens a viewing session (first view or the single replay).
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
   where snap_id = p_snap and recipient_id = v_uid for update;   -- serialises all devices
  if r.snap_id is null then perform private.fail('snap_not_found'); end if;
  select * into s from public.snaps where id = p_snap;
  if private.is_blocked_either(v_uid, s.sender_id) then perform private.fail('snap_not_found'); end if;

  if r.status = 'expired' or s.expires_at <= now() or s.media_asset_id is null then
    perform private.fail('snap_expired');
  end if;
  if private.snap_session_live(r) then perform private.fail('session_active'); end if;
  if r.views_used >= 2 then
    perform private.fail('snap_expired');   -- the expiry job records the final state
  end if;

  -- Session length: photo timer, video duration, or "unlimited" (bounded by a safety cap
  -- so a never-closed session cannot keep the media reachable indefinitely).
  v_len := case
    when s.media_kind = 'video' then make_interval(secs => s.video_seconds::double precision + 3)
    when s.view_seconds is null then (private.config()).unlimited_view_max
    else make_interval(secs => s.view_seconds + 2) end;   -- small network grace

  update public.snap_recipients
     set views_used = r.views_used + 1,
         status = case when r.views_used = 0 then 'opened'::public.snap_status else 'replayed' end,
         opened_at = coalesce(r.opened_at, now()),
         session_id = v_session, session_started_at = now(), session_deadline = now() + v_len
   where snap_id = r.snap_id and recipient_id = v_uid;

  return query select v_session, (r.views_used + 1)::smallint, now() + v_len, s.view_seconds,
                      (s.media_kind = 'photo' and s.view_seconds is null), s.allow_saving;
end $$;

-- Ends the session (viewer closed it, or the timer finished). After the replay, expire.
create or replace function public.close_snap_view(p_snap uuid, p_session uuid)
returns public.snap_status
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); r public.snap_recipients; v_status public.snap_status;
begin
  if v_uid is null then perform private.fail('not_authenticated'); end if;
  select * into r from public.snap_recipients
   where snap_id = p_snap and recipient_id = v_uid for update;
  if r.snap_id is null then perform private.fail('snap_not_found'); end if;
  if r.session_id is distinct from p_session then return r.status; end if;   -- stale/duplicate
  v_status := case when r.views_used >= 2 then 'expired'::public.snap_status else r.status end;
  update public.snap_recipients
     set session_id = null, session_deadline = null, status = v_status,
         expired_at = case when v_status = 'expired' then now() else expired_at end
   where snap_id = p_snap and recipient_id = v_uid;
  return v_status;
end $$;

-- Called by the media-url Edge Function (with the viewer's JWT) to obtain the object
-- path; it then signs a URL valid for at most the remaining session time.
create or replace function public.authorize_snap_media(p_snap uuid, p_session uuid)
returns table (bucket text, object_path text, mime_type text, valid_seconds integer)
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); r public.snap_recipients; a public.media_assets;
begin
  select * into r from public.snap_recipients where snap_id = p_snap and recipient_id = v_uid;
  if r.snap_id is null or r.session_id is distinct from p_session
     or not private.snap_session_live(r) or r.status = 'expired' then
    perform private.fail('snap_session_invalid');
  end if;
  select m.* into a from public.snaps s join public.media_assets m on m.id = s.media_asset_id
   where s.id = p_snap and m.status = 'uploaded';
  if a.id is null then perform private.fail('snap_expired'); end if;
  perform private.charge_egress(a.byte_size);
  return query select a.bucket, a.object_path, a.mime_type,
    least(60, greatest(1, ceil(extract(epoch from r.session_deadline - now()))::integer));
end $$;

-- Sender-controlled saving. Only allowed while the viewer can legitimately see the Snap.
-- This is an in-app permission, not protection against screenshots or screen recording.
create or replace function public.save_snap(p_snap uuid, p_session uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); r public.snap_recipients; v_allowed boolean;
begin
  select * into r from public.snap_recipients
   where snap_id = p_snap and recipient_id = v_uid for update;
  select allow_saving into v_allowed from public.snaps where id = p_snap;
  if r.snap_id is null then perform private.fail('snap_not_found'); end if;
  if not coalesce(v_allowed, false) then perform private.fail('saving_not_permitted'); end if;
  if r.session_id is distinct from p_session or not private.snap_session_live(r) then
    perform private.fail('snap_session_invalid');
  end if;
  update public.snap_recipients set saved_at = coalesce(saved_at, now())
   where snap_id = p_snap and recipient_id = v_uid;
end $$;

grant execute on function
  public.send_snap(uuid, uuid[], uuid[], smallint, boolean, uuid), public.open_snap(uuid),
  public.close_snap_view(uuid, uuid), public.authorize_snap_media(uuid, uuid),
  public.save_snap(uuid, uuid)
  to authenticated;

-- ---------------------------------------------------------------------------
-- Generic media access for non-Snap assets (chat media, profile images, own backups).
-- ---------------------------------------------------------------------------
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
  -- snap, story (Phase 5), memory_backup and vault_backup: owner only.

  if not v_ok then perform private.fail('media_not_found'); end if;
  perform private.charge_egress(a.byte_size);
  return query select a.bucket, a.object_path, a.mime_type, 60;
end $$;
grant execute on function public.authorize_media_access(uuid) to authenticated;
