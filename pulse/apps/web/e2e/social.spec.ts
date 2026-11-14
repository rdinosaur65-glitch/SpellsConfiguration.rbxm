import { expect, test, type Page } from '@playwright/test';
import { signUp, uniq } from './helpers';

const nav = (p: Page, name: string) => p.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: new RegExp(`^${name}`) });
async function openFriends(p: Page) { await nav(p, 'Friends').click(); }

test('two people become friends and chat in real time', async ({ browser }) => {
  const ctxA = await browser.newContext(); const ctxB = await browser.newContext();
  const a = await ctxA.newPage(); const b = await ctxB.newPage();
  const ua = uniq('amy_'); const ub = uniq('bob_');
  await signUp(a, ua, 'Amy');
  await signUp(b, ub, 'Bob');

  // Amy finds Bob by partial username and sends a request.
  await openFriends(a);
  await a.getByLabel('Search by username').fill(ub.slice(0, 8));
  await a.getByRole('button', { name: `Add @${ub}` }).click();
  await expect(a.getByText('Requested')).toBeVisible();

  // Bob sees it arrive live (badge + list) and accepts.
  await expect(nav(b, 'Friends').locator('.nav-badge')).toHaveText('1');
  await openFriends(b);
  const req = b.getByTestId('incoming-request');
  await expect(req).toContainText('Amy');
  await req.getByRole('button', { name: 'Accept' }).click();
  await expect(b.getByTestId('friend-row')).toContainText('Amy');

  // Bob opens the chat and sends a message; Amy's chat list labels it "New Chat" without a preview.
  await b.getByTestId('friend-row').getByRole('button').first().click();
  await expect(b.getByTestId('chat-title')).toHaveText('Amy');
  // Default is "disappear after viewing"; keep messages so the edit below is possible.
  await expect(b.getByText('Messages disappear after everyone has seen them')).toBeVisible();
  await b.getByRole('button', { name: 'Chat settings' }).click();
  await b.getByRole('button', { name: 'Messages are kept' }).click();
  await expect(b.locator('.chat-notice')).toContainText('Messages are kept');
  // The change is announced in the chat for both people.
  await expect(b.getByTestId('system-message')).toContainText('You changed this chat: Messages are kept');
  await b.getByLabel('Message').fill('hey amy 👋');
  await b.getByRole('button', { name: 'Send', exact: true }).click();
  await expect(b.getByTestId('message').last()).not.toContainText('sending');
  await b.getByRole('link', { name: 'Back to chats' }).click();
  await expect(b.getByTestId('chat-row').first()).toContainText('Delivered');

  await nav(a, 'Chats').click();
  const row = a.getByTestId('chat-row').first();
  await expect(row).toContainText('New Chat');
  await expect(row).not.toContainText('hey amy');

  // Amy opens it; Bob's list updates live to "Opened". Amy replies; Bob sees typing + message live.
  await row.getByRole('link').click();
  await expect(a.getByTestId('messages')).toContainText('hey amy 👋');
  await expect(a.getByTestId('system-message')).toContainText('Bob changed this chat: Messages are kept');
  await expect(a.locator('.chat-notice')).toContainText('Messages are kept');
  await expect(b.getByTestId('chat-row').first()).toContainText('Opened');
  await b.getByTestId('chat-row').first().getByRole('link').click();
  await expect(b.getByTestId('messages')).toContainText('hey amy 👋');
  await a.getByLabel('Message').pressSequentially('hi bob', { delay: 30 });
  await expect(b.getByTestId('typing')).toContainText('Amy is typing');
  await a.getByLabel('Message').press('Enter');
  await expect(b.getByTestId('messages')).toContainText('hi bob');

  await b.getByRole('link', { name: 'Back to chats' }).click();
  await expect(b.getByTestId('chat-row').first()).toContainText('Received');

  // Edit within the window propagates.
  await a.getByTestId('message').filter({ hasText: 'hi bob' }).getByRole('button').first().click();
  await a.getByRole('button', { name: 'Edit' }).click();
  await a.getByLabel('Message').fill('hi bob!!');
  await a.getByRole('button', { name: 'Save edit' }).click();
  await b.getByTestId('chat-row').first().getByRole('link').click();
  await expect(b.getByTestId('messages')).toContainText('hi bob!!');
  await expect(b.getByTestId('messages')).toContainText('edited');

  // "Show when I'm typing" off: Bob no longer sees Amy typing, but still gets her message.
  await a.getByRole('link', { name: 'Back to chats' }).click();
  await nav(a, 'Settings').click();
  await a.getByRole('switch', { name: /Show when I'm typing/ }).uncheck();
  await nav(a, 'Chats').click();
  await a.getByTestId('chat-row').first().getByRole('link').click();
  await a.getByLabel('Message').pressSequentially('quiet typing', { delay: 40 });
  await b.waitForTimeout(2500);
  await expect(b.getByTestId('typing')).toHaveCount(0);
  await a.getByLabel('Message').press('Enter');
  await expect(b.getByTestId('messages')).toContainText('quiet typing');

  // Blocking removes the friendship and the chat for the blocker's side.
  await a.getByRole('link', { name: 'Back to chats' }).click();
  await openFriends(a);
  await a.getByRole('button', { name: `More options for ${ub}` }).click();
  a.once('dialog', (d) => d.accept());
  await a.getByRole('button', { name: 'Block' }).click();
  await expect(a.getByText('No friends yet')).toBeVisible();
  await nav(a, 'Chats').click();
  await expect(a.getByText('No chats yet')).toBeVisible();

  await ctxA.close(); await ctxB.close();
});

test('appearance and privacy settings persist across devices', async ({ browser }) => {
  const ctx1 = await browser.newContext(); const p1 = await ctx1.newPage();
  const u = uniq('set_');
  const email = await signUp(p1, u, 'Setter');
  await p1.getByRole('link', { name: 'Settings' }).click();
  await p1.getByRole('group', { name: 'Theme' }).getByRole('button', { name: 'Light' }).click();
  await p1.getByRole('switch', { name: /^Ghost Mode/ }).check();
  await expect(p1.locator('html')).toHaveAttribute('data-theme', 'light');

  // A second device signs in and gets the same settings; both sessions are listed.
  const ctx2 = await browser.newContext(); const p2 = await ctx2.newPage();
  await p2.goto('/signin');
  await p2.getByLabel('Email').fill(email);
  await p2.getByLabel('Password').fill('pulse-test-123');
  await p2.getByRole('button', { name: 'Sign in' }).click();
  await p2.getByRole('link', { name: 'Settings' }).click();
  await expect(p2.locator('html')).toHaveAttribute('data-theme', 'light');
  await expect(p2.getByRole('switch', { name: /^Ghost Mode/ })).toBeChecked();
  await expect(p2.getByTestId('session-row')).toHaveCount(2);

  // "Sign out everywhere else" from device 2 removes device 1's session.
  await p2.getByRole('button', { name: 'Sign out everywhere else' }).click();
  await expect(p2.getByTestId('session-row')).toHaveCount(1);
  await ctx1.close(); await ctx2.close();
});
