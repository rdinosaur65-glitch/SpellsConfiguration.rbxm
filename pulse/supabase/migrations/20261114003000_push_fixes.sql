-- PULSE 0030 — fixes from the review of push notifications (0028).
--
-- 1. A notification setting that is not a JSON boolean (any user can write their own
--    settings) made push_claim fail on a type cast, which rolled back the claim and jammed
--    the queue for everyone. Settings are now read safely: anything but an explicit false
--    means "on", and nothing can make the claim fail.
-- 2. The function is called only when someone will really get a notification (a signed-in
--    device, not muted, the category on, no block), not for every message in a chat where
--    somebody once subscribed. Fewer calls against the free 500,000 a month.
-- 3. At most one friend-request notification per sender and recipient a day (sending and
--    cancelling could otherwise buzz a stranger's phone over and over).
-- 4. A one-minute sweep retries anything left in the queue (e.g. a failed call) and drops
--    entries older than a day; events older than an hour are dropped rather than sent late.
-- 5. At most one call to push-send per transaction (a Snap to many friends made one per row).
-- 6. A device that signs in again re-binds its subscription to the new session
--    (rebind_push_subscription); "on" is reported only while that session is live.

create or replace function private.push_wanted(p_user uuid, p_key text)
returns boolean
language sql stable security definer set search_path = '' as $$
  select not coalesce((select us.notifications -> p_key = 'false'::jsonb from public.user_settings us where us.user_id = p_user), false)
$$;

create or replace function private.push_device_live(p_user uuid)
returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from private.push_subscriptions ps
                   join auth.sessions s on s.id = ps.session_id and s.user_id = ps.user_id
                  where ps.user_id = p_user)
$$;

create or replace function private.enqueue_push()
returns trigger
language plpgsql security definer set search_path = '' as $$
begin
  begin
    if tg_table_name = 'messages' then
      if exists (select 1 from public.conversation_members cm
                   join public.profiles p on p.id = cm.user_id and p.account_state = 'active'
                  where cm.conversation_id = new.conversation_id and cm.user_id <> new.sender_id and cm.left_at is null
                    and (cm.muted_until is null or cm.muted_until <= now())
                    and private.push_wanted(cm.user_id, case when new.kind = 'snap' then 'snaps' else 'messages' end)
                    and not private.is_blocked_either(cm.user_id, new.sender_id)
                    and private.push_device_live(cm.user_id)) then
        insert into private.push_queue (kind, ref_id) values ('message', new.id);
        perform private.invoke_push();
      end if;
    elsif new.status = 'pending'
      and private.push_wanted(new.recipient_id, 'friend_requests')
      and private.push_device_live(new.recipient_id)
      and not private.is_blocked_either(new.recipient_id, new.sender_id)
      and not exists (select 1 from public.friend_requests f
                       where f.sender_id = new.sender_id and f.recipient_id = new.recipient_id
                         and f.id <> new.id and f.created_at > now() - interval '24 hours') then
      insert into private.push_queue (kind, ref_id) values ('friend_request', new.id);
      perform private.invoke_push();
    end if;
  exception when others then
    null;   -- a notification problem must never stop a message or request
  end;
  return null;
end $$;

create or replace function public.push_claim(p_limit integer default 100)
returns table (subscription_id uuid, endpoint text, p256dh text, auth text,
               title text, body text, url text, tag text)
language plpgsql security definer set search_path = '' as $$
begin
  return query
  with claimed as (
    delete from private.push_queue q
     where q.id in (select id from private.push_queue order by id limit greatest(1, least(p_limit, 500)) for update skip locked)
    returning q.kind, q.ref_id, q.created_at
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
    where c.kind = 'message' and c.created_at > now() - interval '1 hour'
      and (cm.muted_until is null or cm.muted_until <= now())
      and not private.is_blocked_either(cm.user_id, m.sender_id)
      and private.push_wanted(cm.user_id, case when m.kind = 'snap' then 'snaps' else 'messages' end)
  ), req as (
    select fr.recipient_id as rid, 'New friend request'::text as title,
      '@' || sp.username || ' wants to be friends' as body, '/friends'::text as url, 'friend-requests'::text as tag
    from claimed c
    join public.friend_requests fr on fr.id = c.ref_id and fr.status = 'pending'
    join public.profiles sp on sp.id = fr.sender_id and sp.account_state = 'active'
    join public.profiles rp on rp.id = fr.recipient_id and rp.account_state = 'active'
    where c.kind = 'friend_request' and c.created_at > now() - interval '1 hour'
      and not private.is_blocked_either(fr.recipient_id, fr.sender_id)
      and private.push_wanted(fr.recipient_id, 'friend_requests')
  ), targets as (select * from msg union all select * from req)
  select ps.id, ps.endpoint, ps.p256dh, ps.auth, t.title, t.body, t.url, t.tag
    from targets t
    join private.push_subscriptions ps on ps.user_id = t.rid
    -- Only devices that are still signed in to that account.
    join auth.sessions s on s.id = ps.session_id and s.user_id = ps.user_id
   where private.push_endpoint_allowed(ps.endpoint);
