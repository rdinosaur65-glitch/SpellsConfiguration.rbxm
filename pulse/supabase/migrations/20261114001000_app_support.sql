-- PULSE 0010 — RPCs the web app needs, plus cleanup of never-confirmed signups.
-- Found while building the UI against a real local Supabase stack:
--  * Non-friends cannot read each other's profiles (by design), so the UI could not
--    show who sent a friend request. my_friend_requests() returns minimal cards.
--  * The profile row is created at signup, before email confirmation, so an
--    unconfirmed signup held its username and a registration slot forever.

-- Pending requests in both directions, with the other person's minimal card.
create or replace function public.my_friend_requests()
returns table (id uuid, direction text, user_id uuid, username text, display_name text,
               created_at timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active();
begin
  return query
    select r.id,
           case when r.recipient_id = v_uid then 'incoming' else 'outgoing' end,
           p.id, p.username::text, p.display_name, r.created_at
    from public.friend_requests r
    join public.profiles p on p.id = case when r.recipient_id = v_uid then r.sender_id else r.recipient_id end
    where r.status = 'pending'
      and (r.recipient_id = v_uid or r.sender_id = v_uid)
      and p.account_state = 'active'
      and not private.is_blocked_either(v_uid, p.id)
    order by r.created_at desc
    limit 200;
end $$;

-- Friends with the caller's private nickname/colour and privacy-filtered presence.
create or replace function public.list_friends()
returns table (user_id uuid, username text, display_name text, nickname text,
               nickname_color text, avatar_asset_id uuid, online boolean,
               last_active_at timestamptz, friends_since timestamptz)
language plpgsql stable security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active();
begin
  return query
    select p.id, p.username::text, p.display_name, n.nickname, n.color, p.avatar_asset_id,
      case when s.ghost_mode or not s.show_online then null
           else pr.last_active_at > now() - interval '2 minutes' end,
      case when s.ghost_mode or not s.show_last_active then null else pr.last_active_at end,
      f.created_at
    from public.friendships f
    join public.profiles p on p.id = case when f.user_a = v_uid then f.user_b else f.user_a end
    join public.user_settings s on s.user_id = p.id
    left join private.presence pr on pr.user_id = p.id
    left join public.friend_nicknames n on n.owner_id = v_uid and n.friend_id = p.id
    where (f.user_a = v_uid or f.user_b = v_uid)
      and p.account_state = 'active'
      and not private.is_blocked_either(v_uid, p.id)
    order by lower(coalesce(n.nickname, p.display_name));
end $$;

-- Delete accounts whose email was never confirmed after 48 hours. This frees the
-- username and the registration slot. Confirmed, OAuth and owner accounts are untouched.
create or replace function private.purge_unconfirmed_signups(p_age interval default interval '48 hours')
returns integer
language plpgsql security definer set search_path = '' as $$
declare v_n integer;
begin
  delete from auth.users u
   where u.email_confirmed_at is null
     and u.created_at < now() - p_age
     and u.id is distinct from (private.config()).owner_user_id
     and not exists (select 1 from public.media_assets a where a.owner_id = u.id);
  get diagnostics v_n = row_count;
  return v_n;
end $$;

revoke execute on function public.my_friend_requests(), public.list_friends(),
  private.purge_unconfirmed_signups(interval) from public, anon, authenticated;
grant execute on function public.my_friend_requests(), public.list_friends() to authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.schedule('pulse-purge-unconfirmed', '23 * * * *',
                          'select private.purge_unconfirmed_signups()');
  end if;
end $$;
