-- PULSE 0021 — 2FA reset of another account requires a code emailed to the owner.
--
-- Replaces the one-step admin_reset_mfa() from 0019. The flow, all enforced here and in
-- the owner-mfa-reset Edge Function (which holds the service role and the SMTP secret):
--
--  1. admin_mfa_reset_request(target, reason)        caller: the owner (JWT)
--       owner + aal2 + a password sign-in within 10 minutes; rate-limited; any earlier
--       open request for the same target is cancelled. Creates a request with NO code.
--  2. mfa_reset_issue_code(request)                   caller: Edge Function (service role)
--       once per request: a fresh CSPRNG 6-digit code, stored only as a hash bound to the
--       request id; returns the code and the owner's *verified* email to the function.
--  3. the function emails the code to the owner, then mfa_reset_mark_sent(request, ok).
--       Delivery failure marks the request failed: it can never be completed.
--  4. admin_mfa_reset_confirm(request, code)          caller: the owner (JWT)
--       5-minute expiry, single use, at most 5 wrong codes (then locked), bound to the
--       owner who asked and to that request (and so to its target). Success only marks
--       the request verified; it changes nothing on the target account.
--  5. mfa_reset_execute(request)                      caller: Edge Function (service role)
--       within 2 minutes of verification: removes the target's factors and sessions,
--       returns the target's email for the notice (which never names the owner).
-- Every step is written to the owner audit log.

drop function if exists public.admin_reset_mfa(uuid, text);

create table if not exists private.mfa_reset_requests (
  id uuid primary key default gen_random_uuid(),
  owner_id uuid not null,
  target_id uuid not null references public.profiles(id) on delete cascade,
  reason text not null check (char_length(reason) between 1 and 500),
  status text not null default 'awaiting_email'
    check (status in ('awaiting_email', 'sending', 'pending', 'verified', 'completed',
                      'failed', 'expired', 'locked', 'cancelled')),
  code_hash text,
  attempts integer not null default 0,
  created_at timestamptz not null default now(),
  code_sent_at timestamptz,
  expires_at timestamptz,
  verified_at timestamptz,
  completed_at timestamptz
);
create index if not exists mfa_reset_requests_target on private.mfa_reset_requests (target_id);
create index if not exists mfa_reset_requests_owner on private.mfa_reset_requests (owner_id, created_at desc);

-- Uniform 6-digit code from the OS CSPRNG (pgcrypto), by rejection sampling.
create or replace function private.random_six_digits()
returns text
language plpgsql volatile set search_path = '' as $$
declare v bigint;
begin
  loop
    v := ('x' || encode(extensions.gen_random_bytes(4), 'hex'))::bit(32)::bigint;   -- 0 .. 2^32-1
    exit when v < 4294000000;                                                         -- multiple of 10^6
  end loop;
  return lpad((v % 1000000)::text, 6, '0');
end $$;

create or replace function private.mfa_reset_hash(p_request uuid, p_code text)
returns text
language sql immutable set search_path = '' as $$
  select encode(extensions.digest(p_request::text || ':' || p_code, 'sha256'), 'hex')
$$;

-- 1. Start a reset (owner, aal2, fresh password sign-in).
create or replace function public.admin_mfa_reset_request(p_user uuid, p_reason text)
returns uuid
language plpgsql security definer set search_path = '' as $$
declare v_owner uuid := private.assert_owner(); v_id uuid;
begin
  if not private.recently_authenticated(interval '10 minutes') then
    perform private.fail('reauthentication_required');
  end if;
  perform private.rate_limit_hit('mfa_reset_request', 5, interval '1 hour');
  perform private.rate_limit_hit('mfa_reset_request_day', 20, interval '1 day');
  if p_user = v_owner then perform private.fail('cannot_moderate_owner'); end if;
  if p_reason is null or char_length(btrim(p_reason)) = 0 then perform private.fail('reason_required'); end if;
  if not exists (select 1 from public.profiles where id = p_user) then perform private.fail('user_not_found'); end if;
  if not exists (select 1 from auth.users where id = v_owner and email_confirmed_at is not null and email is not null) then
    perform private.fail('owner_email_unverified');
  end if;
  -- A new attempt replaces any open one for this target (its code can no longer be used).
  update private.mfa_reset_requests set status = 'cancelled'
   where target_id = p_user and status in ('awaiting_email', 'sending', 'pending', 'verified');
  insert into private.mfa_reset_requests (owner_id, target_id, reason)
  values (v_owner, p_user, left(btrim(p_reason), 500))
  returning id into v_id;
  perform private.audit('account.mfa_reset.requested', p_user, jsonb_build_object('request_id', v_id, 'reason', btrim(p_reason)));
  return v_id;
