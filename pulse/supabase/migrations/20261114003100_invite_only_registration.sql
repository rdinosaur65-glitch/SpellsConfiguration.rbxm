-- PULSE 0031 — invite-only registration, owner-controlled.
--
-- Every new auth.users row passes private.gate_registration() (BEFORE INSERT), whatever
-- created it: the app, a direct call to Supabase Auth (/signup, /otp), or the admin API.
-- In invite-only mode (the default) the row is accepted only if it carries a valid,
-- unused, unexpired, unrevoked invitation code in its user metadata ("invite_code"); the
-- invitation is redeemed by the same statement, inside the same transaction, so a failed
-- sign-up never consumes it and two sign-ups can never redeem one code (row lock + the
-- registration advisory lock). The code is removed from the stored metadata.
--
-- Public mode (owner switch) accepts sign-ups without a code, up to registration_cap.
-- Invite-only mode has no cap: each invitation is the owner's explicit consent.
--
-- The first owner is bootstrapped without an invitation only when ALL hold: no owner yet,
-- the address equals platform_config.owner_bootstrap_email, and the sign-up carries the
-- one-time bootstrap token whose SHA-256 is platform_config.owner_bootstrap_hash. Both are
-- set with database access only (scripts/bootstrap-owner.mjs); the token is used once and
-- never stored. Ownership is granted when that address is confirmed (proof of the inbox).

alter table private.platform_config
  add column if not exists registration_mode text not null default 'invite_only'
    check (registration_mode in ('invite_only', 'public')),
  add column if not exists owner_bootstrap_email text,
  add column if not exists owner_bootstrap_hash text,
  add column if not exists owner_bootstrap_user uuid;

-- Codes: 12 characters from a 32-letter alphabet without I, L, O, 1 (60 bits; shown as
-- XXXX-XXXX-XXXX). Stored only here, readable only through the owner's functions.
create table private.invitations (
  id uuid primary key default gen_random_uuid(),
  code text not null unique check (code ~ '^[A-HJKMNP-Z02-9]{12}$'),
  note text check (note is null or char_length(note) <= 60),
  created_by uuid,
  created_at timestamptz not null default now(),
  expires_at timestamptz not null,
  revoked_at timestamptz,
  revoked_by uuid,
  redeemed_at timestamptz,
  redeemed_by uuid,                 -- no FK: the user row does not exist yet when it is set
  redeemed_username text,
  check ((redeemed_at is null) = (redeemed_by is null)),
  check (not (revoked_at is not null and redeemed_at is not null))
);
create index invitations_created_idx on private.invitations (created_at desc);
create index invitations_redeemed_by_idx on private.invitations (redeemed_by) where redeemed_by is not null;

create or replace function private.new_invite_code()
returns text
language plpgsql volatile set search_path = '' as $$
declare
  v_alphabet constant text := 'ABCDEFGHJKMNPQRSTUVWXYZ023456789';   -- 32 symbols: & 31 is unbiased
  v_bytes bytea := extensions.gen_random_bytes(12);
  v_out text := '';
begin
  for i in 0..11 loop
    v_out := v_out || substr(v_alphabet, (get_byte(v_bytes, i) & 31) + 1, 1);
  end loop;
  return v_out;
end $$;

-- "abcd-efgh-jkmn", spaces, lower case and the letter O typed for zero all match.
create or replace function private.normalize_invite(p_code text)
returns text
language sql immutable set search_path = '' as $$
  select nullif(translate(upper(regexp_replace(coalesce(p_code, ''), '[^A-Za-z0-9]', '', 'g')), 'O', '0'), '')
$$;

create or replace function private.invitation_status(p_revoked timestamptz, p_redeemed timestamptz, p_expires timestamptz)
returns text
language sql stable set search_path = '' as $$
  select case when p_revoked is not null then 'revoked'
              when p_redeemed is not null then 'redeemed'
              when p_expires <= now() then 'expired'
              else 'pending' end
$$;

