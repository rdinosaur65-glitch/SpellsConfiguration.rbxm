-- Snaps: delivery rules, server-enforced sessions, one replay, timers, unlimited
-- viewing, saving permission, media authorisation, expiry and media release.
do $$
declare s_ uuid; r_ uuid; x uuid; asset uuid; snap uuid; sess uuid; st public.snap_status; o record;
begin
  s_ := test.new_user('sender_40'); r_ := test.new_user('recip_40'); x := test.new_user('outsider_40');
  perform test.befriend(s_, r_);
  asset := test.upload(s_, 'snap', 'image/webp', 200000);

  perform test.as_user(s_);
  perform test.throws(format($q$select public.send_snap(%L, array[%L]::uuid[], null, 5::smallint, false, gen_random_uuid())$q$, asset, x),
                      'not_friends', 'snaps only to friends');
  perform test.throws(format($q$select public.send_snap(%L, array[%L]::uuid[], null, 11::smallint, false, gen_random_uuid())$q$, asset, r_),
                      'invalid_view_seconds', 'timer max 10 s');
  perform test.throws(format($q$select public.send_snap(%L, array[%L]::uuid[], null, 0::smallint, false, gen_random_uuid())$q$, asset, r_),
                      'invalid_view_seconds', 'timer min 1 s');
  snap := public.send_snap(asset, array[r_], null, 5::smallint, false, gen_random_uuid());

  -- Outsider sees nothing and cannot open.
  perform test.as_user(x);
  perform test.ok((select count(*) from public.snaps where id = snap) = 0, 'outsider cannot see snap');
  perform test.throws(format('select public.open_snap(%L)', snap), 'snap_not_found', 'outsider cannot open');

  -- Recipient: label, no media path.
  perform test.as_user(r_);
  perform test.ok((select label from public.chat_list() where other_user_id = s_) = 'New Snap', 'New Snap label');
  perform test.throws(format('select media_asset_id from public.snaps where id = %L', snap), 'sqlstate:42501',
                      'recipient cannot read media reference');

  -- First view.
  select * into o from public.open_snap(snap);
  sess := o.session_id;
  perform test.ok(o.view_number = 1 and not o.unlimited, 'first view');
  perform test.ok(o.deadline <= now() + interval '8 seconds', 'deadline bounded by timer');
  perform test.throws(format('select public.open_snap(%L)', snap), 'session_active', 'no parallel second session');
  perform test.ok((select object_path from public.authorize_snap_media(snap, sess)) is not null, 'media during session');
  perform test.throws(format('select public.authorize_snap_media(%L, %L)', snap, gen_random_uuid()),
                      'snap_session_invalid', 'wrong session id rejected');
  perform test.throws(format('select public.save_snap(%L, %L)', snap, sess), 'saving_not_permitted', 'saving off by default');
  st := public.close_snap_view(snap, sess);
  perform test.ok(st = 'opened', 'opened after first view');
  perform test.throws(format('select public.authorize_snap_media(%L, %L)', snap, sess), 'snap_session_invalid',
                      'no media after session closed');

  -- Replay (same timer), then expiry.
  select * into o from public.open_snap(snap);
  perform test.ok(o.view_number = 2 and o.view_seconds = 5, 'replay uses same timer');
  perform public.authorize_snap_media(snap, o.session_id);   -- the replay is actually shown
  -- Timer elapses on the server even if the client never closes.
  perform test.as_superuser();
  update public.snap_recipients set session_deadline = now() - interval '1 second' where snap_id = snap;
  perform test.as_user(r_);
  perform test.throws(format('select public.authorize_snap_media(%L, %L)', snap, o.session_id), 'snap_session_invalid',
                      'server-side timer enforced');
  perform test.throws(format('select public.open_snap(%L)', snap), 'snap_expired', 'no third view');
  perform test.ok(public.close_snap_view(snap, o.session_id) = 'expired', 'expired after replay');

  -- Sender sees status; the chat list reflects it.
  perform test.as_user(s_);
  perform test.ok((select status from public.snap_recipients where snap_id = snap) = 'expired', 'sender sees expired');
  perform test.ok((select label from public.chat_list() where other_user_id = r_) = 'Opened', 'sender sees Opened');

  -- Maintenance releases the media once nobody can view it.
  perform test.as_superuser();
  perform private.run_maintenance();
  perform test.ok((select status from public.media_assets where id = asset) = 'deleting', 'snap media queued for deletion');
end $$;

-- Unlimited viewing, saving permission, video timer, group snaps, idempotency.
do $$
declare s_ uuid := (select id from public.profiles where username = 'sender_40');
        r_ uuid := (select id from public.profiles where username = 'recip_40');
        m uuid; asset uuid; vid uuid; snap uuid; g uuid; o record; cid uuid := gen_random_uuid();
begin
  m := test.new_user('member_40');
  perform test.befriend(s_, m);
  asset := test.upload(s_, 'snap', 'image/jpeg', 150000);
  perform test.as_user(s_);
  snap := public.send_snap(asset, array[r_], null, null, true, cid);
  perform test.ok(public.send_snap(asset, array[r_], null, null, true, cid) = snap, 'send_snap idempotent');

  perform test.as_user(r_);
  select * into o from public.open_snap(snap);
  perform test.ok(o.unlimited, 'unlimited session');
  perform test.ok(o.deadline <= now() + interval '15 minutes' + interval '1 second', 'unlimited is bounded by safety cap');
  perform public.save_snap(snap, o.session_id);
  perform test.ok((select saved_at is not null from public.snap_recipients where snap_id = snap and recipient_id = r_),
                  'saved with sender permission');
  perform public.close_snap_view(snap, o.session_id);
  perform test.throws(format('select public.save_snap(%L, %L)', snap, o.session_id), 'snap_session_invalid',
                      'cannot save outside a viewing session');

  -- Video: plays for its own duration (max 60 s enforced at upload).
  vid := test.upload(s_, 'snap', 'video/mp4', 5000000, 12.5);
  perform test.as_user(s_);
  perform test.throws($q$select public.authorize_upload('snap', 'video/mp4', 1000, repeat('a', 64), 61)$q$,
                      'media_too_long', '60 s snap limit');
  g := public.create_group('Snap group', array[r_, m]);
  snap := public.send_snap(vid, null, array[g], 3::smallint, false, gen_random_uuid());
  perform test.ok((select count(*) from public.snap_recipients where snap_id = snap) = 2, 'group snap fans out to members');
  perform test.as_user(m);
  select * into o from public.open_snap(snap);
  perform test.ok(o.deadline > now() + interval '12 seconds' and o.view_seconds is null, 'video uses its duration');
  perform test.as_superuser();
end $$;
