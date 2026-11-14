// Integration test for the media Edge Functions against a running local Supabase stack
// (`npm run sb:start`, functions served). Real uploads through the Storage API, real
// signed URLs, real deletions. Run: node --test supabase/tests/functions.test.mjs
// Env: SUPABASE_URL, ANON_KEY, SERVICE_ROLE_KEY, DB_URL (from `supabase status -o env`),
// JANITOR_SECRET (defaults to supabase/functions/.env).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, createHmac, randomUUID } from 'node:crypto';
import { execFileSync } from 'node:child_process';
import { readFileSync, existsSync } from 'node:fs';
import { join } from 'node:path';

const URL_ = process.env.SUPABASE_URL ?? process.env.API_URL ?? 'http://127.0.0.1:54321';
const ANON = process.env.ANON_KEY;
const SERVICE = process.env.SERVICE_ROLE_KEY;
const DB_URL = process.env.DB_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const envFile = join(import.meta.dirname, '../functions/.env');
const JANITOR_SECRET = process.env.JANITOR_SECRET
  ?? (existsSync(envFile) ? /JANITOR_SECRET=(.+)/.exec(readFileSync(envFile, 'utf8'))?.[1]?.trim() : undefined);
assert.ok(ANON && SERVICE, 'ANON_KEY and SERVICE_ROLE_KEY are required');
assert.ok(JANITOR_SECRET, 'JANITOR_SECRET is required (supabase/functions/.env)');

const sql = (q) => execFileSync('psql', [DB_URL, '-Atqc', q], { encoding: 'utf8' }).trim();