-- Metadata keys that only matter at sign-up and are never kept on the account.
create or replace function private.strip_signup_secrets()
returns trigger
language plpgsql set search_path = '' as $$
begin
  if new.raw_user_meta_data ?| array['invite_code', 'owner_bootstrap_token'] then
    new.raw_user_meta_data := new.raw_user_meta_data - 'invite_code' - 'owner_bootstrap_token';
  end if;
  return new;
end $$;

-- ---------------------------------------------------------------------------
-- The gate (BEFORE INSERT on auth.users).
-- ---------------------------------------------------------------------------
create or replace function private.gate_registration()
returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_cfg private.platform_config;
  v_code text := private.normalize_invite(new.raw_user_meta_data ->> 'invite_code');
  v_invite uuid;
  v_count integer;
begin
  -- One registration at a time (also taken by handle_new_user): no cap or invite races.
  perform pg_advisory_xact_lock(hashtext('pulse_registration'));
  v_cfg := private.config();

  if v_cfg.owner_user_id is null and v_cfg.owner_bootstrap_hash is not null
     and new.email is not null and lower(new.email) = lower(v_cfg.owner_bootstrap_email)
     and encode(extensions.digest(coalesce(new.raw_user_meta_data ->> 'owner_bootstrap_token', ''), 'sha256'), 'hex')
         = v_cfg.owner_bootstrap_hash then
    -- The first owner's account (token used up; ownership follows confirmation).
    update private.platform_config set owner_bootstrap_hash = null, owner_bootstrap_user = new.id where id;
  else
    if v_code is not null then
      update private.invitations
         set redeemed_at = now(), redeemed_by = new.id,
             redeemed_username = left(new.raw_user_meta_data ->> 'username', 40)
       where code = v_code and redeemed_at is null and revoked_at is null and expires_at > now()
      returning id into v_invite;
    end if;
    if v_invite is null then
      if v_cfg.registration_mode <> 'public' then
        perform private.fail(case when v_code is null then 'invite_required' else 'invite_invalid' end);
      end if;
      select count(*) into v_count from public.profiles where account_state <> 'deleting';
      if v_count >= v_cfg.registration_cap then
        perform private.fail('registration_closed', 'free-tier capacity reached');
      end if;
    end if;
  end if;

  return new;
end $$;

drop trigger if exists pulse_gate_registration on auth.users;
create trigger pulse_gate_registration
  before insert on auth.users
  for each row execute function private.gate_registration();

-- Supabase Auth writes the metadata again after creating the row, so strip on update too
-- (named to run after the gate: triggers fire in name order).
drop trigger if exists pulse_strip_signup_secrets on auth.users;
create trigger pulse_strip_signup_secrets
  before insert or update of raw_user_meta_data on auth.users
  for each row execute function private.strip_signup_secrets();

-- Profile creation no longer applies the cap (the gate does, in public mode only).
create or replace function private.handle_new_user()
returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_username text;
  v_display text;
begin
  perform pg_advisory_xact_lock(hashtext('pulse_registration'));
  v_username := private.validate_username(new.raw_user_meta_data ->> 'username');
  if private.username_unavailable(v_username) then perform private.fail('username_taken'); end if;
  if exists (select 1 from public.profiles where username = v_username::extensions.citext) then
    perform private.fail('username_taken');
  end if;

  v_display := coalesce(nullif(btrim(new.raw_user_meta_data ->> 'display_name'), ''), v_username);
  insert into public.profiles (id, username, display_name)
  values (new.id, v_username, left(v_display, 40));
  insert into public.user_settings (user_id) values (new.id);
  insert into private.presence (user_id) values (new.id);
  return new;
end $$;

