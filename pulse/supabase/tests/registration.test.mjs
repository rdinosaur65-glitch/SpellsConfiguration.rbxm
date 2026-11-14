// Invite-only registration (migration 0031) against the real Supabase Auth server of the
// local stack: every way of creating an account, attacked directly, without the app.
// Run: node --test supabase/tests/registration.test.mjs   (stack running; env as functions.test.mjs)
import { test } from 'node:test';
import assert from 'node:assert/strict';
import { execFileSync } from 'node:child_process';
import { createHash, randomBytes } from 'node:crypto';

const URL_ = process.env.SUPABASE_URL ?? process.env.API_URL ?? 'http://127.0.0.1:54321';
const ANON = process.env.ANON_KEY;
const SERVICE = process.env.SERVICE_ROLE_KEY;
const DB_URL = process.env.DB_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const MAILPIT = process.env.MAILPIT_URL ?? 'http://127.0.0.1:54324';
assert.ok(ANON && SERVICE, 'ANON_KEY and SERVICE_ROLE_KEY are required');

const sql = (q) => execFileSync('psql', [DB_URL, '-Atqc', q], { encoding: 'utf8' }).trim();
const tag = () => `r${Date.now().toString(36)}${Math.floor(Math.random() * 1e4)}`.slice(0, 16);
const newInvite = (valid = "interval '1 day'") =>
  sql(`insert into private.invitations (code, expires_at) values (private.new_invite_code(), now() + ${valid}) returning code`);
const usersWith = (email) => Number(sql(`select count(*) from auth.users where lower(email) = lower('${email}')`));

async function call(path, { method = 'POST', token, body, admin = false } = {}) {
  const key = admin ? SERVICE : ANON;
  const res = await fetch(`${URL_}${path}`, {
    method,
    headers: { apikey: key, Authorization: `Bearer ${token ?? key}`, 'Content-Type': 'application/json' },
    body: body === undefined ? undefined : JSON.stringify(body),
  });
  const text = await res.text();
  let data; try { data = text ? JSON.parse(text) : null; } catch { data = text; }
  return { status: res.status, data };
}
const signup = (email, data, extra = {}) =>
  call('/auth/v1/signup', { body: { email, password: 'pulse-test-123', data, ...extra } });

async function mail(to, subject) {
  for (let i = 0; i < 40; i++) {
    const list = await (await fetch(`${MAILPIT}/api/v1/search?query=${encodeURIComponent(`to:"${to}"`)}`)).json();
    const m = list.messages.find((x) => subject.test(x.Subject));
    if (m) return (await (await fetch(`${MAILPIT}/api/v1/message/${m.ID}`)).json());
    await new Promise((r) => setTimeout(r, 300));
  }
  return null;
}

test('direct Supabase Auth sign-ups need a valid, unused invitation', async () => {
  // No code, a made-up code, a blank code: refused by the database, no account left behind.
  for (const data of [{}, { invite_code: 'AAAA-BBBB-CCCC' }, { invite_code: '' }]) {
    const t = tag(); const email = `${t}@example.test`;
    const r = await signup(email, { username: t, ...data });
    assert.ok(r.status >= 400, `refused without a valid invitation: ${JSON.stringify(data)} → ${r.status}`);
    assert.equal(usersWith(email), 0, 'no account created');
  }

  // A valid code: account created, confirmation email sent, code redeemed and not stored.
  const code = newInvite();
  const t = tag(); const email = `${t}@example.test`;
  const ok = await signup(email, { username: t, invite_code: code.toLowerCase().replace(/(.{4})(.{4})/, '$1-$2-') });
  assert.equal(ok.status, 200, JSON.stringify(ok.data));
  const uid = ok.data.id ?? ok.data.user?.id;
  assert.equal(sql(`select redeemed_by from private.invitations where code = '${code}'`), uid, 'invitation redeemed by this account');
  assert.equal(sql(`select raw_user_meta_data ? 'invite_code' from auth.users where id = '${uid}'`), 'f', 'code not kept in metadata');
  const confirm = await mail(email, /verify your email/i);
  assert.ok(confirm, 'verification email still sent (Supabase Auth email confirmation unchanged)');
  const link = /href="([^"]+)"/.exec(confirm.HTML)?.[1]?.replace(/&amp;/g, '&') ?? '';
  const tokenHash = new URL(link).searchParams.get('token_hash');
  assert.ok(tokenHash, 'link carries the token hash');
  const before = await call('/auth/v1/token?grant_type=password', { body: { email, password: 'pulse-test-123' } });
  assert.equal(before.data?.error_code, 'email_not_confirmed', 'cannot sign in before confirming');
  const verified = await call('/auth/v1/verify', { body: { type: 'email', token_hash: tokenHash } });
  assert.equal(verified.status, 200, 'the emailed link confirms the account');
  const after = await call('/auth/v1/token?grant_type=password', { body: { email, password: 'pulse-test-123' } });
  assert.equal(after.status, 200, 'sign-in works after confirming');

  // The same code again (another address): refused.
  const t2 = tag();
  const again = await signup(`${t2}@example.test`, { username: t2, invite_code: code });
  assert.ok(again.status >= 400, 'a used invitation is refused');
  assert.equal(usersWith(`${t2}@example.test`), 0);

  // Expired and revoked codes: refused.
  const expired = newInvite("interval '1 second'");
  sql(`update private.invitations set expires_at = now() - interval '1 minute' where code = '${expired}'`);
  const revoked = newInvite();
  sql(`update private.invitations set revoked_at = now() where code = '${revoked}'`);
  for (const c of [expired, revoked]) {
    const t3 = tag();
    const r = await signup(`${t3}@example.test`, { username: t3, invite_code: c });
    assert.ok(r.status >= 400, `refused: ${c}`);
    assert.equal(usersWith(`${t3}@example.test`), 0);
  }
});

