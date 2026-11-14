import { execFileSync } from 'node:child_process';
import { createDecipheriv, createECDH, hkdfSync, randomBytes, randomUUID } from 'node:crypto';
import { readFileSync } from 'node:fs';
import http from 'node:http';
import { join } from 'node:path';
import { expect, test, type Page } from '@playwright/test';
import { befriendUi, openPeople, signUp, uniq } from './helpers';

const DB_URL = process.env.DB_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const sql = (q: string) => execFileSync('psql', [DB_URL, '-Atqc', q], { encoding: 'utf8' }).trim();
const nav = (p: Page, name: string) => p.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: new RegExp(`^${name}`) });
const fnEnv = readFileSync(join(import.meta.dirname, '../../../supabase/functions/.env'), 'utf8');
const prefix = /^PULSE_PUSH_TEST_PREFIXES=(.+)$/m.exec(fnEnv)?.[1]?.trim() ?? '';

// Notifications need the full Chromium build (the default headless shell denies them).
test.use({ channel: 'chromium' });

function decrypt(body: Buffer, ecdh: ReturnType<typeof createECDH>, auth: Buffer): string {
  const salt = body.subarray(0, 16), idlen = body[20]!, asPub = body.subarray(21, 21 + idlen), ct = body.subarray(21 + idlen);
  const ikm = Buffer.from(hkdfSync('sha256', ecdh.computeSecret(asPub), auth,
    Buffer.concat([Buffer.from('WebPush: info\0'), ecdh.getPublicKey(), asPub]), 32));
  const cek = Buffer.from(hkdfSync('sha256', ikm, salt, Buffer.from('Content-Encoding: aes128gcm\0'), 16));
  const nonce = Buffer.from(hkdfSync('sha256', ikm, salt, Buffer.from('Content-Encoding: nonce\0'), 12));
  const d = createDecipheriv('aes-128-gcm', cek, nonce);
  d.setAuthTag(ct.subarray(ct.length - 16));
  const pt = Buffer.concat([d.update(ct.subarray(0, ct.length - 16)), d.final()]);
  return pt.subarray(0, pt.length - 1).toString('utf8');
}

test('push notifications: turn on, receive "New Chat" without the text, turn off', async ({ browser }) => {
  test.setTimeout(180_000);
  expect(prefix, 'PULSE_PUSH_TEST_PREFIXES in supabase/functions/.env').toMatch(/^http:\/\//);
  const received: Array<{ url: string; body: Buffer }> = [];
  const server = http.createServer((req, res) => {
    const chunks: Buffer[] = [];
    req.on('data', (c: Buffer) => chunks.push(c));
    req.on('end', () => { received.push({ url: req.url ?? '', body: Buffer.concat(chunks) }); res.statusCode = 201; res.end(); });
  });
  await new Promise<void>((r) => server.listen(0, '0.0.0.0', r));
  const base = `${prefix.replace(/:$/, '')}:${(server.address() as { port: number }).port}`;
  sql(`update private.platform_config set push_test_prefixes = array['${base}/']`);

  // Ben's phone: a real P-256 key pair; only the browser's subscribe() is replaced, so the
  // push lands at the mock push service instead of Google's.
  const ecdh = createECDH('prime256v1'); ecdh.generateKeys();
  const auth = randomBytes(16);
  const fake = { endpoint: `${base}/push/${randomUUID()}`, p256dh: ecdh.getPublicKey().toString('base64url'), auth: auth.toString('base64url') };
  const ca = await browser.newContext();
  const cb = await browser.newContext({ permissions: ['notifications'] });
  await cb.addInitScript((f) => {
    const bytes = (s: string) => Uint8Array.from(atob(s.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (s.length % 4)) % 4)), (c) => c.charCodeAt(0)).buffer;
    let active: PushSubscription | null = null;
    const make = () => ({
      endpoint: f.endpoint, expirationTime: null, options: { userVisibleOnly: true, applicationServerKey: null },
      getKey: (n: string) => bytes(n === 'p256dh' ? f.p256dh : f.auth),
      toJSON: () => ({ endpoint: f.endpoint, expirationTime: null, keys: { p256dh: f.p256dh, auth: f.auth } }),
      unsubscribe: async () => { active = null; return true; },
    }) as unknown as PushSubscription;
    PushManager.prototype.subscribe = async function () { active = make(); return active; };
    PushManager.prototype.getSubscription = async function () { return active; };
  }, fake);
  const a = await ca.newPage(), b = await cb.newPage();
  try {
    const ua = uniq('pna_'), ub = uniq('pnb_');
    await signUp(a, ua, 'Amy'); await signUp(b, ub, 'Ben');
    await befriendUi(a, b, ub, 'Amy');

    await nav(b, 'Settings').click();
    await b.getByRole('switch', { name: /Notifications on this device/ }).click();
    await expect(b.getByText('Notifications are on for this device')).toBeVisible();
    expect(sql(`select count(*) from private.push_subscriptions s join public.profiles p on p.id = s.user_id where p.username = '${ub}'`)).toBe('1');

    // Amy writes; Ben's device gets an encrypted "Amy — New Chat", without the text.
    await openPeople(a, 'Friends');
    await a.getByTestId('friend-row').getByRole('button').first().click();
    await a.getByLabel('Message').fill('the secret plan');
    await a.getByLabel('Message').press('Enter');
    // Usually immediate; if that first call is missed, the one-minute sweep (push_sweep) sends
    // it — the guarantee under test is delivery, not the speed of the first attempt.
    await expect.poll(() => received.length, { timeout: 75_000 }).toBeGreaterThan(0);
    const text = decrypt(received[0]!.body, ecdh, auth);
    expect(text).not.toContain('secret plan');
    expect(JSON.parse(text)).toMatchObject({ title: 'Amy', body: 'New Chat' });

    // The service worker shows it (delivered through DevTools, as the push service would).
    const cdp = await cb.newCDPSession(b);
    const regs: Array<{ registrationId: string; scopeURL: string; isDeleted: boolean }> = [];
    cdp.on('ServiceWorker.workerRegistrationUpdated', (e) => regs.push(...e.registrations));
    await cdp.send('ServiceWorker.enable');
    await expect.poll(() => regs.filter((r) => !r.isDeleted).length).toBeGreaterThan(0);
    const reg = regs.find((r) => !r.isDeleted)!;
    await cdp.send('ServiceWorker.deliverPushMessage', { origin: new URL(b.url()).origin, registrationId: reg.registrationId, data: text });
    await expect.poll(() => b.evaluate(async () => (await (await navigator.serviceWorker.ready).getNotifications()).map((n) => `${n.title}|${n.body}`)))
      .toContain('Amy|New Chat');

    // "New chats" off: no push for messages.
    await b.getByRole('switch', { name: 'New chats' }).uncheck();
    const before = received.length;
    await a.getByLabel('Message').fill('quiet one');
    await a.getByLabel('Message').press('Enter');
    await b.waitForTimeout(3000);
    expect(received.length).toBe(before);

    // Turning notifications off removes this device.
    await b.getByRole('switch', { name: /Notifications on this device/ }).click();
    await expect(b.getByText('Notifications are off for this device')).toBeVisible();
    expect(sql(`select count(*) from private.push_subscriptions s join public.profiles p on p.id = s.user_id where p.username = '${ub}'`)).toBe('0');
  } finally {
    server.close();
    sql(`update private.platform_config set push_test_prefixes = '{}'`);
    await ca.close(); await cb.close();
  }
});
