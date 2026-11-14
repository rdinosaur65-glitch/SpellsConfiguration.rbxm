-- PULSE 0002 — accounts: profiles, settings, usernames, presence, signup trigger.

create type public.account_state as enum ('active', 'suspended', 'banned', 'deleting');

create table public.profiles (
  id uuid primary key references auth.users(id) on delete cascade,
  username extensions.citext not null unique
    check (username::text ~ '^[a-z0-9](?:[a-z0-9._]{1,18})[a-z0-9]$'
           and username::text !~ '[._]{2}'),
  display_name text not null check (char_length(btrim(display_name)) between 1 and 40),
  avatar_asset_id uuid,
  banner_asset_id uuid,
  bio text check (char_length(bio) <= 160),
  status_text text check (char_length(status_text) <= 60),
  status_expires_at timestamptz,
  profile_theme jsonb not null default '{}'::jsonb check (pg_column_size(profile_theme) <= 4096),
  account_state public.account_state not null default 'active',
  username_changed_at timestamptz,
  created_at timestamptz not null default now()
);

create table public.user_settings (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  -- appearance: theme mode, accent, typography, bubble style, animations (synced across devices)
  appearance jsonb not null default
    '{"mode":"dark","accent":"#8B5CF6","font":"system","bubbles":"rounded","reduce_motion":false}'::jsonb
    check (pg_column_size(appearance) <= 4096),
  ghost_mode boolean not null default false,
  show_online boolean not null default true,
  show_last_active boolean not null default true,
  show_typing boolean not null default true,
  show_recording boolean not null default true,
  data_saver boolean not null default false,
  notifications jsonb not null default
    '{"messages":true,"snaps":true,"calls":true,"friend_requests":true,"streaks":true,"on_this_day":false}'::jsonb,
  updated_at timestamptz not null default now()
);

-- Presence is private; friends read it only through get_friend_presence(), which
-- applies Ghost Mode and visibility settings server-side.
create table private.presence (
  user_id uuid primary key references public.profiles(id) on delete cascade,
  last_active_at timestamptz not null default now()
);

create table private.username_reservations (
  username extensions.citext primary key,
  user_id uuid not null references public.profiles(id) on delete cascade,
  reserved_until timestamptz not null
);

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------
create or replace function private.assert_active()
returns uuid
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := auth.uid(); v_state public.account_state;
begin
  if v_uid is null then perform private.fail('not_authenticated'); end if;
  select account_state into v_state from public.profiles where id = v_uid;
  if v_state is null then perform private.fail('no_profile'); end if;
  if v_state <> 'active' then perform private.fail('account_not_active', v_state::text); end if;
  return v_uid;
end $$;

create or replace function private.normalize_username(p text)
returns text language sql immutable as $$
  select lower(btrim(p))
$$;

create or replace function private.validate_username(p text)
returns text
language plpgsql immutable as $$
declare v text := private.normalize_username(p);
begin
  if v is null or v !~ '^[a-z0-9](?:[a-z0-9._]{1,18})[a-z0-9]$' or v ~ '[._]{2}' then
    perform private.fail('invalid_username');
  end if;
  if v in ('pulse','admin','owner','support','help','moderator','official','system','root') then
    perform private.fail('username_reserved');
  end if;
  return v;
end $$;

-- ---------------------------------------------------------------------------
-- Signup: create profile + settings; enforce registration cap and reservations.
-- ---------------------------------------------------------------------------
create or replace function private.handle_new_user()
returns trigger
language plpgsql security definer set search_path = '' as $$
declare
  v_cfg private.platform_config := private.config();
  v_username text;
  v_display text;
  v_count integer;
begin
  -- Serialise signups so the cap cannot be exceeded by concurrent registrations.
  perform pg_advisory_xact_lock(hashtext('pulse_registration'));
  select count(*) into v_count from public.profiles;
  if v_count >= v_cfg.registration_cap and new.id is distinct from v_cfg.owner_user_id then
    perform private.fail('registration_closed', 'free-tier capacity reached');
  end if;

  v_username := private.validate_username(new.raw_user_meta_data ->> 'username');
  if exists (select 1 from private.username_reservations
             where username = v_username::extensions.citext and reserved_until > now()) then
    perform private.fail('username_taken');
  end if;
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

create trigger on_auth_user_created
  after insert on auth.users
  for each row execute function private.handle_new_user();

-- ---------------------------------------------------------------------------
-- Username change: 48 h cooldown (owner exempt), old name reserved 30 days.
-- ---------------------------------------------------------------------------
create or replace function public.change_username(p_new text)
returns text
language plpgsql security definer set search_path = '' as $$
declare
  v_uid uuid := private.assert_active();
  v_cfg private.platform_config := private.config();
  v_new text := private.validate_username(p_new);
  v_old extensions.citext;
  v_changed timestamptz;
begin
  perform private.rate_limit_hit('change_username', 5, interval '1 hour');
  select username, username_changed_at into v_old, v_changed
    from public.profiles where id = v_uid for update;

  if v_old = v_new::extensions.citext then
    -- Allow pure case changes? Usernames are stored lower-case, so this is a no-op.
    return v_old::text;
  end if;
  if not private.is_owner(v_uid) and v_changed is not null
     and v_changed > now() - v_cfg.username_cooldown then
    perform private.fail('username_cooldown',
      to_char(v_changed + v_cfg.username_cooldown, 'YYYY-MM-DD"T"HH24:MI:SS"Z"'));
  end if;
  if exists (select 1 from private.username_reservations
             where username = v_new::extensions.citext and reserved_until > now()
               and user_id <> v_uid) then
    perform private.fail('username_taken');
  end if;

  begin
    update public.profiles set username = v_new, username_changed_at = now() where id = v_uid;
  exception when unique_violation then
    perform private.fail('username_taken');
  end;

  delete from private.username_reservations where username = v_new::extensions.citext;
  insert into private.username_reservations (username, user_id, reserved_until)
  values (v_old, v_uid, now() + v_cfg.username_reservation)
  on conflict (username) do update
    set user_id = excluded.user_id, reserved_until = excluded.reserved_until;
  return v_new;
end $$;
grant execute on function public.change_username(text) to authenticated;

-- Heartbeat for presence (client calls every ~60 s while foregrounded).
create or replace function public.touch_presence()
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active();
begin
  perform private.rate_limit_hit('touch_presence', 10, interval '1 minute');
  insert into private.presence (user_id, last_active_at) values (v_uid, now())
  on conflict (user_id) do update set last_active_at = now();
end $$;
grant execute on function public.touch_presence() to authenticated;

-- ---------------------------------------------------------------------------
-- RLS
-- ---------------------------------------------------------------------------
alter table public.profiles enable row level security;
alter table public.user_settings enable row level security;

-- Column-level privileges: clients may only update cosmetic profile fields.
revoke all on public.profiles from anon, authenticated;
grant select on public.profiles to authenticated;
grant update (display_name, bio, status_text, status_expires_at, profile_theme,
              avatar_asset_id, banner_asset_id) on public.profiles to authenticated;

revoke all on public.user_settings from anon, authenticated;
grant select, update (appearance, ghost_mode, show_online, show_last_active, show_typing,
                      show_recording, data_saver, notifications, updated_at)
  on public.user_settings to authenticated;

create policy settings_self_select on public.user_settings
  for select to authenticated using (user_id = auth.uid());
create policy settings_self_update on public.user_settings
  for update to authenticated using (user_id = auth.uid()) with check (user_id = auth.uid());

-- profiles select/update policies are created in 0003 once friendship helpers exist.
