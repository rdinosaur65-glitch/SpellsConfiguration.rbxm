-- PULSE 0007 — reporting, owner-only administration, audit log, sessions, deletion.
-- The owner panel never gets a bypass into chats, Vault or location: there is no
-- owner clause in any of those tables' RLS policies. Report evidence is a snapshot
-- taken at report time from content the reporter was authorised to see.

create type public.report_target as enum ('user', 'message', 'story', 'group');
create type public.report_reason as enum
  ('spam', 'harassment', 'hate', 'sexual_content', 'violence', 'self_harm', 'impersonation',
   'underage', 'other');
create type public.report_status as enum ('open', 'reviewing', 'actioned', 'dismissed');

create table public.reports (
  id uuid primary key default gen_random_uuid(),
  reporter_id uuid references public.profiles(id) on delete set null,
  target_type public.report_target not null,
  target_user_id uuid references public.profiles(id) on delete set null,
  target_message_id uuid references public.messages(id) on delete set null,
  target_conversation_id uuid references public.conversations(id) on delete set null,
  reason public.report_reason not null,
  details text check (char_length(details) <= 1000),
  evidence jsonb not null default '{}'::jsonb,   -- retained per the disclosed retention policy
  status public.report_status not null default 'open',
  created_at timestamptz not null default now(),
  resolved_at timestamptz,
  resolution_note text
);
create index reports_status on public.reports (status, created_at);

create table private.audit_log (
  id bigserial primary key,
  actor_id uuid,
  action text not null,
  target_user_id uuid,
  details jsonb not null default '{}'::jsonb,
  created_at timestamptz not null default now()
);
-- Append-only, even for the definer functions' owner, by trigger.
create or replace function private.audit_log_immutable() returns trigger language plpgsql as $$
begin raise exception 'audit_log is append-only'; end $$;
create trigger audit_log_no_update before update or delete on private.audit_log
  for each row execute function private.audit_log_immutable();

create or replace function private.audit(p_action text, p_target uuid, p_details jsonb)
returns void language sql security definer set search_path = '' as $$
  insert into private.audit_log (actor_id, action, target_user_id, details)
  values (auth.uid(), p_action, p_target, coalesce(p_details, '{}'::jsonb))
$$;

alter table public.reports enable row level security;
revoke all on public.reports from anon, authenticated;
grant select on public.reports to authenticated;
-- Reporters can see the status of their own reports. Owner access goes through RPCs.
create policy reports_own on public.reports for select to authenticated
  using (reporter_id = auth.uid());

create or replace function private.assert_owner()
returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null or not private.is_owner(v_uid) then perform private.fail('forbidden'); end if;
  return v_uid;
end $$;

-- ---------------------------------------------------------------------------
-- Reporting
-- ---------------------------------------------------------------------------
create or replace function public.report_user(p_user uuid, p_reason public.report_reason,
                                              p_details text default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_id uuid;
begin
  perform private.rate_limit_hit('report', 20, interval '1 hour');
  if p_user = v_uid or not exists (select 1 from public.profiles where id = p_user) then
    perform private.fail('user_not_found');
  end if;
  insert into public.reports (reporter_id, target_type, target_user_id, reason, details, evidence)
  select v_uid, 'user', p.id, p_reason, p_details,
         jsonb_build_object('username', p.username, 'display_name', p.display_name,
                            'bio', p.bio, 'captured_at', now())
  from public.profiles p where p.id = p_user
  returning id into v_id;
  return v_id;
end $$;

create or replace function public.report_message(p_msg uuid, p_reason public.report_reason,
                                                 p_details text default null)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); m public.messages; v_id uuid;
begin
  perform private.rate_limit_hit('report', 20, interval '1 hour');
  select * into m from public.messages where id = p_msg;
  if m.id is null or not private.can_read_message(m.id, v_uid)
     or not private.message_content_visible(m.id) or m.sender_id = v_uid then
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
  insert into public.reports (reporter_id, target_type, target_conversation_id, reason, details, evidence)
  select v_uid, 'group', c.id, p_reason, p_details,
         jsonb_build_object('name', c.name, 'description', c.description, 'captured_at', now())
  from public.conversations c where c.id = p_conv
  returning id into v_id;
  return v_id;
end $$;

-- ---------------------------------------------------------------------------
-- Owner panel RPCs (every one checks ownership server-side and writes the audit log)
-- ---------------------------------------------------------------------------
create or replace function public.admin_search_users(p_query text)
returns table (id uuid, username text, display_name text, account_state public.account_state,
               created_at timestamptz, open_reports bigint)
