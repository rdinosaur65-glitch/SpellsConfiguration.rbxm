import { execFileSync } from 'node:child_process';
import { expect, test, type Page } from '@playwright/test';
import { befriendUi, openPeople, signIn, signUp, uniq } from './helpers';

const DB_URL = process.env.DB_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const sql = (q: string) => execFileSync('psql', [DB_URL, '-Atqc', q], { encoding: 'utf8' }).trim();
const nav = (p: Page, name: string) => p.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: new RegExp(`^${name}`) });

async function chats(p: Page) {
  await nav(p, 'Chats').click();
  await expect(p.getByRole('heading', { name: 'Chats', exact: true })).toBeVisible();
}
async function signOutAndIn(p: Page, email: string) {
  await nav(p, 'Settings').click();
  await p.getByRole('button', { name: 'Sign out', exact: true }).first().click();
  await expect(p.getByRole('button', { name: 'Sign in' })).toBeVisible();
  await signIn(p, email);
  await expect(p.getByRole('navigation', { name: 'Main' })).toBeVisible();
}

test('removing a blocked chat hides it only for the person who pressed ×', async ({ browser }) => {
  test.setTimeout(150_000);
  const [ca, cb] = await Promise.all([browser.newContext(), browser.newContext()]);
  const a = await ca.newPage(), b = await cb.newPage();
  const ua = uniq('bla_'), ub = uniq('blb_');
  const emailA = await signUp(a, ua, 'Ada'); const emailB = await signUp(b, ub, 'Bea');
  await befriendUi(a, b, ub, 'Ada');

  // A conversation with history on both sides.
  await b.getByTestId('friend-row').getByRole('button').first().click();
  await b.getByRole('button', { name: 'Chat settings' }).click();
  await b.getByRole('button', { name: 'Messages are kept' }).click();
  const conv = b.url().split('/chats/')[1]!;
  await b.getByLabel('Message').fill('keep this one');
  await b.getByLabel('Message').press('Enter');
  await chats(a);
  await a.getByTestId('chat-row').first().getByRole('link').click();
  await expect(a.getByTestId('messages')).toContainText('keep this one');
  await a.getByLabel('Message').fill('and this reply');
  await a.getByLabel('Message').press('Enter');
  await expect(b.getByTestId('messages')).toContainText('and this reply');
  const count = () => sql(`select count(*) from public.messages where conversation_id = '${conv}'`);
  const before = count();
  const hidden = (u: string) => sql(`select hidden_at is not null from public.conversation_members m join public.profiles p on p.id = m.user_id
                                     where m.conversation_id = '${conv}' and p.username = '${u}'`);

  // Ada blocks Bea: Ada keeps the chat, marked Blocked, with an ×. Bea cannot see or use it.
  await a.getByRole('link', { name: 'Back to chats' }).click();
  await openPeople(a, 'Friends');
  await a.getByTestId('friend-row').getByRole('button', { name: `More options for ${ub}` }).click();
  a.once('dialog', (d) => d.accept());
  await a.getByRole('button', { name: 'Block' }).click();
  await chats(a);
  const rowA = a.getByTestId('chat-row').filter({ hasText: 'Blocked' });
  await expect(rowA).toHaveCount(1);
  await b.getByRole('link', { name: 'Back to chats' }).click();
  await expect(b.getByText('No chats yet')).toBeVisible();

  // Ada presses ×: gone from Ada's list only. Nothing is deleted.
  await rowA.getByRole('button', { name: /^Remove chat with .* from your list$/ }).click();
  await expect(a.getByText('Removed from your chats')).toBeVisible();
  await expect(a.getByText('No chats yet')).toBeVisible();
  expect(count()).toBe(before);
  expect(hidden(ua)).toBe('t');
  expect(hidden(ub)).toBe('f');

  // It stays removed for Ada after signing out and back in.
  await signOutAndIn(a, emailA);
  await chats(a);
  await expect(a.getByText('No chats yet')).toBeVisible();

  // Ada unblocks Bea. Bea's chat comes back with its whole history; Ada's stays removed.
  await nav(a, 'Settings').click();
  await a.getByTestId('blocked-row').filter({ hasText: ub }).getByRole('button', { name: 'Unblock' }).click();
  await expect(a.getByText(`Unblocked @${ub}`)).toBeVisible();
  await chats(a);
  await expect(a.getByText('No chats yet')).toBeVisible();
  await openPeople(b);
  await chats(b);
  await b.getByTestId('chat-row').first().getByRole('link').click();
  await expect(b.getByTestId('messages')).toContainText('keep this one');
  await expect(b.getByTestId('messages')).toContainText('and this reply');

  // Now Bea blocks Ada and removes it on her side — independently of Ada's setting.
  await b.getByRole('link', { name: 'Back to chats' }).click();
  await openPeople(b, 'Discover');
  await b.getByLabel('Search by username').fill(ua);
  await b.getByRole('button', { name: `More options for ${ua}` }).click();
  b.once('dialog', (d) => d.accept());
  await b.getByRole('button', { name: 'Block' }).click();
  await chats(b);
  const rowB = b.getByTestId('chat-row').filter({ hasText: 'Blocked' });
  await expect(rowB).toHaveCount(1);
  await rowB.getByRole('button', { name: /^Remove chat with .* from your list$/ }).click();
  await expect(b.getByText('No chats yet')).toBeVisible();
  expect(hidden(ub)).toBe('t');
  expect(count()).toBe(before);
  expect(sql(`select count(*) from public.conversations where id = '${conv}'`)).toBe('1');

  // Both settings persist across sign-in; the shared history is still there.
  await signOutAndIn(b, emailB);
  await chats(b);
  await expect(b.getByText('No chats yet')).toBeVisible();
  expect(sql(`select string_agg(body, ' | ' order by created_at) from public.messages
              where conversation_id = '${conv}' and kind = 'text'`)).toBe('keep this one | and this reply');
  await ca.close(); await cb.close();
});