async function call(path, { method = 'POST', token, body, headers = {}, raw = false } = {}) {
  const res = await fetch(`${URL_}${path}`, {
    method,
    headers: { apikey: ANON, ...(token ? { Authorization: `Bearer ${token}` } : {}),
               ...(raw ? {} : { 'Content-Type': 'application/json' }), ...headers },
    body: raw ? body : body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let data; try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  return { status: res.status, data };
}
const rpc = async (token, fn, args) => {
  const r = await call(`/rest/v1/rpc/${fn}`, { token, body: args });
  assert.ok(r.status < 300, `${fn}: ${r.status} ${JSON.stringify(r.data)}`);
  return r.data;
};

async function newUser(tag) {
  const username = `${tag}${Date.now().toString(36)}${Math.floor(Math.random() * 1e3)}`.slice(0, 20);
  const email = `${username}@example.test`;
  const created = await call('/auth/v1/admin/users', {
    token: SERVICE, headers: { apikey: SERVICE },
    body: { email, password: 'pulse-test-123', email_confirm: true, user_metadata: { username } },
  });
  assert.equal(created.status, 200, JSON.stringify(created.data));
  const s = await call('/auth/v1/token?grant_type=password', { body: { email, password: 'pulse-test-123' } });
  assert.equal(s.status, 200, JSON.stringify(s.data));
  return { id: created.data.id, token: s.data.access_token };
}

/** RFC 6238 TOTP (SHA-1, 30 s, 6 digits) from a base32 secret. */
function totp(secretB32, at = Date.now()) {
  const alphabet = 'ABCDEFGHIJKLMNOPQRSTUVWXYZ234567';
  let bits = '';
  for (const ch of secretB32.replace(/=+$/, '').toUpperCase()) {
    const v = alphabet.indexOf(ch);
    if (v >= 0) bits += v.toString(2).padStart(5, '0');
  }
  const key = Buffer.from((bits.match(/.{8}/g) ?? []).map((b) => parseInt(b, 2)));
  const counter = Buffer.alloc(8);
  counter.writeBigUInt64BE(BigInt(Math.floor(at / 1000 / 30)));
  const h = createHmac('sha1', key).update(counter).digest();
  const off = h[h.length - 1] & 0xf;
  return ((h.readUInt32BE(off) & 0x7fffffff) % 1_000_000).toString().padStart(6, '0');
}

/** Turns on TOTP for the user through GoTrue and returns an aal2 access token. */
async function withTotp(user) {
  const f = await call('/auth/v1/factors', { token: user.token, body: { factor_type: 'totp', friendly_name: 'test' } });
  assert.equal(f.status, 200, JSON.stringify(f.data));
  const ch = await call(`/auth/v1/factors/${f.data.id}/challenge`, { token: user.token, body: {} });
  assert.equal(ch.status, 200, JSON.stringify(ch.data));
  const v = await call(`/auth/v1/factors/${f.data.id}/verify`, {
    token: user.token, body: { challenge_id: ch.data.id, code: totp(f.data.totp.secret) } });
  assert.equal(v.status, 200, JSON.stringify(v.data));
  return { ...user, aal1: user.token, token: v.data.access_token };
}

async function befriend(a, b) {
  const req = await rpc(a.token, 'send_friend_request', { p_target: b.id });
  await rpc(b.token, 'respond_friend_request', { p_request: req, p_accept: true });
}

/** Reserve, upload through the Storage API, confirm. Returns { asset, bytes }. */
async function upload(user, purpose, size = 2048) {
  const bytes = Buffer.alloc(size, 7);
  bytes.write(randomUUID());                             // unique content (no dedupe)
  const sha = createHash('sha256').update(bytes).digest('hex');
  const [r] = await rpc(user.token, 'authorize_upload', { p_purpose: purpose, p_mime: 'image/jpeg', p_bytes: size, p_sha256: sha });
  const up = await call(`/storage/v1/object/media/${r.object_path}`, {
    token: user.token, raw: true, body: bytes, headers: { 'Content-Type': 'image/jpeg' },
  });
  assert.equal(up.status, 200, `upload: ${JSON.stringify(up.data)}`);
  assert.equal(await rpc(user.token, 'confirm_upload', { p_asset: r.asset_id }), true);
  return { asset: r.asset_id, path: r.object_path, bytes };
}

/** One authorised download through media-url (bytes streamed by the function). */
async function download(token, body) {
  const res = await fetch(`${URL_}/functions/v1/media-url`, {
    method: 'POST',
    headers: { apikey: ANON, 'Content-Type': 'application/json', ...(token ? { Authorization: `Bearer ${token}` } : {}) },
    body: JSON.stringify(body),
  });
  const bytes = Buffer.from(await res.arrayBuffer());
  return { status: res.status, bytes, type: res.headers.get('content-type'), cache: res.headers.get('cache-control') ?? '' };
}
const egressOf = (id) => Number(sql(`select coalesce((select egress_bytes from private.usage_daily
  where user_id = '${id}' and day = (now() at time zone 'utc')::date), 0)`));

test('media-url streams one copy per authorisation, only to people allowed to see it', async () => {
  const a = await newUser('mua'), b = await newUser('mub'), x = await newUser('mux');
  await befriend(a, b);
  const pic = await upload(a, 'chat');
  const conv = await rpc(a.token, 'create_direct_conversation', { p_friend: b.id });
  await rpc(a.token, 'set_chat_expiry', { p_conv: conv, p_mode: 'never' });
  await rpc(a.token, 'send_message', { p_conv: conv, p_kind: 'photo', p_body: null, p_client_msg_id: randomUUID(), p_media_asset: pic.asset });

  const before = egressOf(b.id);
  const got = await download(b.token, { asset_id: pic.asset });
  assert.equal(got.status, 200);
  assert.ok(got.bytes.equals(pic.bytes), 'the uploaded bytes');
  assert.equal(got.type, 'image/jpeg');
  assert.match(got.cache, /no-store/, 'never kept in a browser or proxy cache');
  await download(b.token, { asset_id: pic.asset });
  assert.equal(egressOf(b.id) - before, 2 * pic.bytes.length, 'every download is charged (no free re-fetch)');

  assert.equal((await download(a.token, { asset_id: pic.asset })).status, 200, 'owner downloads via media-url too');
  assert.equal((await download(x.token, { asset_id: pic.asset })).status, 404, 'stranger refused');
  assert.equal((await download(undefined, { asset_id: pic.asset })).status, 401, 'no JWT refused at the gateway');
  assert.equal((await download(b.token, { asset_id: 'nope' })).status, 400, 'malformed id');
  // No path around the function: the bucket is private and has no read policy.
  assert.notEqual((await call(`/storage/v1/object/media/${pic.path}`, { method: 'GET', token: b.token })).status, 200);
  assert.notEqual((await call(`/storage/v1/object/media/${pic.path}`, { method: 'GET', token: a.token })).status, 200);
  assert.notEqual((await call(`/storage/v1/object/sign/media/${pic.path}`, { token: a.token, body: { expiresIn: 31536000 } })).status, 200,
    'nobody can mint a signed URL');
});

test('Snap bytes only during a live viewing session, only for current members', async () => {
  const a = await newUser('sna'), b = await newUser('snb'), c = await newUser('snc');
  await befriend(a, b); await befriend(a, c);
  const img = await upload(a, 'snap');
  const snap = await rpc(a.token, 'send_snap', { p_media_asset: img.asset, p_recipients: [b.id], p_groups: null,
    p_view_seconds: 3, p_allow_saving: false, p_client_id: randomUUID() });
  assert.equal((await download(b.token, { snap_id: snap, session_id: randomUUID() })).status, 403, 'no session, no bytes');
  const [view] = await rpc(b.token, 'open_snap', { p_snap: snap });
  const ok = await download(b.token, { snap_id: snap, session_id: view.session_id });
  assert.equal(ok.status, 200);
  assert.ok(ok.bytes.equals(img.bytes));
  assert.match(ok.cache, /no-store/);
  await rpc(b.token, 'close_snap_view', { p_snap: snap, p_session: view.session_id });
  assert.equal((await download(b.token, { snap_id: snap, session_id: view.session_id })).status, 403, 'closed session refused');
  assert.equal((await download(a.token, { snap_id: snap, session_id: view.session_id })).status, 403, 'sender has no session');

  // A group Snap: a member removed afterwards cannot open it or get its bytes.
  const g = await rpc(a.token, 'create_group', { p_name: 'snaps', p_members: [b.id, c.id] });
  const img2 = await upload(a, 'snap');
  const gsnap = await rpc(a.token, 'send_snap', { p_media_asset: img2.asset, p_recipients: null, p_groups: [g],
    p_view_seconds: 3, p_allow_saving: false, p_client_id: randomUUID() });
  await rpc(a.token, 'remove_group_member', { p_conv: g, p_user: c.id });
  const denied = await call('/rest/v1/rpc/open_snap', { token: c.token, body: { p_snap: gsnap } });
  assert.notEqual(denied.status, 200, 'removed member cannot open the group Snap');
});

test('storage-janitor removes released objects (direct call and via pg_cron/pg_net)', async () => {
  const a = await newUser('jna'), b = await newUser('jnb');
  await befriend(a, b);
  const pic = await upload(a, 'chat');
  const conv = await rpc(a.token, 'create_direct_conversation', { p_friend: b.id });
  const msg = await rpc(a.token, 'send_message', { p_conv: conv, p_kind: 'photo', p_body: null, p_client_msg_id: randomUUID(), p_media_asset: pic.asset });
  await rpc(a.token, 'delete_message', { p_msg: msg });
  assert.equal(sql(`select status from public.media_assets where id = '${pic.asset}'`), 'deleting');

  const denied = await call('/functions/v1/storage-janitor', { headers: { 'x-janitor-secret': 'wrong' }, body: {} });
  assert.equal(denied.status, 401, 'wrong secret refused');
  const run = await call('/functions/v1/storage-janitor', { headers: { 'x-janitor-secret': JANITOR_SECRET }, body: {} });
  assert.equal(run.status, 200, JSON.stringify(run.data));
  assert.ok(run.data.removed >= 1, 'removed at least the released photo');
  assert.equal(sql(`select status from public.media_assets where id = '${pic.asset}'`), 'deleted');
  assert.equal(sql(`select count(*) from storage.objects where bucket_id = 'media' and name = '${pic.path}'`), '0', 'object gone');

  // Scheduled path: pg_cron → private.invoke_storage_janitor() → pg_net → function.
  const pic2 = await upload(a, 'chat');
  await rpc(a.token, 'delete_media_asset', { p_asset: pic2.asset });
  sql(`delete from vault.secrets where name in ('pulse_janitor_url', 'pulse_janitor_secret')`);
  sql(`select vault.create_secret('http://kong:8000/functions/v1/storage-janitor', 'pulse_janitor_url')`);
  sql(`select vault.create_secret('${JANITOR_SECRET}', 'pulse_janitor_secret')`);
  const reqId = sql('select private.invoke_storage_janitor()');
  assert.match(reqId, /^\d+$/, 'pg_net request queued');
  let status = '';
  for (let i = 0; i < 60 && !status; i++) {
    await new Promise((r) => setTimeout(r, 500));
    status = sql(`select status_code from net._http_response where id = ${reqId}`);
  }
  assert.equal(status, '200', 'function answered the scheduled call');
  assert.equal(sql(`select status from public.media_assets where id = '${pic2.asset}'`), 'deleted');
  if (sql(`select count(*) from public.media_assets where status = 'deleting'`) === '0'
      && sql('select count(*) from private.storage_trash') === '0') {
    assert.equal(sql('select private.invoke_storage_janitor() is null'), 't', 'no call when there is nothing to delete');
  }
});

// ---------------------------------------------------------------------------
// Owner-verified 2FA reset (owner-mfa-reset + migration 0021), with real email.
// ---------------------------------------------------------------------------
const MAILPIT = process.env.MAILPIT_URL ?? 'http://127.0.0.1:54324';
async function mailTo(address, subject, { after = 0 } = {}) {
  for (let i = 0; i < 40; i++) {
    const list = await (await fetch(`${MAILPIT}/api/v1/search?query=${encodeURIComponent(`to:"${address}"`)}`)).json();
    const m = list.messages.find((x) => subject.test(x.Subject) && new Date(x.Created).getTime() >= after);
    if (m) return (await (await fetch(`${MAILPIT}/api/v1/message/${m.ID}`)).json());
    await new Promise((r) => setTimeout(r, 300));
  }
  return null;
}
const resetFn = (token, body) => call('/functions/v1/owner-mfa-reset', { token, body });
const emailOf = (id) => sql(`select email from auth.users where id = '${id}'`);

test('2FA reset of another account needs the code emailed to the owner', async () => {
  const target = await newUser('mft'), other = await newUser('mfx');
  let owner = await newUser('mfo');
  sql(`update private.platform_config set owner_user_id = '${owner.id}'`);
  try {
    // Owner powers need the owner's own 2FA (an aal2 session).
    const noMfa = await resetFn(owner.token, { action: 'request', target_id: target.id, reason: 'x' });
    assert.equal(noMfa.status, 403);
    assert.equal(noMfa.data.error, 'owner_mfa_required');
    owner = await withTotp(owner);
    const aal1 = await resetFn(owner.aal1, { action: 'request', target_id: target.id, reason: 'x' });
    assert.equal(aal1.status, 401, 'a password-only session of a 2FA owner is refused');

    sql(`insert into auth.mfa_factors (id, user_id, friendly_name, factor_type, status, created_at, updated_at)
         values (gen_random_uuid(), '${target.id}', 'phone', 'totp', 'verified', now(), now())`);
    const started = Date.now() - 1000;

    // Only the owner, never another user.
    assert.equal((await resetFn(other.token, { action: 'request', target_id: target.id, reason: 'x' })).status, 403);
    assert.equal((await resetFn(undefined, { action: 'request', target_id: target.id, reason: 'x' })).status, 401);

    const req = await resetFn(owner.token, { action: 'request', target_id: target.id, reason: 'lost phone' });
    assert.equal(req.status, 200, JSON.stringify(req.data));
    assert.equal(Object.keys(req.data).sort().join(','), 'expires_in,request_id', 'no code or address in the response');
    const mail = await mailTo(emailOf(owner.id), /confirm a two-step verification reset/i, { after: started });
    assert.ok(mail, 'code emailed to the owner');
    assert.equal(await mailTo(emailOf(target.id), /confirm a two-step/i, { after: started }), null, 'never to the target');
    const code = /Confirmation code: (\d{6})/.exec(mail.Text)?.[1];
    assert.match(code ?? '', /^\d{6}$/);

    // Wrong code, then the right one; replay refused; target reset and signed out.
    const wrong = await resetFn(owner.token, { action: 'confirm', request_id: req.data.request_id, code: code === '000000' ? '111111' : '000000' });
    assert.equal(wrong.data.status, 'incorrect');
    assert.equal(wrong.data.attempts_left, 4);
    assert.equal(sql(`select count(*) from auth.mfa_factors where user_id = '${target.id}'`), '1', 'unchanged until verified');
    const ok = await resetFn(owner.token, { action: 'confirm', request_id: req.data.request_id, code });
    assert.equal(ok.status, 200, JSON.stringify(ok.data));
    assert.equal(ok.data.status, 'completed');
    assert.equal(ok.data.notified, true);
    assert.equal(sql(`select count(*) from auth.mfa_factors where user_id = '${target.id}'`), '0', 'target 2FA removed');
    assert.equal(sql(`select count(*) from auth.sessions where user_id = '${target.id}'`), '0', 'target signed out');
    const replay = await resetFn(owner.token, { action: 'confirm', request_id: req.data.request_id, code });
    assert.equal(replay.data.status, 'used', 'a code works once');

    // The affected user is told, without the owner's address.
    const notice = await mailTo(emailOf(target.id), /two-step verification was reset/i, { after: started });
    assert.ok(notice, 'target notified');
    assert.ok(!notice.Text.includes(emailOf(owner.id)) && !JSON.stringify(notice.From).includes(emailOf(owner.id)),
      'notice does not reveal the owner email');
    assert.equal(sql(`select count(*) from private.audit_log where target_user_id = '${target.id}' and action in
      ('account.mfa_reset.requested','account.mfa_reset.code_sent','account.mfa_reset.code_incorrect',
       'account.mfa_reset.verified','account.mfa_reset.completed','account.mfa_reset.user_notified')`), '6', 'fully audited');

    // Email delivery failure: no code, no reset, no bypass.
    sql(`insert into auth.mfa_factors (id, user_id, friendly_name, factor_type, status, created_at, updated_at)
         values (gen_random_uuid(), '${other.id}', 'phone', 'totp', 'verified', now(), now())`);
    execFileSync('docker', ['stop', 'supabase_inbucket_pulse'], { stdio: 'ignore' });
    let failed;
    try { failed = await resetFn(owner.token, { action: 'request', target_id: other.id, reason: 'smtp down' }); }
    finally { execFileSync('docker', ['start', 'supabase_inbucket_pulse'], { stdio: 'ignore' }); }
    assert.equal(failed.status, 502);
    assert.equal(failed.data.error, 'email_failed');
    assert.equal(sql(`select status from private.mfa_reset_requests where target_id = '${other.id}' order by created_at desc limit 1`), 'failed');
    const reqId = sql(`select id from private.mfa_reset_requests where target_id = '${other.id}' order by created_at desc limit 1`);
    for (const guess of ['000000', '123456']) {
      const r = await resetFn(owner.token, { action: 'confirm', request_id: reqId, code: guess });
      assert.equal(r.data.status, 'failed');
    }
    assert.equal(sql(`select count(*) from auth.mfa_factors where user_id = '${other.id}'`), '1', 'nothing reset after a delivery failure');

    // Mail sent from the owner's own mailbox would reveal the owner to the affected user:
    // refused before anything is sent. (The local functions .env sends from no-reply@pulse.local.)
    const ownerEmail = emailOf(owner.id);
    const sender = 'no-reply@pulse.local';
    sql(`update auth.users set email = '${sender}' where id = '${owner.id}'`);
    let same;
    const t0 = Date.now() - 1000;
    try { same = await resetFn(owner.token, { action: 'request', target_id: other.id, reason: 'sender check' }); }
    finally { sql(`update auth.users set email = '${ownerEmail}' where id = '${owner.id}'`); }
    assert.equal(same.status, 409, JSON.stringify(same.data));
    assert.equal(same.data.error, 'smtp_sender_is_owner');
    assert.equal(sql(`select status from private.mfa_reset_requests where target_id = '${other.id}' order by created_at desc limit 1`), 'failed');
    assert.equal(await mailTo(sender, /confirm a two-step/i, { after: t0 }), null, 'no code sent');
    assert.equal(sql(`select count(*) from auth.mfa_factors where user_id = '${other.id}'`), '1', 'nothing reset');
  } finally {
    sql('update private.platform_config set owner_user_id = null');
  }
});
