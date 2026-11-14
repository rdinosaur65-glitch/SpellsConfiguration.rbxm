-- PULSE 0019 — account recovery for testers who lose their authenticator.
-- Supabase TOTP has no backup codes, so without this a lost phone means a lost account.
-- The owner (at aal2) can remove a user's factors after confirming their identity outside
-- the app. The password is still required to sign in; all sessions are signed out; the
-- action is audited. The owner cannot use it on their own account (use a second device).
create or replace function public.admin_reset_mfa(p_user uuid, p_reason text)
returns integer
language plpgsql security definer set search_path = '' as $$
declare v_owner uuid := private.assert_owner(); v_n integer;
begin
  if p_user = v_owner then perform private.fail('cannot_moderate_owner'); end if;
  if p_reason is null or char_length(btrim(p_reason)) = 0 then perform private.fail('reason_required'); end if;
  if not exists (select 1 from public.profiles where id = p_user) then perform private.fail('user_not_found'); end if;
  delete from auth.mfa_factors where user_id = p_user;
  get diagnostics v_n = row_count;
  perform private.revoke_sessions(p_user);
  perform private.audit('account.mfa_reset', p_user, jsonb_build_object('reason', p_reason, 'factors_removed', v_n));
  return v_n;
end $$;
revoke execute on function public.admin_reset_mfa(uuid, text) from public, anon;
grant execute on function public.admin_reset_mfa(uuid, text) to authenticated;
