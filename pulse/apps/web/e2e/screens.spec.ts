import { expect, test } from '@playwright/test';
import { signUp, uniq } from './helpers';

// Visual review helper: SCREENSHOTS=<dir> npx playwright test screens
const dir = process.env.SCREENSHOTS;
test.skip(!dir, 'set SCREENSHOTS=<dir> to capture screens');

test('capture key screens', async ({ browser }) => {
  const a = await (await browser.newContext()).newPage();
  const b = await (await browser.newContext()).newPage();
  await a.goto('/signin');
  await a.screenshot({ path: `${dir}/01-signin.png` });
  await a.goto('/signup');
  await a.screenshot({ path: `${dir}/02-signup.png` });
  const ua = uniq('maya_'); const ub = uniq('leo_');
  await signUp(a, ua, 'Maya Chen');
  await signUp(b, ub, 'Leo Park');
  await a.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: /^Friends/ }).click();
  await a.getByLabel('Search by username').fill(ub);
  await a.getByRole('button', { name: `Add @${ub}` }).click();
  await b.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: /^Friends/ }).click();
  await expect(b.getByTestId('incoming-request')).toBeVisible();
  await b.screenshot({ path: `${dir}/03-friend-request.png` });
  await b.getByTestId('incoming-request').getByRole('button', { name: 'Accept' }).click();
  await b.getByTestId('friend-row').getByRole('button').first().click();
  await b.getByRole('button', { name: 'Chat settings' }).click();
  await b.getByRole('button', { name: 'Messages are kept' }).click();
  for (const t of ['Hey! Are we still on for Saturday?', 'Yes!! 10am at the park 🌳', 'Bring the frisbee']) {
    await b.getByLabel('Message').fill(t); await b.getByLabel('Message').press('Enter');
  }
  await a.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: /^Chats/ }).click();
  await expect(a.getByTestId('chat-row')).toContainText('New Chat');
  await a.screenshot({ path: `${dir}/04-chat-list.png` });
  await a.getByTestId('chat-row').getByRole('link').click();
  await a.getByLabel('Message').fill('Can’t wait. I’ll bring snacks too');
  await a.getByLabel('Message').press('Enter');
  await expect(a.getByTestId('message')).toHaveCount(4);
  await a.screenshot({ path: `${dir}/05-chat.png` });
  await a.getByRole('link', { name: 'Back to chats' }).click();
  await a.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Settings' }).click();
  await a.screenshot({ path: `${dir}/06-settings.png`, fullPage: false });
  await a.getByRole('group', { name: 'Theme' }).getByRole('button', { name: 'Light' }).click();
  await a.getByRole('button', { name: 'Accent #EC4899' }).click();
  await a.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: /^Chats/ }).click();
  await a.getByTestId('chat-row').getByRole('link').click();
  await expect(a.getByTestId('chat-title')).toHaveText('Leo Park');
  await expect(a.getByTestId('message').first()).toBeVisible();
  await a.screenshot({ path: `${dir}/07-chat-light.png` });
  await a.getByRole('link', { name: 'Back to chats' }).click();
  await a.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: 'Camera' }).click();
  await a.screenshot({ path: `${dir}/08-camera.png` });
});