end $$;

-- 2. Issue the code (service role only; once per request, within a minute of the request).
create or replace function public.mfa_reset_issue_code(p_request uuid)
returns table (code text, owner_email text, target_username text)
language plpgsql security definer set search_path = '' as $$
declare r private.mfa_reset_requests; v_code text := private.random_six_digits(); v_email text;
begin
  select * into r from private.mfa_reset_requests where id = p_request for update;
  if r.id is null or r.status <> 'awaiting_email' or r.created_at < now() - interval '1 minute' then
    perform private.fail('request_not_found');
  end if;
  select u.email into v_email from auth.users u
   where u.id = r.owner_id and u.email_confirmed_at is not null;
  if v_email is null then perform private.fail('owner_email_unverified'); end if;
  update private.mfa_reset_requests
     set status = 'sending', code_hash = private.mfa_reset_hash(r.id, v_code)
   where id = r.id;
  return query select v_code, v_email, (select p.username::text from public.profiles p where p.id = r.target_id);
end $$;

-- 3. Record the delivery outcome. Only a delivered code can ever be confirmed.
create or replace function public.mfa_reset_mark_sent(p_request uuid, p_delivered boolean, p_error text default null)
returns void
language plpgsql security definer set search_path = '' as $$
declare r private.mfa_reset_requests;
begin
  select * into r from private.mfa_reset_requests where id = p_request for update;
  if r.id is null or r.status <> 'sending' then perform private.fail('request_not_found'); end if;
  if p_delivered then
    update private.mfa_reset_requests
       set status = 'pending', code_sent_at = now(), expires_at = now() + interval '5 minutes'
     where id = r.id;
    insert into private.audit_log (actor_id, action, target_user_id, details)
    values (r.owner_id, 'account.mfa_reset.code_sent', r.target_id, jsonb_build_object('request_id', r.id));
  else
    update private.mfa_reset_requests set status = 'failed', code_hash = null where id = r.id;
    insert into private.audit_log (actor_id, action, target_user_id, details)
    values (r.owner_id, 'account.mfa_reset.email_failed', r.target_id,
            jsonb_build_object('request_id', r.id, 'error', left(coalesce(p_error, ''), 200)));
  end if;
end $$;

