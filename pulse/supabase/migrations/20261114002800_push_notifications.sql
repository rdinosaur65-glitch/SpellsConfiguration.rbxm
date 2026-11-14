-- PULSE 0028 — push notifications (standard Web Push with VAPID; free, no third-party account).
--
-- * A device subscribes in Settings; the browser's push service (Google/Mozilla/Apple/
--   Microsoft) gives an endpoint and keys, stored here per account and per sign-in session.
--   Pushes go only to devices whose session is still signed in: signing out, "sign out
--   everywhere", an admin reset or account deletion stops them.
-- * New messages, Snaps and friend requests are queued by triggers; pg_net then calls the
--   push-send Edge Function (same Vault secret as the storage janitor), which encrypts and
--   sends them. Nothing is queued when no recipient has a device subscribed.
-- * A notification says who it is from and "New Chat" / "New Snap" — never the message
--   text (PULSE shows no previews, by design). Mutes, blocks, account state and each
--   person's notification settings are respected.
-- * Endpoints must belong to a known push service (no requests to arbitrary URLs).

create table if not exists private.push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  user_id uuid not null references public.profiles(id) on delete cascade,
  session_id uuid,                                        -- the sign-in session that subscribed
  endpoint text not null unique check (char_length(endpoint) between 20 and 1024),
  p256dh text not null check (p256dh ~ '^[A-Za-z0-9_-]{86,88}$'),   -- 65-byte P-256 key, base64url
  auth text not null check (auth ~ '^[A-Za-z0-9_-]{21,24}$'),       -- 16-byte secret, base64url
  created_at timestamptz not null default now(),
  last_sent_at timestamptz
);
create index if not exists push_subscriptions_user on private.push_subscriptions (user_id);

create table if not exists private.push_queue (
  id bigserial primary key,
  kind text not null check (kind in ('message', 'friend_request')),
  ref_id uuid not null,                                   -- message id or friend request id
  created_at timestamptz not null default now()
);

-- Test deployments may add endpoint prefixes (e.g. a local mock push service).
alter table private.platform_config add column if not exists push_test_prefixes text[] not null default '{}';

create or replace function private.push_endpoint_allowed(p_endpoint text)
returns boolean
language sql stable security definer set search_path = '' as $$
  select p_endpoint ~ '^https://(fcm\.googleapis\.com|updates\.push\.services\.mozilla\.com|web\.push\.apple\.com|[a-z0-9-]+\.notify\.windows\.com)/[^\s]+$'
      or exists (select 1 from unnest((private.config()).push_test_prefixes) p where p <> '' and starts_with(p_endpoint, p))
$$;

-- Save this device's subscription for the signed-in account (re-subscribing replaces it).
create or replace function public.save_push_subscription(p_endpoint text, p_p256dh text, p_auth text)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_session uuid := nullif(auth.jwt() ->> 'session_id', '')::uuid;
begin
  perform private.rate_limit_hit('save_push_subscription', 20, interval '1 hour');
  if p_endpoint is null or not private.push_endpoint_allowed(p_endpoint) then perform private.fail('push_endpoint_invalid'); end if;
  if p_p256dh !~ '^[A-Za-z0-9_-]{86,88}$' or p_auth !~ '^[A-Za-z0-9_-]{21,24}$' then perform private.fail('push_keys_invalid'); end if;
  insert into private.push_subscriptions (user_id, session_id, endpoint, p256dh, auth)
  values (v_uid, v_session, p_endpoint, p_p256dh, p_auth)
  on conflict (endpoint) do update
     set user_id = excluded.user_id, session_id = excluded.session_id, p256dh = excluded.p256dh,
         auth = excluded.auth, created_at = now();
  -- At most 10 devices per account: drop the oldest.
  delete from private.push_subscriptions where id in (
    select id from private.push_subscriptions where user_id = v_uid order by created_at desc offset 10);
end $$;

create or replace function public.delete_push_subscription(p_endpoint text)
returns void
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := auth.uid();
begin
  -- Works for suspended accounts too (a device must always be able to stop its pushes).
  if v_uid is null then perform private.fail('not_authenticated'); end if;
  perform private.assert_mfa();
  perform private.rate_limit_hit('delete_push_subscription', 60, interval '1 hour');
  delete from private.push_subscriptions where endpoint = p_endpoint and user_id = v_uid;
end $$;

create or replace function public.has_push_subscription(p_endpoint text)
returns boolean
language sql stable security definer set search_path = '' as $$
  select private.mfa_satisfied()
     and exists (select 1 from private.push_subscriptions where endpoint = p_endpoint and user_id = auth.uid())
$$;

-- Ask the push-send function to deliver what is queued (after commit, via pg_net).
create or replace function private.invoke_push()
returns bigint
language plpgsql security definer set search_path = '' as $$
declare v_url text; v_secret text; v_id bigint;
begin
  if to_regclass('vault.decrypted_secrets') is null or to_regproc('net.http_post') is null then return null; end if;
  execute $q$select decrypted_secret from vault.decrypted_secrets where name = 'pulse_janitor_url'$q$ into v_url;
  execute $q$select decrypted_secret from vault.decrypted_secrets where name = 'pulse_janitor_secret'$q$ into v_secret;
  if v_url is null or v_secret is null then return null; end if;
  v_url := regexp_replace(v_url, 'storage-janitor/?$', 'push-send');
  execute 'select net.http_post(url := $1, body := $2, headers := $3, timeout_milliseconds := 15000)'
     into v_id
    using v_url, '{}'::jsonb, jsonb_build_object('Content-Type', 'application/json', 'x-janitor-secret', v_secret);
  return v_id;
