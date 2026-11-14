-- PULSE 0026 — owner 2FA reset: a request replaced by a newer one is now audited
-- ('account.mfa_reset.cancelled'), so every request in the audit log has a recorded end.

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
  -- A new attempt replaces any open one for this target (its code can no longer be used);
  -- each replaced request is audited, so every request has a recorded end.
  with cancelled as (
    update private.mfa_reset_requests set status = 'cancelled', code_hash = null
     where target_id = p_user and status in ('awaiting_email', 'sending', 'pending', 'verified')
    returning id, status)
  insert into private.audit_log (actor_id, action, target_user_id, details)
  select v_owner, 'account.mfa_reset.cancelled', p_user, jsonb_build_object('request_id', id, 'replaced', true)
    from cancelled;
  insert into private.mfa_reset_requests (owner_id, target_id, reason)
  values (v_owner, p_user, left(btrim(p_reason), 500))
  returning id into v_id;
  perform private.audit('account.mfa_reset.requested', p_user, jsonb_build_object('request_id', v_id, 'reason', btrim(p_reason)));
  return v_id;
end $$;
revoke execute on function public.admin_mfa_reset_request(uuid, text) from public, anon;
grant execute on function public.admin_mfa_reset_request(uuid, text) to authenticated;
