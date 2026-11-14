-- PULSE 0013 — server-side enforcement of two-step verification.
-- Until now 2FA was enforced only by the web app: after the password step the session
-- is aal1, and a client talking to the API directly could use it. Now, once a user has
-- a verified TOTP factor, every RPC, table read, Storage read and Realtime topic
-- requires an aal2 session (password + code). Users without 2FA are unaffected.

create or replace function private.mfa_satisfied()
returns boolean
language sql stable security definer set search_path = '' as $$
  select coalesce(auth.jwt() ->> 'aal', 'aal1') = 'aal2'
      or not exists (select 1 from auth.mfa_factors f
                     where f.user_id = auth.uid() and f.status::text = 'verified')
$$;

create or replace function private.assert_mfa()
returns void
language plpgsql stable security definer set search_path = '' as $$
begin
  if not private.mfa_satisfied() then perform private.fail('mfa_required'); end if;
end $$;

revoke execute on function private.mfa_satisfied(), private.assert_mfa() from public, anon;
grant execute on function private.mfa_satisfied(), private.assert_mfa() to authenticated;

-- Central guards used by almost every RPC.
create or replace function private.assert_active()
returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_state public.account_state;
begin
  if v_uid is null then perform private.fail('not_authenticated'); end if;
  perform private.assert_mfa();
  select account_state into v_state from public.profiles where id = v_uid;
  if v_state is null then perform private.fail('no_profile'); end if;
  if v_state <> 'active' then perform private.fail('account_not_active', v_state::text); end if;
  return v_uid;
end $$;

create or replace function private.assert_owner()
returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null or not private.is_owner(v_uid) then perform private.fail('forbidden'); end if;
  perform private.assert_mfa();
  return v_uid;
end $$;

-- Realtime topics (typing, call signalling).
create or replace function private.can_use_topic(p_topic text)
returns boolean
language sql stable security definer set search_path = '' as $$
  select p_topic like 'conv:%'
     and private.is_member(private.try_uuid(substr(p_topic, 6)), auth.uid())
     and not private.direct_blocked(private.try_uuid(substr(p_topic, 6)))
     and exists (select 1 from public.profiles where id = auth.uid() and account_state = 'active')
     and private.mfa_satisfied()
$$;

-- RPCs that check auth.uid() directly instead of assert_active().
create or replace function public.delete_media_asset(p_asset uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then perform private.fail('not_authenticated'); end if;
  perform private.assert_mfa();
  if not exists (select 1 from public.media_assets where id = p_asset and owner_id = v_uid) then
    perform private.fail('asset_not_found');
  end if;
  perform private.request_asset_deletion(p_asset);
end $$;

create or replace function public.delete_message(p_msg uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); m public.messages;
begin
  if v_uid is null then perform private.fail('not_authenticated'); end if;
  perform private.assert_mfa();
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
  v_status := case when r.views_used >= 2 then 'expired'::public.snap_status else r.status end;
  update public.snap_recipients
     set session_id = null, session_deadline = null, status = v_status,
         expired_at = case when v_status = 'expired' then now() else expired_at end
   where snap_id = p_snap and recipient_id = v_uid;
  return v_status;
end $$;

create or replace function public.my_sessions()
returns table (id uuid, created_at timestamptz, user_agent text, current boolean)
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then perform private.fail('not_authenticated'); end if;
  perform private.assert_mfa();
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
  perform private.assert_mfa();
  delete from auth.sessions where id = p_session and user_id = v_uid;
  if not found then perform private.fail('session_not_found'); end if;
end $$;

create or replace function public.revoke_other_sessions()
returns integer
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then perform private.fail('not_authenticated'); end if;
  perform private.assert_mfa();
  return private.revoke_sessions(v_uid, nullif(auth.jwt() ->> 'session_id', '')::uuid);
end $$;

create or replace function public.request_account_deletion()
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  if v_uid is null then perform private.fail('not_authenticated'); end if;
  perform private.assert_mfa();
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

-- Direct table reads (PostgREST, Realtime postgres_changes): a restrictive policy is
-- AND-ed with the existing permissive ones on every RLS table in public, and on the
-- media bucket's objects. "(select ...)" lets Postgres evaluate it once per query.
-- Test 80 fails if a future table lacks this policy.
do $$
declare t record;
begin
  for t in select c.relname from pg_class c join pg_namespace n on n.oid = c.relnamespace
           where n.nspname = 'public' and c.relkind = 'r' and c.relrowsecurity loop
    execute format('create policy mfa_gate on public.%I as restrictive for all to authenticated
                    using ((select private.mfa_satisfied())) with check ((select private.mfa_satisfied()))', t.relname);
  end loop;
end $$;

create policy media_mfa_gate on storage.objects as restrictive for all to authenticated
  using (bucket_id <> 'media' or (select private.mfa_satisfied()))
  with check (bucket_id <> 'media' or (select private.mfa_satisfied()));
