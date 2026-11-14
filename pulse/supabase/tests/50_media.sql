-- Media: validation, deduplication, quotas, pool ceilings, storage policies, upload
-- verification, access control, egress budget, rate limiting.
do $$
declare u uuid; v uuid; a1 uuid; a2 uuid; p text; h text := repeat('b', 64); n integer;
begin
  u := test.new_user('uploader_50'); v := test.new_user('viewer_50');
  perform test.as_user(u);
  perform test.throws($q$select public.authorize_upload('chat', 'application/x-msdownload', 100, repeat('c', 64))$q$,
                      'invalid_media_type', 'executables rejected');
  perform test.throws($q$select public.authorize_upload('chat', 'image/jpeg', 6000000, repeat('c', 64))$q$,
                      'media_too_large', 'photo size cap');
  perform test.throws($q$select public.authorize_upload('chat', 'video/mp4', 1000, repeat('c', 64))$q$,
                      'duration_required', 'video needs duration');
  perform test.throws($q$select public.authorize_upload('memory_backup', 'video/mp4', 1000, repeat('c', 64), 301)$q$,
                      'media_too_long', '5 minute Memories video cap');
  perform test.throws($q$select public.authorize_upload('chat', 'image/jpeg', 100, 'not-a-hash')$q$,
                      'invalid_hash', 'hash format');

  -- Deduplication.
  select asset_id into a1 from public.authorize_upload('chat', 'image/jpeg', 1000, h);
  select asset_id into a2 from public.authorize_upload('chat', 'image/jpeg', 1000, h);
  perform test.ok(a1 = a2, 'same content -> same asset');
  perform test.ok((select deduplicated from public.authorize_upload('chat', 'image/jpeg', 1000, h)), 'flagged as dedupe');

  -- Storage policy: only reserved paths, only in own folder.
  perform test.throws(format($q$insert into storage.objects (bucket_id, name, owner, metadata) values ('media', %L, %L, '{}')$q$,
                             u || '/chat/' || gen_random_uuid(), u), 'sqlstate:42501', 'unreserved path rejected');
  p := (select object_path from public.media_assets where id = a1);
  perform test.as_user(v);
  perform test.throws(format($q$insert into storage.objects (bucket_id, name, owner, metadata) values ('media', %L, %L, '{}')$q$, p, v),
                      'sqlstate:42501', 'cannot upload into someone else''s reservation');

  -- Upload verification: stored object larger than declared -> rejected, quota released.
  perform test.as_user(u);
  insert into storage.objects (bucket_id, name, owner, metadata)
  values ('media', p, u, jsonb_build_object('size', 999999, 'mimetype', 'image/jpeg'));
  perform test.ok(not public.confirm_upload(a1), 'oversized object rejected');
  perform test.ok((select status from public.media_assets where id = a1) = 'deleting', 'rejected upload queued for deletion');
  perform test.as_superuser();
end $$;

-- Memories quota (50 MB per user) and platform pool ceilings.
do $$
declare u uuid := (select id from public.profiles where username = 'uploader_50'); used bigint;
begin
  perform test.upload(u, 'memory_backup', 'video/mp4', 30000000, 120);
  perform test.as_user(u);
  perform test.throws($q$select public.authorize_upload('memory_backup', 'video/mp4', 30000000, repeat('d', 64), 120)$q$,
                      'memories_quota_full', 'per-user Memories quota');
  perform test.ok((select percent from public.my_storage_usage()) between 55 and 60, 'usage meter accurate');
  perform test.as_superuser();
  select bytes_used into used from private.storage_pools where pool = 'ephemeral';
  update private.storage_pools set bytes_limit = used + 500 where pool = 'ephemeral';
  perform test.as_user(u);
  perform test.throws($q$select public.authorize_upload('chat', 'image/jpeg', 1000, repeat('e', 64))$q$,
                      'storage_pool_full', 'platform pool ceiling');
  perform test.as_superuser();
  update private.storage_pools set bytes_limit = 419430400 where pool = 'ephemeral';
end $$;

-- Access control for non-snap media + egress budget.
do $$
declare u uuid := (select id from public.profiles where username = 'uploader_50');
        v uuid := (select id from public.profiles where username = 'viewer_50');
        x uuid; img uuid; mem uuid; conv uuid; msg uuid;
begin
  x := test.new_user('stranger_50');
  perform test.befriend(u, v);
  img := test.upload(u, 'chat', 'image/webp', 50000);
  mem := (select id from public.media_assets where owner_id = u and purpose = 'memory_backup' and status = 'uploaded' limit 1);
  perform test.as_user(u);
  conv := public.create_direct_conversation(v);
  msg := public.send_message(conv, 'photo', null, gen_random_uuid(), img);
  perform test.throws(format($q$select public.send_message(%L, 'photo', null, gen_random_uuid(), %L)$q$, conv, mem),
                      'invalid_media', 'cannot attach a Memories asset to chat');

  perform public.send_message(conv, 'text', 'see https://example.org', gen_random_uuid());
  perform test.as_user(v);
  perform test.ok((select count(*) from public.conversation_gallery(conv, 'photos')) = 1, 'gallery: photos');
  perform test.ok((select count(*) from public.conversation_gallery(conv, 'links')) = 1, 'gallery: links');
  perform test.ok((select count(*) from public.conversation_gallery(conv, 'all')) = 2, 'gallery: all');
  perform test.as_user(x);
  perform test.throws(format($q$select * from public.conversation_gallery(%L, 'all')$q$, conv), 'not_a_member',
                      'gallery closed to outsiders');
  perform test.ok((select count(*) from public.search_messages(null, null, null, null, false, null, conv)) = 0,
                  'search scoped to authorised content');
  perform test.as_user(v);
  perform test.ok((select object_path from public.authorize_media_access(img)) is not null, 'member can fetch chat media');
  perform test.throws(format('select public.authorize_media_access(%L)', mem), 'media_not_found', 'Memories are owner-only');
  perform test.ok((select count(*) from storage.objects where owner = u) = 0, 'cannot list others'' objects directly');
  perform test.as_user(x);
  perform test.throws(format('select public.authorize_media_access(%L)', img), 'media_not_found', 'stranger denied');

  -- Daily egress budget.
  perform test.as_superuser();
  update private.platform_config set daily_egress_budget_bytes = 1;
  perform test.as_user(v);
  perform test.throws(format('select public.authorize_media_access(%L)', img), 'egress_budget_exhausted',
                      'egress budget enforced');
  perform test.as_superuser();
  update private.platform_config set daily_egress_budget_bytes = 167772160;
end $$;

-- Rate limiting.
do $$
declare v uuid := (select id from public.profiles where username = 'viewer_50'); i integer;
begin
  perform test.as_user(v);
  for i in 1..30 loop perform public.search_users('uploader'); end loop;
  perform test.throws($q$select public.search_users('uploader')$q$, 'rate_limited', 'search rate limit (anti-enumeration)');
  perform test.as_superuser();
end $$;
