-- PULSE 0023 — the per-user daily download share (40 MB) is smaller than the largest file
-- PULSE accepts (50 MB backups and memory videos), so such a file could be uploaded but
-- never downloaded again. The first download of the day is now always allowed; the share
-- applies from the second one on. The project-wide daily budget still applies to every call.
create or replace function private.charge_egress_for(p_asset uuid, p_bytes bigint)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_user bigint;
begin
  -- Every authorisation is charged: media-url streams exactly one copy per call.
  insert into private.usage_daily as u (user_id, day, egress_bytes)
  values (v_uid, (now() at time zone 'utc')::date, p_bytes)
  on conflict (user_id, day) do update set egress_bytes = u.egress_bytes + excluded.egress_bytes
  returning egress_bytes into v_user;
  if v_user > (private.config()).daily_egress_user_bytes and v_user - p_bytes > 0 then
    perform private.fail('egress_quota_exceeded');
  end if;
  perform private.charge_egress(p_bytes);
end $$;
