// Integration test for the media Edge Functions against a running local Supabase stack
// (`npm run sb:start`, functions served). Real uploads through the Storage API, real
// signed URLs, real deletions. Run: node --test supabase/tests/functions.test.mjs
// Env: SUPABASE_URL, ANON_KEY, SERVICE_ROLE_KEY, DB_URL (from `supabase status -o env`),
// JANITOR_SECRET (defaults to supabase/functions/.env).
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { createHash, randomUUID } from 'node:crypto';
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

const mediaUrl = (token, body) => call('/functions/v1/media-url', { token, body });
async function fetchSigned(path) {
  const res = await fetch(`${URL_}${path}`);
  return { status: res.status, bytes: Buffer.from(await res.arrayBuffer()) };
}

test('media-url signs short URLs only for people allowed to see the media', async () => {
  const a = await newUser('mua'), b = await newUser('mub'), x = await newUser('mux');
  await befriend(a, b);
  const pic = await upload(a, 'chat');
  const conv = await rpc(a.token, 'create_direct_conversation', { p_friend: b.id });
  await rpc(a.token, 'set_chat_expiry', { p_conv: conv, p_mode: 'never' });
  await rpc(a.token, 'send_message', { p_conv: conv, p_kind: 'photo', p_body: null, p_client_msg_id: randomUUID(), p_media_asset: pic.asset });

  const ok = await mediaUrl(b.token, { asset_id: pic.asset });
  assert.equal(ok.status, 200, JSON.stringify(ok.data));
  assert.ok(ok.data.expires_in <= 60 && ok.data.expires_in >= 1, 'URL lives at most 60 s');
  assert.equal(ok.data.mime_type, 'image/jpeg');
  const got = await fetchSigned(ok.data.path);
  assert.equal(got.status, 200);
  assert.ok(got.bytes.equals(pic.bytes), 'signed URL serves the uploaded bytes');

  assert.equal((await mediaUrl(a.token, { asset_id: pic.asset })).status, 200, 'owner downloads via media-url too');
  assert.equal((await mediaUrl(x.token, { asset_id: pic.asset })).status, 404, 'stranger refused');
  assert.equal((await mediaUrl(undefined, { asset_id: pic.asset })).status, 401, 'no JWT refused at the gateway');
  assert.equal((await mediaUrl(b.token, { asset_id: 'nope' })).status, 400, 'malformed id');
  // No direct path around the function: the bucket is private and has no read policy.
  assert.notEqual((await call(`/storage/v1/object/media/${pic.path}`, { method: 'GET', token: b.token })).status, 200);
  assert.notEqual((await call(`/storage/v1/object/media/${pic.path}`, { method: 'GET', token: a.token })).status, 200);
  assert.notEqual((await call(`/storage/v1/object/sign/media/${pic.path}`, { token: a.token, body: { expiresIn: 31536000 } })).status, 200,
    'owners cannot mint long-lived URLs');
});

test('Snap media is reachable only during a live viewing session', async () => {
  const a = await newUser('sna'), b = await newUser('snb');
  await befriend(a, b);
  const img = await upload(a, 'snap');
  const snap = await rpc(a.token, 'send_snap', { p_media_asset: img.asset, p_recipients: [b.id], p_groups: null,
    p_view_seconds: 3, p_allow_saving: false, p_client_id: randomUUID() });
  assert.equal((await mediaUrl(b.token, { snap_id: snap, session_id: randomUUID() })).status, 403, 'no session, no media');
  const [view] = await rpc(b.token, 'open_snap', { p_snap: snap });
  const ok = await mediaUrl(b.token, { snap_id: snap, session_id: view.session_id });
  assert.equal(ok.status, 200, JSON.stringify(ok.data));
  assert.ok(ok.data.expires_in <= 5, 'URL never outlives the 3 s (+grace) session');
  assert.ok((await fetchSigned(ok.data.path)).bytes.equals(img.bytes));
  await rpc(b.token, 'close_snap_view', { p_snap: snap, p_session: view.session_id });
  assert.equal((await mediaUrl(b.token, { snap_id: snap, session_id: view.session_id })).status, 403, 'closed session refused');
  assert.equal((await mediaUrl(a.token, { snap_id: snap, session_id: view.session_id })).status, 403, 'sender has no session');
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
