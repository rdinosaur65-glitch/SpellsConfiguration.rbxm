import { execFileSync } from 'node:child_process';
import { expect, test, type Page } from '@playwright/test';
import { befriendUi, openPeople, signUp, uniq } from './helpers';

const DB_URL = process.env.DB_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const sql = (q: string) => execFileSync('psql', [DB_URL, '-Atqc', q], { encoding: 'utf8' }).trim();
const nav = (p: Page, name: string) => p.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: new RegExp(`^${name}`) });

test.afterEach(() => { sql(`update private.platform_config set streak_timezone = 'UTC', streak_warn_hours = 4`); });

async function snapTo(p: Page, friend: string) {
  await nav(p, 'Camera').click();
  await p.getByRole('button', { name: 'Open camera' }).click();
  await p.getByRole('button', { name: 'Take photo' }).click();
  await p.getByRole('button', { name: 'Send to…' }).click();
  await p.getByRole('checkbox', { name: `Send to ${friend}` }).check();
  await p.getByRole('button', { name: 'Send', exact: true }).click();
  await expect(p.getByText('Snap sent to 1 chat')).toBeVisible({ timeout: 15_000 });
}
const chatRow = (p: Page, name: string) => p.getByTestId('chat-row').filter({ hasText: name });

test('streaks: both friends Snap the same day → 🔥1; ⌛ near the end; a milestone is celebrated once', async ({ browser }) => {
  test.setTimeout(150_000);
  const [ca, cb] = await Promise.all([browser.newContext(), browser.newContext()]);
  const a = await ca.newPage(), b = await cb.newPage();
  const ua = uniq('sa_'), ub = uniq('sb_');
  await signUp(a, ua, 'Sky'); await signUp(b, ub, 'Bo');
  await befriendUi(a, b, ub, 'Sky');
  const pair = `least((select id from public.profiles where username = '${ua}'), (select id from public.profiles where username = '${ub}'))`;
  const pairB = pair.replace('least(', 'greatest(');

  // Sky sends a Snap: one-sided, no streak.
  await snapTo(a, 'Bo');
  await nav(a, 'Chats').click();
  await expect(chatRow(a, 'Bo')).toBeVisible();
  await expect(chatRow(a, 'Bo').getByTestId('streak')).toHaveCount(0);
  // A text message from Bo does not count either.
  await nav(b, 'Chats').click();
  await chatRow(b, 'Sky').getByRole('link').click();
  await b.getByLabel('Message').fill('nice!');
  await b.getByLabel('Message').press('Enter');
  await expect(b.getByText('nice!')).toBeVisible();
  await a.reload();
  await expect(chatRow(a, 'Bo').getByTestId('streak')).toHaveCount(0);

  // Bo sends a Snap back: 🔥1 for both, in the chat list, friends list and the chat.
  await b.getByRole('link', { name: 'Back to chats' }).click();
  await snapTo(b, 'Sky');
  await nav(b, 'Chats').click();
  await expect(chatRow(b, 'Sky').getByTestId('streak')).toHaveAttribute('aria-label', '1-day streak');
  await a.reload();
  await expect(chatRow(a, 'Bo').getByTestId('streak')).toHaveAttribute('aria-label', '1-day streak');
  await openPeople(a, 'Friends');
  await expect(a.getByTestId('friend-row').filter({ hasText: 'Bo' }).getByTestId('streak')).toContainText('1');
  await nav(a, 'Chats').click();
  await chatRow(a, 'Bo').getByRole('link').click();
  await a.getByRole('button', { name: /1-day streak — details/ }).click();
  await expect(a.getByTestId('streak-sheet')).toContainText('You both sent a Snap today');
  await expect(a.getByTestId('streak-sheet')).toContainText('Streak days end at');
  await a.keyboard.press('Escape');

  // Late in the server day (timezone chosen so it is 18:00 there), 9 days so far, nobody
  // has sent today: ⌛ for both.
  const h = new Date().getUTCHours();
  let o = 18 - h; if (o > 14) o -= 24; if (o < -12) o += 24;
  const tz = o >= 0 ? `Etc/GMT-${o}` : `Etc/GMT+${-o}`;
  sql(`update private.platform_config set streak_timezone = '${tz}', streak_warn_hours = 8`);
  sql(`update private.streaks set count = 9, best = 9, last_completed_on = private.streak_day(now()) - 1,
         a_sent_on = private.streak_day(now()) - 1, b_sent_on = private.streak_day(now()) - 1, milestone = 0,
         a_milestone_seen = 0, b_milestone_seen = 0 where user_a = ${pair} and user_b = ${pairB}`);
  await a.getByRole('link', { name: 'Back to chats' }).click();
  await a.reload();
  await expect(chatRow(a, 'Bo').getByTestId('streak')).toHaveAttribute('aria-label', '9-day streak, ending soon');
  await expect(chatRow(a, 'Bo').getByTestId('streak')).toContainText('⌛');

  // Both send today: 10 days, the ⌛ goes, and the milestone is celebrated — once.
  await snapTo(a, 'Bo');
  await nav(a, 'Chats').click();
  await expect(chatRow(a, 'Bo').getByTestId('streak')).toContainText('⌛');      // still waiting for Bo
  await snapTo(b, 'Sky');
  await nav(a, 'Chats').click();
  await a.reload();
  await expect(chatRow(a, 'Bo').getByTestId('streak')).toHaveAttribute('aria-label', '10-day streak');
  await expect(a.getByTestId('streak-milestone')).toContainText('10 days of Snaps with Bo');
  await a.getByRole('button', { name: 'Dismiss' }).click();
  await a.reload();
  await expect(chatRow(a, 'Bo').getByTestId('streak')).toBeVisible();
  await expect(a.getByTestId('streak-milestone')).toHaveCount(0);                  // not repeated
  // Bo sees it too, the first time he looks.
  await nav(b, 'Chats').click();
  await b.reload();
  await expect(b.getByTestId('streak-milestone')).toContainText('10 days of Snaps with Sky');

  // Removing the friend ends the streak for both.
  await openPeople(a, 'Friends');
  await a.getByRole('button', { name: `More options for ${ub}` }).click();
  a.once('dialog', (d) => d.accept());
  await a.getByRole('button', { name: 'Remove friend' }).click();
  await nav(b, 'Chats').click();
  await b.reload();
  await expect(chatRow(b, 'Sky').getByTestId('streak')).toHaveCount(0);
  expect(sql(`select count(*) from private.streaks where user_a = ${pair} and user_b = ${pairB}`)).toBe('0');

  await ca.close(); await cb.close();
});