-- Ownership for the bootstrap account, when its address is confirmed (once).
create or replace function private.promote_bootstrap_owner()
returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  if new.email_confirmed_at is not null
     and exists (select 1 from private.platform_config c
                  where c.id and c.owner_user_id is null and c.owner_bootstrap_user = new.id
                    and lower(c.owner_bootstrap_email) = lower(new.email)) then
    update private.platform_config
       set owner_user_id = new.id, owner_bootstrap_email = null, owner_bootstrap_user = null, updated_at = now()
     where id and owner_user_id is null;
    if found then
      insert into private.audit_log (actor_id, action, target_user_id, details)
      values (new.id, 'owner.bootstrapped', new.id, '{}'::jsonb);
    end if;
  end if;
  return null;
end $$;

drop trigger if exists pulse_promote_bootstrap_owner on auth.users;
create trigger pulse_promote_bootstrap_owner
  after insert or update of email_confirmed_at on auth.users
  for each row execute function private.promote_bootstrap_owner();

-- A never-confirmed sign-up that is purged gives its invitation back (if still valid,
-- it can be used again; otherwise it shows as expired).
create or replace function private.purge_unconfirmed_signups(p_age interval default null)
returns integer
language plpgsql security definer set search_path = '' as $$
declare v_n integer; v_age interval := coalesce(p_age, (private.config()).unconfirmed_signup_ttl);
begin
  with doomed as (
    select u.id from auth.users u
     where u.email_confirmed_at is null
       and coalesce(u.confirmation_sent_at, u.created_at) < now() - v_age
       and u.id is distinct from (private.config()).owner_user_id
       and not exists (select 1 from public.media_assets a where a.owner_id = u.id)
  ), released as (
    update private.invitations
       set redeemed_at = null, redeemed_by = null, redeemed_username = null
     where redeemed_by in (select id from doomed)
    returning 1
  )
  delete from auth.users where id in (select id from doomed);
  get diagnostics v_n = row_count;
  return v_n;
end $$;

-- ---------------------------------------------------------------------------
-- Owner functions (owner + own 2FA, via assert_owner).
-- ---------------------------------------------------------------------------
create or replace function public.admin_create_invitation(p_valid_hours integer, p_note text default null)
returns table (id uuid, code text, expires_at timestamptz)
language plpgsql security definer set search_path = '' as $$
declare
  v_owner uuid := private.assert_owner();
  v_note text := nullif(btrim(coalesce(p_note, '')), '');
  v_row private.invitations;
begin
  perform private.rate_limit_hit('create_invitation', 50, interval '1 hour');
  if p_valid_hours is null or p_valid_hours < 1 or p_valid_hours > 720 then
    perform private.fail('invalid_expiry', 'between 1 hour and 30 days');
  end if;
  if v_note is not null and char_length(v_note) > 60 then perform private.fail('note_too_long'); end if;
  for attempt in 1..5 loop
    begin
      insert into private.invitations (code, note, created_by, expires_at)
      values (private.new_invite_code(), v_note, v_owner, now() + make_interval(hours => p_valid_hours))
      returning * into v_row;
      exit;
    exception when unique_violation then
      if attempt = 5 then raise; end if;
    end;
  end loop;
  perform private.audit('registration.invite_created', null,
    jsonb_build_object('invitation_id', v_row.id, 'expires_at', v_row.expires_at, 'note', v_row.note));
  return query select v_row.id, v_row.code, v_row.expires_at;
end $$;