test('one invitation, many simultaneous sign-ups: exactly one account', async () => {
  const code = newInvite();
  const tries = Array.from({ length: 8 }, () => tag());
  const results = await Promise.all(tries.map((t, i) => signup(`${t}${i}@example.test`, { username: `${t}${i}`.slice(0, 20), invite_code: code })));
  const ok = results.filter((r) => r.status === 200);
  assert.equal(ok.length, 1, `exactly one succeeded: ${results.map((r) => r.status).join(',')}`);
  const created = tries.reduce((n, t, i) => n + usersWith(`${t}${i}@example.test`), 0);
  assert.equal(created, 1, 'exactly one account exists');
});

test('other ways into Supabase Auth are gated too', async () => {
  // Magic link / OTP with account creation.
  const t = tag();
  const otp = await call('/auth/v1/otp', { body: { email: `${t}@example.test`, create_user: true, data: { username: t } } });
  assert.ok(otp.status >= 400, `OTP sign-up without an invitation refused (${otp.status})`);
  assert.equal(usersWith(`${t}@example.test`), 0);

  // Anonymous sign-in is off.
  const anon = await call('/auth/v1/signup', { body: {} });
  assert.ok(anon.status >= 400, 'anonymous sign-in refused');

  // Even the service role (admin API, invite API) needs an invitation.
  const t2 = tag();
  const admin = await call('/auth/v1/admin/users', { admin: true, body: { email: `${t2}@example.test`, password: 'pulse-test-123', email_confirm: true, user_metadata: { username: t2 } } });
  assert.ok(admin.status >= 400, `admin-created account without an invitation refused (${admin.status})`);
  const t3 = tag();
  const inv = await call('/auth/v1/invite', { admin: true, body: { email: `${t3}@example.test`, data: { username: t3 } } });
  assert.ok(inv.status >= 400, `Supabase invite without a PULSE invitation refused (${inv.status})`);
  assert.equal(usersWith(`${t2}@example.test`) + usersWith(`${t3}@example.test`), 0);

  // Checking a code is open to signed-out visitors and never consumes it.
  const code = newInvite();
  const st = await call('/rest/v1/rpc/registration_status', { body: { p_code: code } });
  assert.equal(st.status, 200);
  assert.equal(st.data.mode, 'invite_only');
  assert.equal(st.data.invite, 'pending');
  assert.equal(sql(`select redeemed_at is null from private.invitations where code = '${code}'`), 't', 'not consumed by checking');
  // The owner functions and the table are not reachable without the owner's session.
  const list = await call('/rest/v1/rpc/admin_list_invitations', { body: {} });
  assert.ok(list.status >= 400, 'anon cannot list invitations');
  const table = await call('/rest/v1/invitations?select=*');
  assert.ok(table.status >= 400, 'the invitations table is not exposed');
});

test('the first owner: one-time token set with database access, configured address, confirmed inbox', async () => {
  const savedOwner = sql('select coalesce(owner_user_id::text, \'\') from private.platform_config');
  const t = tag(); const email = `${t}@example.test`;
  const token = randomBytes(32).toString('hex');
  sql(`update private.platform_config set owner_user_id = null, owner_bootstrap_email = '${email}',
       owner_bootstrap_hash = '${createHash('sha256').update(token).digest('hex')}'`);
  try {
    // Without the token, the owner's address alone gets nowhere (app_metadata is ignored too).
    const pub = await signup(email, { username: t }, { app_metadata: { pulse_owner_bootstrap: true } });
    assert.ok(pub.status >= 400, `sign-up for the owner address without the token refused (${pub.status})`);
    const wrong = await signup(email, { username: t, owner_bootstrap_token: 'guess' });
    assert.ok(wrong.status >= 400, 'wrong token refused');
    assert.equal(usersWith(email), 0);

    // With the token (as scripts/bootstrap-owner.mjs does): account without an invitation.
    const created = await call('/auth/v1/admin/users', { admin: true, body: {
      email, email_confirm: false, user_metadata: { username: t, owner_bootstrap_token: token } } });
    assert.equal(created.status, 200, JSON.stringify(created.data));
    assert.equal(sql(`select raw_user_meta_data ? 'owner_bootstrap_token' from auth.users where id = '${created.data.id}'`), 'f', 'token not kept');
    assert.equal(sql('select coalesce(owner_user_id::text, \'\') from private.platform_config'), '', 'not owner before confirming');
    // Confirming the address (the emailed set-password link) makes it the owner.
    const link = await call('/auth/v1/admin/generate_link', { admin: true, body: { type: 'recovery', email } });
    const v = await call('/auth/v1/verify', { body: { type: 'recovery', token_hash: link.data.hashed_token } });
    assert.equal(v.status, 200);
    assert.equal(sql('select owner_user_id::text from private.platform_config'), created.data.id, 'owner once the address is confirmed');

    // The token cannot be used again.
    const t2 = tag();
    sql(`update private.platform_config set owner_bootstrap_email = '${t2}@example.test'`);
    const again = await signup(`${t2}@example.test`, { username: t2, owner_bootstrap_token: token });
    assert.ok(again.status >= 400, 'token used up; no second owner');
  } finally {
    sql(`update private.platform_config set owner_bootstrap_email = null, owner_bootstrap_hash = null, owner_bootstrap_user = null,
         owner_user_id = ${savedOwner ? `'${savedOwner}'` : 'null'}`);
  }
});
