import { expect, test, type Page } from '@playwright/test';
import { openPeople, signUp, uniq } from './helpers';

const nav = (p: Page) => p.getByRole('navigation', { name: 'Main' });

test('People: no Friends tab; find, request, accept, chat and come back to Chats', async ({ browser }) => {
  test.setTimeout(120_000);
  const [ca, cb] = await Promise.all([browser.newContext(), browser.newContext()]);
  const a = await ca.newPage(), b = await cb.newPage();
  const ua = uniq('pa_'), ub = uniq('pb_');
  await signUp(a, ua, 'Ari'); await signUp(b, ub, 'Bex');

  // Three tabs; friends live behind the People button in the Chats header.
  await expect(nav(a).getByRole('link')).toHaveText(['Camera', 'Chats', 'Settings']);
  await nav(a).getByRole('link', { name: /^Chats/ }).click();
  await expect(a.getByRole('heading', { name: 'Chats', exact: true })).toBeVisible();
  await a.getByTestId('people-button').click();
  // No friends and no requests yet: Discover opens, with a friendly empty state.
  await expect(a.getByRole('tab', { name: /^Discover/ })).toHaveAttribute('aria-selected', 'true');
  await expect(a.getByText('Find your people')).toBeVisible();
  await a.getByLabel('Search by username').fill(ub);
  await a.getByRole('button', { name: `Add @${ub}` }).click();
  await expect(a.getByTestId('person-result').filter({ hasText: `@${ub}` })).toContainText('Requested');
  await a.getByRole('tab', { name: /^Requests/ }).click();
  await expect(a.getByTestId('outgoing-request')).toContainText('Bex');

  // Bex: a dot on Chats, a count on People; People opens on the waiting request.
  await nav(b).getByRole('link', { name: /^Chats/ }).click();
  await expect(nav(b).locator('.nav-dot')).toBeVisible();
  await expect(b.getByTestId('people-button')).toHaveAttribute('aria-label', 'People, 1 friend request');
  await b.getByTestId('people-button').click();
  await expect(b.getByRole('tab', { name: /^Requests/ })).toHaveAttribute('aria-selected', 'true');
  await expect(b.getByRole('tab', { name: /^Requests/ })).toContainText('1');
  const card = b.getByTestId('incoming-request').filter({ hasText: 'Ari' });
  await expect(card).toContainText(`@${ua}`);
  await card.getByRole('button', { name: `Accept @${ua}` }).click();
  // Accepted: Friends shows Ari; tapping opens the chat.
  await expect(b.getByRole('tab', { name: /^Friends/ })).toHaveAttribute('aria-selected', 'true');
  await b.getByTestId('friend-row').filter({ hasText: 'Ari' }).getByRole('button', { name: 'Chat with Ari' }).click();
  await expect(b.getByTestId('chat-title')).toHaveText('Ari');
  await b.getByLabel('Message').fill('hi from people');
  await b.getByLabel('Message').press('Enter');
  await expect(b.getByTestId('messages')).toContainText('hi from people');
  // Back lands on Chats; the request badge is gone.
  await b.getByRole('link', { name: 'Back to chats' }).click();
  await expect(b.getByTestId('chat-row').filter({ hasText: 'Ari' })).toBeVisible();
  await expect(b.getByTestId('people-button')).toHaveAttribute('aria-label', 'People');
  await expect(nav(b).locator('.nav-dot')).toHaveCount(0);

  // Ari sees Bex as a friend in Discover; the profile sheet opens the chat too.
  await openPeople(a, 'Discover');
  await a.getByLabel('Search by username').fill(ub);
  const row = a.getByTestId('person-result').filter({ hasText: `@${ub}` });
  await expect(row).toContainText('Friends');
  await a.getByRole('tab', { name: /^Friends/ }).click();
  await a.getByRole('button', { name: `More options for ${ub}` }).click();
  await expect(a.getByRole('dialog')).toContainText(`@${ub}`);
  await a.getByRole('button', { name: 'Open chat' }).click();
  await expect(a.getByTestId('chat-title')).toHaveText('Bex');

  // Block from Friends → shown as Blocked in Discover, with Unblock.
  await a.getByRole('link', { name: 'Back to chats' }).click();
  await openPeople(a, 'Friends');
  await a.getByRole('button', { name: `More options for ${ub}` }).click();
  a.once('dialog', (d) => d.accept());
  await a.getByRole('button', { name: 'Block' }).click();
  await expect(a.getByText('No friends yet')).toBeVisible();
  await a.getByRole('tab', { name: /^Discover/ }).click();
  await a.getByLabel('Search by username').fill(ub);
  const blockedRow = a.getByTestId('person-result').filter({ hasText: `@${ub}` });
  await expect(blockedRow).toContainText('Blocked');
  await blockedRow.getByRole('button', { name: `Unblock @${ub}` }).click();
  await expect(a.getByText(`Unblocked @${ub}`)).toBeVisible();
  await expect(a.getByRole('button', { name: `Add @${ub}` })).toBeVisible();
  // Bex never sees Ari while blocked, and sees Ari again (as addable) once unblocked.
  await openPeople(b, 'Discover');
  await b.getByLabel('Search by username').fill(ua);
  await expect(b.getByRole('button', { name: `Add @${ua}` })).toBeVisible();

  // The old address still works (friend-request notifications point to it).
  await a.goto('/friends');
  await expect(a.getByRole('tab', { name: /^Requests/ })).toHaveAttribute('aria-selected', 'true');

  await ca.close(); await cb.close();
});

test('New chat: one friend opens your chat with them', async ({ browser }) => {
  const [ca, cb] = await Promise.all([browser.newContext(), browser.newContext()]);
  const a = await ca.newPage(), b = await cb.newPage();
  const ua = uniq('na_'), ub = uniq('nb_');
  await signUp(a, ua, 'Noa'); await signUp(b, ub, 'Nik');
  const { befriendUi } = await import('./helpers');
  await befriendUi(a, b, ub, 'Noa');
  await nav(a).getByRole('link', { name: /^Chats/ }).click();
  await a.getByRole('button', { name: 'New chat or group' }).click();
  const sheet = a.getByRole('dialog', { name: 'New chat' });
  await sheet.getByRole('checkbox').first().check();
  await sheet.getByRole('button', { name: 'Chat with Nik' }).click();
  await expect(a.getByTestId('chat-title')).toHaveText('Nik');
  await ca.close(); await cb.close();
});
