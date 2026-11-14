import { execFileSync } from 'node:child_process';
import { devices, expect, test, type Page } from '@playwright/test';
import { befriendUi, signUp, uniq } from './helpers';

const DB_URL = process.env.DB_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const sql = (q: string) => execFileSync('psql', [DB_URL, '-Atqc', q], { encoding: 'utf8' }).trim();
const nav = (p: Page, name: string) => p.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: new RegExp(`^${name}`) });

/** Two friends; `b` opens their chat (messages kept). Returns pages and the chat id. */
async function pair(browser: import('@playwright/test').Browser, opts: Parameters<typeof browser.newContext>[0],
                    names = ['Amy', 'Ben']) {
  const ca = await browser.newContext(opts), cb = await browser.newContext(opts);
  const a = await ca.newPage(), b = await cb.newPage();
  const ua = uniq('mpa_'), ub = uniq('mpb_');
  await signUp(a, ua, names[0]!); await signUp(b, ub, names[1]!);
  await befriendUi(a, b, ub, names[0]!);
  await b.getByTestId('friend-row').getByRole('button').first().click();
  await b.getByRole('button', { name: 'Chat settings' }).click();
  await b.getByRole('button', { name: 'Messages are kept' }).click();
  await expect(b.locator('.chat-notice')).toContainText('Messages are kept');
  const conv = b.url().split('/chats/')[1]!;
  return { ca, cb, a, b, ua, ub, conv };
}

test('long names never push buttons off a small phone screen', async ({ browser }) => {
  const long = 'Bartholomew Featherstonehaugh the Third';         // 39 characters
  const { ca, cb, a, b, ub } = await pair(browser, { ...devices['iPhone SE'] }, [long, 'Alexandria Montgomery-Wolfeschlegel']);
  await b.getByLabel('Message').fill('hello');
  await b.getByLabel('Message').press('Enter');
  const width = a.viewportSize()!.width;
  const inside = async (p: Page, name: string | RegExp) => {
    const box = (await p.getByRole('button', { name }).first().boundingBox())!;
    expect(box.x + box.width).toBeLessThanOrEqual(width);
  };
  await nav(a, 'Friends').click();
  await inside(a, `More options for ${ub}`);
  await nav(a, 'Chats').click();
  await inside(a, /^Options for /);
  expect(await a.locator('.screen').evaluate((el) => el.scrollWidth <= el.clientWidth)).toBe(true);
  await b.getByRole('link', { name: 'Back to chats' }).click();
  await inside(b, /^Options for /);
  await ca.close(); await cb.close();
});

test('tall sheets scroll inside a short screen', async ({ browser }) => {
  const { ca, cb, a, ub } = await pair(browser, { viewport: { width: 375, height: 548 }, isMobile: true, hasTouch: true });
  await nav(a, 'Friends').click();
  await a.getByRole('button', { name: `More options for ${ub}` }).click();
  await a.getByRole('button', { name: 'Report' }).click();
  const sheet = a.getByRole('dialog');
  const box = (await sheet.boundingBox())!;
  expect(box.y + box.height).toBeLessThanOrEqual(548 + 1);
  await sheet.getByRole('button', { name: 'Back' }).click();       // reachable (scrolls inside the sheet)
  await expect(sheet.getByRole('button', { name: 'Report' })).toBeVisible();
  await ca.close(); await cb.close();
});

test('messages written offline arrive in the order they were typed', async ({ browser }) => {
  const { ca, cb, b, cb: ctxB, conv } = await pair(browser, {});
  await ctxB.setOffline(true);
  for (let i = 1; i <= 5; i++) {
    await b.getByLabel('Message').fill(`order ${i}`);
    await b.getByLabel('Message').press('Enter');
  }
  await expect(b.getByTestId('message').filter({ hasText: 'order 5' })).toBeVisible();
  await ctxB.setOffline(false);
  await expect.poll(() => sql(`select count(*) from public.messages where conversation_id = '${conv}' and body like 'order %'`),
                    { timeout: 20_000 }).toBe('5');
  expect(sql(`select string_agg(body, ',' order by created_at) from public.messages where conversation_id = '${conv}' and body like 'order %'`))
    .toBe('order 1,order 2,order 3,order 4,order 5');
  await ca.close(); await cb.close();
});

test('opening the keyboard keeps the newest message in view', async ({ browser }) => {
  const { ca, cb, b, ua, conv } = await pair(browser, { ...devices['Pixel 7'] });
  sql(`update public.conversation_members set joined_at = now() - interval '2 days' where conversation_id = '${conv}'`);
  sql(`insert into public.messages (conversation_id, sender_id, kind, body, client_msg_id, created_at, expiry_mode)
       select '${conv}', p.id, 'text', 'line ' || g, gen_random_uuid(), now() - interval '1 hour' + g * interval '1 second', 'never'
         from public.profiles p, generate_series(1, 30) g where p.username = '${ua}'`);
  await b.reload();
  const last = b.getByText('line 30', { exact: true });
  await expect(last).toBeInViewport();
  await b.getByLabel('Message').focus();
  const vp = b.viewportSize()!;
  await b.setViewportSize({ width: vp.width, height: vp.height - 300 });   // a 300px keyboard
  await expect(last).toBeInViewport();
  await ca.close(); await cb.close();
});

test('messages that disappeared on the server leave an open chat when it refreshes', async ({ browser }) => {
  const { ca, cb, b, ua, conv } = await pair(browser, {});
  sql(`update public.conversation_members set joined_at = now() - interval '2 days' where conversation_id = '${conv}'`);
  sql(`insert into public.messages (conversation_id, sender_id, kind, body, client_msg_id, created_at, expiry_mode, expires_at)
       select '${conv}', p.id, 'text', v.body, gen_random_uuid(), now() - interval '10 minutes' + v.n * interval '1 second', 'never',
              case when v.n > 1 then now() + interval '1 day' end
         from public.profiles p, (values (1, 'kept message'), (2, 'secret 1'), (3, 'secret 2')) v(n, body) where p.username = '${ua}'`);
  await b.reload();
  await expect(b.getByTestId('messages')).toContainText('secret 2');
  sql(`update public.messages set expires_at = now() - interval '1 second' where conversation_id = '${conv}' and body like 'secret %'`);
  await b.evaluate(() => window.dispatchEvent(new Event('online')));   // what reconnecting does
  await expect(b.getByText('secret 1')).toHaveCount(0);
  await expect(b.getByText('secret 2')).toHaveCount(0);
  await expect(b.getByTestId('messages')).toContainText('kept message');
  await ca.close(); await cb.close();
});