create or replace function public.admin_list_invitations(p_limit integer default 200)
returns table (id uuid, code text, note text, status text, created_at timestamptz, expires_at timestamptz,
               redeemed_at timestamptz, redeemed_username text, awaiting_confirmation boolean, revoked_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare v_owner uuid := private.assert_owner();
begin
  return query
  select i.id,
         case when private.invitation_status(i.revoked_at, i.redeemed_at, i.expires_at) = 'pending' then i.code end,
         i.note,
         private.invitation_status(i.revoked_at, i.redeemed_at, i.expires_at),
         i.created_at, i.expires_at, i.redeemed_at,
         coalesce(p.username::text, i.redeemed_username),
         i.redeemed_by is not null and exists (select 1 from auth.users u where u.id = i.redeemed_by and u.email_confirmed_at is null),
         i.revoked_at
    from private.invitations i
    left join public.profiles p on p.id = i.redeemed_by
   order by i.created_at desc
   limit least(greatest(coalesce(p_limit, 200), 1), 500);
end $$;

create or replace function public.admin_revoke_invitation(p_id uuid)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_owner uuid := private.assert_owner();
begin
  update private.invitations set revoked_at = now(), revoked_by = v_owner
   where id = p_id and revoked_at is null and redeemed_at is null and expires_at > now();
  if not found then perform private.fail('invitation_not_pending'); end if;
  perform private.audit('registration.invite_revoked', null, jsonb_build_object('invitation_id', p_id));
end $$;

create or replace function public.admin_set_registration(p_mode text, p_cap integer default null)
returns jsonb
language plpgsql security definer set search_path = '' as $$
declare v_owner uuid := private.assert_owner(); v_cfg private.platform_config;
begin
  if p_mode not in ('invite_only', 'public') then perform private.fail('invalid_mode'); end if;
  if p_cap is not null and (p_cap < 1 or p_cap > 10000) then perform private.fail('invalid_cap'); end if;
  update private.platform_config
     set registration_mode = p_mode, registration_cap = coalesce(p_cap, registration_cap), updated_at = now()
   where id
  returning * into v_cfg;
  perform private.audit('registration.mode_changed', null,
    jsonb_build_object('mode', v_cfg.registration_mode, 'cap', v_cfg.registration_cap));
  return jsonb_build_object('mode', v_cfg.registration_mode, 'cap', v_cfg.registration_cap);
end $$;

-- Usage summary gains the registration settings.
create or replace function public.admin_usage_summary()
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare v_owner uuid := private.assert_owner(); v_cfg private.platform_config := private.config();
begin
  return jsonb_build_object(
    'accounts', (select count(*) from public.profiles),
    'registration_cap', v_cfg.registration_cap,
    'registration_mode', v_cfg.registration_mode,
    'pending_invitations', (select count(*) from private.invitations
                             where revoked_at is null and redeemed_at is null and expires_at > now()),
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

-- ---------------------------------------------------------------------------
-- For the sign-up screen (signed out): the mode, and whether a code can be used.
-- Says nothing about who an invitation is for. Guessing a code is not practical
-- (2^60 possibilities), and checking never consumes one.
-- ---------------------------------------------------------------------------
create or replace function public.registration_status(p_code text default null)
returns jsonb
language plpgsql stable security definer set search_path = '' as $$
declare
  v_cfg private.platform_config := private.config();
  v_code text := private.normalize_invite(p_code);
  v_status text;
begin
  if v_code is not null then
    select private.invitation_status(i.revoked_at, i.redeemed_at, i.expires_at) into v_status
      from private.invitations i where i.code = v_code;
  end if;
  return jsonb_build_object(
    'mode', v_cfg.registration_mode,
    'invite', case when v_code is null then null else coalesce(v_status, 'invalid') end,
    'public_full', v_cfg.registration_mode = 'public'
                   and (select count(*) from public.profiles where account_state <> 'deleting') >= v_cfg.registration_cap);
end $$;

revoke execute on function
  private.new_invite_code(), private.normalize_invite(text),
  private.invitation_status(timestamptz, timestamptz, timestamptz), private.strip_signup_secrets(),
  private.gate_registration(), private.promote_bootstrap_owner(), private.purge_unconfirmed_signups(interval),
  public.admin_create_invitation(integer, text), public.admin_list_invitations(integer),
  public.admin_revoke_invitation(uuid), public.admin_set_registration(text, integer),
  public.admin_usage_summary(), public.registration_status(text)
  from public, anon, authenticated;
grant execute on function
  public.admin_create_invitation(integer, text), public.admin_list_invitations(integer),
  public.admin_revoke_invitation(uuid), public.admin_set_registration(text, integer),
  public.admin_usage_summary()
  to authenticated;
grant execute on function public.registration_status(text) to anon, authenticated;