language plpgsql stable security definer set search_path = '' as $$
declare v_owner uuid := private.assert_owner();
begin
  return query
    select p.id, p.username::text, p.display_name, p.account_state, p.created_at,
           (select count(*) from public.reports r where r.target_user_id = p.id and r.status = 'open')
    from public.profiles p
    where p_query is null or p.username::text ilike '%' || replace(p_query, '_', '\_') || '%'
    order by p.created_at desc limit 100;
end $$;

create or replace function public.admin_list_reports(p_status public.report_status default 'open')
returns setof public.reports
language plpgsql stable security definer set search_path = '' as $$
declare v_owner uuid := private.assert_owner();
begin
  return query select * from public.reports where status = p_status order by created_at limit 200;
end $$;

create or replace function public.admin_resolve_report(p_report uuid, p_status public.report_status,
                                                       p_note text default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_owner uuid := private.assert_owner();
begin
  update public.reports set status = p_status, resolved_at = now(), resolution_note = p_note
   where id = p_report;
  if not found then perform private.fail('report_not_found'); end if;
  perform private.audit('report.resolve', null,
    jsonb_build_object('report_id', p_report, 'status', p_status, 'note', p_note));
end $$;

-- Revokes every session of a user (used by bans, suspensions, deletion, and by users
-- themselves for "sign out everywhere").
create or replace function private.revoke_sessions(p_user uuid, p_except uuid default null)
returns integer
language plpgsql security definer set search_path = '' as $$
declare v_n integer;
begin
  delete from auth.sessions where user_id = p_user and (p_except is null or id <> p_except);
  get diagnostics v_n = row_count;
  return v_n;
end $$;

create or replace function public.admin_set_account_state(p_user uuid, p_state public.account_state,
                                                          p_reason text)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_owner uuid := private.assert_owner();
begin
  if p_user = v_owner then perform private.fail('cannot_moderate_owner'); end if;
  if p_state = 'deleting' then perform private.fail('use_deletion_flow'); end if;
  if p_reason is null or char_length(btrim(p_reason)) = 0 then perform private.fail('reason_required'); end if;
  update public.profiles set account_state = p_state where id = p_user;
  if not found then perform private.fail('user_not_found'); end if;
  -- GoTrue refuses sign-in and token refresh while banned_until is in the future.
  update auth.users set banned_until = case when p_state = 'active' then null else 'infinity'::timestamptz end
   where id = p_user;
  if p_state <> 'active' then perform private.revoke_sessions(p_user); end if;
  perform private.audit('account.set_state', p_user, jsonb_build_object('state', p_state, 'reason', p_reason));
end $$;

-- Aggregate, non-personal operational data.
create or replace function public.admin_usage_summary()
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_owner uuid := private.assert_owner(); v_cfg private.platform_config := private.config();
begin
  return jsonb_build_object(
    'accounts', (select count(*) from public.profiles),
    'registration_cap', v_cfg.registration_cap,
    'active_7d', (select count(*) from private.presence where last_active_at > now() - interval '7 days'),
    'messages_total', (select count(*) from public.messages),
    'open_reports', (select count(*) from public.reports where status = 'open'),
    'storage_pools', (select jsonb_object_agg(pool, jsonb_build_object(
        'used', bytes_used, 'limit', bytes_limit,
        'percent', round(100.0 * bytes_used / bytes_limit, 1))) from private.storage_pools),
    'egress_today', (select coalesce(bytes, 0) from private.egress_daily
                     where day = (now() at time zone 'utc')::date),
    'egress_budget_daily', v_cfg.daily_egress_budget_bytes,
    'database_bytes', pg_database_size(current_database()),
    'database_limit', 524288000,
    'pending_deletions', (select count(*) from public.media_assets where status = 'deleting'));
end $$;

create or replace function public.admin_audit_log(p_limit integer default 100)
returns setof private.audit_log
language plpgsql stable security definer set search_path = '' as $$
declare v_owner uuid := private.assert_owner();
begin
  return query select * from private.audit_log order by id desc limit least(p_limit, 500);
end $$;

-- ---------------------------------------------------------------------------
-- User session management
-- ---------------------------------------------------------------------------
create or replace function public.my_sessions()
returns table (id uuid, created_at timestamptz, user_agent text, current boolean)
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then perform private.fail('not_authenticated'); end if;
  return query select s.id, s.created_at, s.user_agent,
                      s.id::text = (auth.jwt() ->> 'session_id')
               from auth.sessions s where s.user_id = v_uid order by s.created_at desc;
end $$;

create or replace function public.revoke_session(p_session uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then perform private.fail('not_authenticated'); end if;
  delete from auth.sessions where id = p_session and user_id = v_uid;
  if not found then perform private.fail('session_not_found'); end if;
end $$;

create or replace function public.revoke_other_sessions()
returns integer
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then perform private.fail('not_authenticated'); end if;
  return private.revoke_sessions(v_uid, nullif(auth.jwt() ->> 'session_id', '')::uuid);
end $$;

-- ---------------------------------------------------------------------------
-- Account deletion (no recovery period)
-- Identity confirmation: the JWT must show a password/OAuth/OTP authentication within
-- the last 10 minutes (Supabase puts this in the "amr" claim), so the client must
-- re-authenticate immediately before requesting deletion.
-- ---------------------------------------------------------------------------
create table private.deletion_queue (
  user_id uuid primary key,
  requested_at timestamptz not null default now(),
  processed_at timestamptz
);

create or replace function private.recently_authenticated(p_max_age interval)
returns boolean
language sql stable as $$
  select coalesce(
    (select max((e ->> 'timestamp')::bigint) from jsonb_array_elements(auth.jwt() -> 'amr') e)
      >= extract(epoch from now() - p_max_age), false)
$$;

create or replace function public.request_account_deletion()
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then perform private.fail('not_authenticated'); end if;
  if private.is_owner(v_uid) then perform private.fail('owner_account_protected'); end if;
  if not private.recently_authenticated(interval '10 minutes') then
    perform private.fail('reauthentication_required');
  end if;
  update public.profiles set account_state = 'deleting' where id = v_uid;   -- access disabled
  update auth.users set banned_until = 'infinity' where id = v_uid;         -- no new tokens
  perform private.revoke_sessions(v_uid);                                   -- sessions gone
  insert into private.deletion_queue (user_id) values (v_uid) on conflict do nothing;
  -- Queue all media for removal now; quota released immediately.
  perform private.request_asset_deletion(id) from public.media_assets
   where owner_id = v_uid and status in ('pending', 'uploaded');
  perform private.audit('account.deletion_requested', v_uid, '{}'::jsonb);
end $$;

-- Hand each group the departing user owns to its longest-standing admin, else member.
create or replace function private.transfer_ownership_on_delete(p_user uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare g record; v_heir uuid;
begin
  for g in select conversation_id from public.conversation_members
           where user_id = p_user and role = 'owner' and left_at is null loop
    select o.user_id into v_heir from public.conversation_members o
     where o.conversation_id = g.conversation_id and o.user_id <> p_user and o.left_at is null
     order by (o.role = 'admin') desc, o.joined_at limit 1;
    update public.conversation_members set role = 'member', left_at = now()
     where conversation_id = g.conversation_id and user_id = p_user;
    if v_heir is not null then
      update public.conversation_members set role = 'owner'
       where conversation_id = g.conversation_id and user_id = v_heir;
    end if;
  end loop;
end $$;

-- Background step: once a user's media objects are gone, delete the account rows.
-- Cascades remove profile, settings, friendships, memberships, messages, snaps, etc.
-- Reports keep their evidence snapshot with the user reference nulled.
create or replace function private.process_account_deletions()
returns integer
language plpgsql security definer set search_path = '' as $$
declare q record; v_n integer := 0;
begin
  for q in select * from private.deletion_queue where processed_at is null loop
    if exists (select 1 from public.media_assets where owner_id = q.user_id and status <> 'deleted') then
      continue;   -- storage-janitor has not finished removing objects yet
    end if;
    perform private.transfer_ownership_on_delete(q.user_id);
    delete from public.media_assets where owner_id = q.user_id;
    delete from auth.users where id = q.user_id;
    update private.deletion_queue set processed_at = now() where user_id = q.user_id;
    v_n := v_n + 1;
  end loop;
  return v_n;
end $$;

grant execute on function
  public.report_user(uuid, public.report_reason, text),
  public.report_message(uuid, public.report_reason, text),
  public.report_group(uuid, public.report_reason, text),
  public.admin_search_users(text), public.admin_list_reports(public.report_status),
  public.admin_resolve_report(uuid, public.report_status, text),
  public.admin_set_account_state(uuid, public.account_state, text),
  public.admin_usage_summary(), public.admin_audit_log(integer),
  public.my_sessions(), public.revoke_session(uuid), public.revoke_other_sessions(),
  public.request_account_deletion()
  to authenticated;
