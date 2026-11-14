import { execFileSync } from 'node:child_process';
import { expect, test } from '@playwright/test';
import { befriendUi, signUp, uniq } from './helpers';

const DB_URL = process.env.DB_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const sql = (q: string) => execFileSync('psql', [DB_URL, '-Atqc', q], { encoding: 'utf8' }).trim();

test('long chats: earlier messages load on request', async ({ browser }) => {
  const ca = await browser.newContext(), cb = await browser.newContext();
  const a = await ca.newPage(), b = await cb.newPage();
  const ua = uniq('hia_'), ub = uniq('hib_');
  await signUp(a, ua, 'Hana'); await signUp(b, ub, 'Iker');
  await befriendUi(a, b, ub, 'Hana');
  await b.getByTestId('friend-row').getByRole('button').first().click();
  await b.getByRole('button', { name: 'Chat settings' }).click();
  await b.getByRole('button', { name: 'Messages are kept' }).click();
  const conv = b.url().split('/chats/')[1]!;
  // 230 older messages from Hana (seeded directly: the API would rate-limit this, by design).
  sql(`update public.conversation_members set joined_at = now() - interval '2 days' where conversation_id = '${conv}'`);
  sql(`insert into public.messages (conversation_id, sender_id, kind, body, client_msg_id, created_at, expiry_mode)
       select '${conv}', p.id, 'text', 'old message ' || g, gen_random_uuid(), now() - interval '1 day' + g * interval '1 second', 'never'
         from public.profiles p, generate_series(1, 230) g where p.username = '${ua}'`);
  await b.reload();
  await expect(b.getByTestId('messages')).toContainText('old message 230');
  await expect(b.getByText('old message 1', { exact: true })).toHaveCount(0);   // only the newest 200 at first
  // Late live events for those (seeded) rows must not slip older messages in out of order.
  await b.waitForTimeout(2000);
  await expect(b.getByText('old message 1', { exact: true })).toHaveCount(0);
  // The reader keeps their place, even without the browser's scroll anchoring (Safari).
  await b.addStyleTag({ content: '.messages { overflow-anchor: none; }' });
  await b.getByTestId('messages').evaluate((el) => { el.scrollTop = 0; });
  const anchor = b.getByText('old message 32', { exact: true });   // first on screen
  const before = (await anchor.boundingBox())!.y;
  await b.getByRole('button', { name: 'Load earlier messages' }).click();
  await expect(b.getByText('old message 1', { exact: true })).toBeAttached();
  expect(Math.abs((await anchor.boundingBox())!.y - before)).toBeLessThan(6);
  await b.getByText('old message 1', { exact: true }).scrollIntoViewIfNeeded();
  await expect(b.getByText('old message 1', { exact: true })).toBeVisible();
  await expect(b.getByRole('button', { name: 'Load earlier messages' })).toHaveCount(0);   // nothing older left
  await ca.close(); await cb.close();
});