-- 4. Confirm the code (owner). Never raises for a wrong code, so the attempt counter is
--    kept (an exception would roll it back). Returns status + remaining attempts.
create or replace function public.admin_mfa_reset_confirm(p_request uuid, p_code text)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_owner uuid := private.assert_owner(); r private.mfa_reset_requests; v_left integer;
begin
  perform private.rate_limit_hit('mfa_reset_confirm', 30, interval '10 minutes');
  select * into r from private.mfa_reset_requests where id = p_request for update;
  -- Bound to the owner who asked and to this request (and therefore its target).
  if r.id is null or r.owner_id <> v_owner then perform private.fail('request_not_found'); end if;
  if r.status <> 'pending' then
    return jsonb_build_object('status', case when r.status in ('verified', 'completed') then 'used' else r.status end);
  end if;
  if r.expires_at <= now() then
    update private.mfa_reset_requests set status = 'expired', code_hash = null where id = r.id;
    perform private.audit('account.mfa_reset.expired', r.target_id, jsonb_build_object('request_id', r.id));
    return jsonb_build_object('status', 'expired');
  end if;
  if p_code is null or p_code !~ '^[0-9]{6}$' or private.mfa_reset_hash(r.id, p_code) <> r.code_hash then
    v_left := 4 - r.attempts;
    update private.mfa_reset_requests
       set attempts = attempts + 1,
           status = case when v_left <= 0 then 'locked' else status end,
           code_hash = case when v_left <= 0 then null else code_hash end
     where id = r.id;
    perform private.audit(case when v_left <= 0 then 'account.mfa_reset.locked' else 'account.mfa_reset.code_incorrect' end,
                          r.target_id, jsonb_build_object('request_id', r.id, 'attempt', r.attempts + 1));
    return jsonb_build_object('status', case when v_left <= 0 then 'locked' else 'incorrect' end,
                              'attempts_left', greatest(v_left, 0));
  end if;
  update private.mfa_reset_requests set status = 'verified', verified_at = now(), code_hash = null where id = r.id;
  perform private.audit('account.mfa_reset.verified', r.target_id, jsonb_build_object('request_id', r.id));
  return jsonb_build_object('status', 'verified');
end $$;

-- 5. Carry out a verified reset (service role only), shortly after verification.
create or replace function public.mfa_reset_execute(p_request uuid)
returns table (target_email text, factors_removed integer, sessions_revoked integer)
language plpgsql security definer set search_path = '' as $$
declare r private.mfa_reset_requests; v_f integer; v_s integer; v_email text;
begin
  select * into r from private.mfa_reset_requests where id = p_request for update;
  if r.id is null or r.status <> 'verified' or r.verified_at < now() - interval '2 minutes' then
    perform private.fail('request_not_verified');
  end if;
  delete from auth.mfa_factors where user_id = r.target_id;
  get diagnostics v_f = row_count;
  v_s := private.revoke_sessions(r.target_id);
  update private.mfa_reset_requests set status = 'completed', completed_at = now() where id = r.id;
  insert into private.audit_log (actor_id, action, target_user_id, details)
  values (r.owner_id, 'account.mfa_reset.completed', r.target_id,
          jsonb_build_object('request_id', r.id, 'factors_removed', v_f, 'sessions_revoked', v_s, 'reason', r.reason));
  select email into v_email from auth.users where id = r.target_id;
  return query select v_email, v_f, v_s;
end $$;

-- Delivery outcome of the notice to the affected user (audit only).
create or replace function public.mfa_reset_notified(p_request uuid, p_delivered boolean)
returns void
language plpgsql security definer set search_path = '' as $$
declare r private.mfa_reset_requests;
begin
  select * into r from private.mfa_reset_requests where id = p_request;
  if r.id is null or r.status <> 'completed' then perform private.fail('request_not_found'); end if;
  insert into private.audit_log (actor_id, action, target_user_id, details)
  values (r.owner_id, case when p_delivered then 'account.mfa_reset.user_notified' else 'account.mfa_reset.notify_failed' end,
          r.target_id, jsonb_build_object('request_id', r.id));
end $$;

revoke execute on function
  private.random_six_digits(), private.mfa_reset_hash(uuid, text),
  public.admin_mfa_reset_request(uuid, text), public.mfa_reset_issue_code(uuid),
  public.mfa_reset_mark_sent(uuid, boolean, text), public.admin_mfa_reset_confirm(uuid, text),
  public.mfa_reset_execute(uuid), public.mfa_reset_notified(uuid, boolean)
  from public, anon, authenticated;
grant execute on function public.admin_mfa_reset_request(uuid, text), public.admin_mfa_reset_confirm(uuid, text)
  to authenticated;
grant execute on function public.mfa_reset_issue_code(uuid), public.mfa_reset_mark_sent(uuid, boolean, text),
  public.mfa_reset_execute(uuid), public.mfa_reset_notified(uuid, boolean)
  to service_role;