end $$;
revoke execute on function public.push_claim(integer) from public, anon, authenticated;
grant execute on function public.push_claim(integer) to service_role;

create or replace function private.push_sweep()
returns void
language plpgsql security definer set search_path = '' as $$
begin
  delete from private.push_queue where created_at < now() - interval '1 day';
  if exists (select 1 from private.push_queue where created_at < now() - interval '30 seconds') then
    perform private.invoke_push();
  end if;
end $$;

revoke execute on function private.push_wanted(uuid, text), private.push_device_live(uuid), private.enqueue_push(),
  private.push_sweep() from public, anon, authenticated;

do $$
begin
  if exists (select 1 from pg_extension where extname = 'pg_cron') then
    perform cron.unschedule(jobid) from cron.job where jobname = 'pulse-push-sweep';
    perform cron.schedule('pulse-push-sweep', '* * * * *', 'select private.push_sweep()');
  end if;
end $$;

-- One call per transaction: pg_net sends after commit, and one run drains the whole queue.
create or replace function private.invoke_push()
returns bigint
language plpgsql security definer set search_path = '' as $$
declare v_url text; v_secret text; v_id bigint;
begin
  if current_setting('pulse.push_invoked', true) = 'on' then return null; end if;
  if to_regclass('vault.decrypted_secrets') is null or to_regproc('net.http_post') is null then return null; end if;
  execute $q$select decrypted_secret from vault.decrypted_secrets where name = 'pulse_janitor_url'$q$ into v_url;
  execute $q$select decrypted_secret from vault.decrypted_secrets where name = 'pulse_janitor_secret'$q$ into v_secret;
  if v_url is null or v_secret is null then return null; end if;
  v_url := regexp_replace(v_url, 'storage-janitor/?$', 'push-send');
  execute 'select net.http_post(url := $1, body := $2, headers := $3, timeout_milliseconds := 15000)'
     into v_id
    using v_url, '{}'::jsonb, jsonb_build_object('Content-Type', 'application/json', 'x-janitor-secret', v_secret);
  perform set_config('pulse.push_invoked', 'on', true);
  return v_id;
end $$;

-- push-send: is anything still waiting? (A claimed batch can yield no device at all.)
create or replace function public.push_pending()
returns boolean
language sql stable security definer set search_path = '' as $$
  select exists (select 1 from private.push_queue)
$$;

-- "On" only while this device's sign-in session is live.
create or replace function public.has_push_subscription(p_endpoint text)
returns boolean
language sql stable security definer set search_path = '' as $$
  select private.mfa_satisfied() and exists (
    select 1 from private.push_subscriptions ps join auth.sessions s on s.id = ps.session_id and s.user_id = ps.user_id
     where ps.endpoint = p_endpoint and ps.user_id = auth.uid())
$$;

-- After signing in again on the same device: move its subscription to the new session.
-- Only the account that turned notifications on here can do this.
create or replace function public.rebind_push_subscription(p_endpoint text)
returns boolean
language plpgsql security definer set search_path = '' as $$
declare v_uid uuid := private.assert_active(); v_session uuid := nullif(auth.jwt() ->> 'session_id', '')::uuid;
begin
  perform private.rate_limit_hit('rebind_push_subscription', 30, interval '1 hour');
  update private.push_subscriptions set session_id = v_session
   where endpoint = p_endpoint and user_id = v_uid and v_session is not null;
  return found;
end $$;

revoke execute on function private.invoke_push(), public.push_pending(), public.has_push_subscription(text),
  public.rebind_push_subscription(text) from public, anon, authenticated;
grant execute on function public.push_pending() to service_role;
grant execute on function public.has_push_subscription(text), public.rebind_push_subscription(text) to authenticated;
