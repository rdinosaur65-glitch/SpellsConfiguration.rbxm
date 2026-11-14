import { execFileSync } from 'node:child_process';
import { expect, test, type Page } from '@playwright/test';
import { befriendUi, signUp, uniq } from './helpers';

const DB_URL = process.env.DB_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const sql = (q: string) => execFileSync('psql', [DB_URL, '-Atqc', q], { encoding: 'utf8' }).trim();
const nav = (p: Page, name: string) => p.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: new RegExp(`^${name}`) });
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEElEQVR4nGN44NAARwzEcQCqUhoBIWH54wAAAABJRU5ErkJggg==', 'base64');
const msg = (p: Page, text: string) => p.getByTestId('message').filter({ hasText: text });

test('reactions, message search and the photos/links/saved view', async ({ browser }) => {
  test.setTimeout(120_000);
  const [ca, cb] = await Promise.all([browser.newContext(), browser.newContext()]);
  const a = await ca.newPage(), b = await cb.newPage();
  const ua = uniq('exa_'), ub = uniq('exb_');
  await signUp(a, ua, 'Amy'); await signUp(b, ub, 'Ben');
  await befriendUi(a, b, ub, 'Amy');
  await b.getByTestId('friend-row').getByRole('button').first().click();
  await b.getByRole('button', { name: 'Chat settings' }).click();
  await b.getByRole('button', { name: 'Messages are kept' }).click();
  const conv = b.url().split('/chats/')[1]!;
  // Older history, so search has to load earlier pages to reach a hit.
  sql(`update public.conversation_members set joined_at = now() - interval '2 days' where conversation_id = '${conv}'`);
  sql(`insert into public.messages (conversation_id, sender_id, kind, body, client_msg_id, created_at, expiry_mode)
       select '${conv}', p.id, 'text', case when g = 3 then 'the old pizza place' else 'filler ' || g end, gen_random_uuid(),
              now() - interval '1 day' + g * interval '1 second', 'never'
         from public.profiles p, generate_series(1, 230) g where p.username = '${ua}'`);
  await b.reload();
  await b.getByLabel('Message').fill('pizza tonight? see https://example.com/menu');
  await b.getByLabel('Message').press('Enter');
  await b.getByTestId('photo-input').setInputFiles({ name: 'pic.png', mimeType: 'image/png', buffer: PNG });
  await expect(b.getByTestId('message').last()).not.toContainText('sending', { timeout: 15_000 });

  // Amy reacts ❤️ to Ben's message; Ben sees it live and adds his own.
  await nav(a, 'Chats').click();
  await a.getByTestId('chat-row').first().getByRole('link').click();
  await msg(a, 'pizza tonight').getByRole('button').first().click();
  await a.getByRole('button', { name: 'React ❤️' }).click();
  await expect(msg(a, 'pizza tonight').getByTestId('reactions')).toContainText('❤️');
  await expect(msg(b, 'pizza tonight').getByRole('button', { name: /❤️ from Amy/ })).toBeVisible();
  await msg(b, 'pizza tonight').getByRole('button', { name: /❤️ from Amy/ }).click();
  await expect(msg(b, 'pizza tonight').getByTestId('reactions')).toContainText('❤️ 2');
  await expect(msg(a, 'pizza tonight').getByTestId('reactions')).toContainText('❤️ 2');
  // Changing a reaction replaces it (one per person); tapping yours again removes it.
  await msg(a, 'pizza tonight').getByRole('button').first().click();
  await a.getByRole('button', { name: 'React 😂' }).click();
  await expect(msg(a, 'pizza tonight').getByTestId('reactions')).toContainText('😂');
  await expect(msg(a, 'pizza tonight').getByTestId('reactions')).not.toContainText('❤️ 2');
  await msg(a, 'pizza tonight').getByRole('button', { name: /😂 from you/ }).click();
  await expect(msg(a, 'pizza tonight').getByTestId('reactions')).not.toContainText('😂');
  expect(sql(`select string_agg(emoji, '') from public.message_reactions where conversation_id = '${conv}'`)).toBe('❤️');

  // Search in this chat reaches an old message and scrolls to it.
  await b.getByRole('button', { name: 'Chat settings' }).click();
  await b.getByRole('button', { name: 'Search in this chat' }).click();
  await b.getByRole('searchbox', { name: 'Search messages' }).fill('pizza');
  const results = b.getByTestId('search-results');
  await expect(results).toContainText('the old pizza place');
  await expect(results).toContainText('pizza tonight?');
  await results.getByRole('button', { name: /the old pizza place/ }).click();
  const old = msg(b, 'the old pizza place');
  await expect(old).toHaveClass(/msg-highlight/);
  await expect(old).toBeInViewport();

  // Search across all chats opens the chat at the message.
  await a.getByRole('link', { name: 'Back to chats' }).click();
  await a.getByRole('button', { name: 'Search all chats' }).click();
  await a.getByRole('searchbox', { name: 'Search messages' }).fill('pizza tonight');
  await a.getByTestId('search-results').getByRole('button').first().click();
  await expect(msg(a, 'pizza tonight')).toHaveClass(/msg-highlight/);

  // Photos, links and saved.
  await a.getByRole('button', { name: 'Chat settings' }).click();
  await a.getByRole('button', { name: 'Photos, links and saved' }).click();
  await expect(a.getByTestId('gallery').locator('.gallery-cell')).toHaveCount(1);
  await a.getByRole('button', { name: 'Links' }).click();
  await expect(a.getByRole('link', { name: 'https://example.com/menu' })).toBeVisible();
  await a.getByRole('button', { name: 'Saved' }).click();
  await expect(a.getByText('Nothing here yet.')).toBeVisible();
  await a.keyboard.press('Escape');
  await msg(a, 'filler 230').getByRole('button').first().click();
  await a.getByRole('button', { name: 'Save in chat' }).click();
  await a.getByRole('button', { name: 'Chat settings' }).click();
  await a.getByRole('button', { name: 'Photos, links and saved' }).click();
  await a.getByRole('button', { name: 'Saved' }).click();
  await expect(a.getByTestId('gallery')).toContainText('filler 230');
  await ca.close(); await cb.close();
});