end $$;

create or replace function private.enqueue_push()
returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  begin
    if tg_table_name = 'messages' then
      if exists (select 1 from public.conversation_members cm
                   join private.push_subscriptions ps on ps.user_id = cm.user_id
                  where cm.conversation_id = new.conversation_id and cm.user_id <> new.sender_id and cm.left_at is null) then
        insert into private.push_queue (kind, ref_id) values ('message', new.id);
        perform private.invoke_push();
      end if;
    elsif new.status = 'pending' and exists (select 1 from private.push_subscriptions where user_id = new.recipient_id) then
      insert into private.push_queue (kind, ref_id) values ('friend_request', new.id);
      perform private.invoke_push();
    end if;
  exception when others then
    null;   -- a notification problem must never stop a message or request
  end;
  return null;
end $$;

drop trigger if exists messages_push on public.messages;
create trigger messages_push after insert on public.messages
  for each row when (new.kind <> 'system') execute function private.enqueue_push();
drop trigger if exists friend_requests_push on public.friend_requests;
create trigger friend_requests_push after insert on public.friend_requests
  for each row execute function private.enqueue_push();

-- push-send: claim queued events and get, per subscribed device, what to show.
create or replace function public.push_claim(p_limit integer default 100)
returns table (subscription_id uuid, endpoint text, p256dh text, auth text,
               title text, body text, url text, tag text)
language plpgsql security definer set search_path = '' as $$
begin
  return query
  with claimed as (
    delete from private.push_queue q
     where q.id in (select id from private.push_queue order by id limit greatest(1, least(p_limit, 500)) for update skip locked)
    returning q.kind, q.ref_id
  ), msg as (
    select cm.user_id as rid,
      case when cv.kind = 'group' then coalesce(cv.name, 'Group')
           else coalesce(n.nickname, sp.display_name) end as title,
      case when cv.kind = 'group' then coalesce(n.nickname, sp.display_name) || ' · ' else '' end
        || case when m.kind = 'snap' then 'New Snap' else 'New Chat' end as body,
      '/chats/' || cv.id as url, 'chat:' || cv.id as tag
    from claimed c
    join public.messages m on m.id = c.ref_id and m.deleted_at is null
    join public.conversations cv on cv.id = m.conversation_id
    join public.profiles sp on sp.id = m.sender_id
    join public.conversation_members cm on cm.conversation_id = m.conversation_id and cm.left_at is null
                                       and cm.user_id <> m.sender_id and cm.joined_at <= m.created_at
    join public.profiles rp on rp.id = cm.user_id and rp.account_state = 'active'
    left join public.friend_nicknames n on n.owner_id = cm.user_id and n.friend_id = m.sender_id
    left join public.user_settings us on us.user_id = cm.user_id
    where c.kind = 'message'
      and (cm.muted_until is null or cm.muted_until <= now())
      and not private.is_blocked_either(cm.user_id, m.sender_id)
      and coalesce((us.notifications ->> case when m.kind = 'snap' then 'snaps' else 'messages' end)::boolean, true)
  ), req as (
    select fr.recipient_id as rid, 'New friend request'::text as title,
      '@' || sp.username || ' wants to be friends' as body, '/friends'::text as url, 'friend-requests'::text as tag
    from claimed c
    join public.friend_requests fr on fr.id = c.ref_id and fr.status = 'pending'
    join public.profiles sp on sp.id = fr.sender_id and sp.account_state = 'active'
    join public.profiles rp on rp.id = fr.recipient_id and rp.account_state = 'active'
    left join public.user_settings us on us.user_id = fr.recipient_id
    where c.kind = 'friend_request'
      and not private.is_blocked_either(fr.recipient_id, fr.sender_id)
      and coalesce((us.notifications ->> 'friend_requests')::boolean, true)
  ), targets as (select * from msg union all select * from req)
  select ps.id, ps.endpoint, ps.p256dh, ps.auth, t.title, t.body, t.url, t.tag
    from targets t
    join private.push_subscriptions ps on ps.user_id = t.rid
    -- Only devices that are still signed in to that account.
    join auth.sessions s on s.id = ps.session_id and s.user_id = ps.user_id
   where private.push_endpoint_allowed(ps.endpoint);
end $$;

-- push-send: the push service said the subscription is gone (404/410) or was used.
create or replace function public.push_report(p_gone uuid[], p_sent uuid[])
returns void
language plpgsql security definer set search_path = '' as $$
begin
  delete from private.push_subscriptions where id = any (coalesce(p_gone, '{}'));
  update private.push_subscriptions set last_sent_at = now() where id = any (coalesce(p_sent, '{}'));
  -- Devices whose sign-in session has ended will never be sent to again.
  delete from private.push_subscriptions ps
   where ps.session_id is null
      or not exists (select 1 from auth.sessions s where s.id = ps.session_id and s.user_id = ps.user_id);
end $$;

revoke execute on function private.push_endpoint_allowed(text), private.invoke_push(), private.enqueue_push()
  from public, anon, authenticated;
revoke execute on function public.save_push_subscription(text, text, text), public.delete_push_subscription(text),
  public.has_push_subscription(text), public.push_claim(integer), public.push_report(uuid[], uuid[])
  from public, anon, authenticated;
grant execute on function public.save_push_subscription(text, text, text), public.delete_push_subscription(text),
  public.has_push_subscription(text) to authenticated;
grant execute on function public.push_claim(integer), public.push_report(uuid[], uuid[]) to service_role;
