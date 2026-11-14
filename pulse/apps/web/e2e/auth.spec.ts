import { expect, test } from '@playwright/test';
import { PASSWORD, hasEmail, linkFromEmail, signIn, signUp, uniq } from './helpers';

test('sign-up requires email confirmation, then signs in', async ({ page }) => {
  const username = uniq('ann_');
  const email = `${username}@example.test`;
  // Before confirming, sign-in is refused.
  await page.goto('/signup');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Username').fill(username);
  await page.getByLabel('Password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Create account' }).click();
  await expect(page.getByText('We sent a confirmation link')).toBeVisible();
  await signIn(page, email);
  await expect(page.getByRole('alert')).toContainText('confirm your email');

  await page.goto(await linkFromEmail(email, /confirm/i));
  await expect(page.getByRole('navigation', { name: 'Main' })).toBeVisible();
  await page.getByRole('link', { name: 'Settings' }).click();
  await expect(page.getByTestId('my-username')).toHaveText(`@${username}`);
});

test('username rules are checked client-side and server-side', async ({ page }) => {
  const taken = uniq('tk_');
  await signUp(page, taken, 'Taken');
  await page.getByRole('link', { name: 'Settings' }).click();
  await page.getByRole('button', { name: 'Sign out' }).click();

  await page.goto('/signup');
  await page.getByLabel('Username').fill('ab');
  await page.getByLabel('Username').blur();
  await expect(page.getByText(/Usernames are 3–20 characters/)).toBeVisible();
  await page.getByLabel('Username').fill('admin');
  await expect(page.getByText('That username is reserved')).toBeVisible();

  // Taken usernames are only known to the server (no anonymous username lookup API).
  await page.getByLabel('Email').fill(`${uniq('x_')}@example.test`);
  await page.getByLabel('Username').fill(taken);
  await page.getByLabel('Password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Create account' }).click();
  await expect(page.getByRole('alert')).toHaveText(/username (is|may be) taken/);
});

test('password reset by email', async ({ page }) => {
  const username = uniq('rs_');
  const email = await signUp(page, username, 'Reset Me');
  await page.getByRole('link', { name: 'Settings' }).click();
  await page.getByRole('button', { name: 'Sign out' }).click();

  await page.goto('/forgot');
  await page.getByLabel('Email').fill(email);
  await page.getByRole('button', { name: 'Send reset link' }).click();
  await expect(page.getByText('a reset link is on its way')).toBeVisible();
  await page.goto(await linkFromEmail(email, /reset/i));
  await page.getByLabel('New password').fill('brand-new-pass-9');
  await page.getByRole('button', { name: 'Save password' }).click();
  await expect(page.getByRole('navigation', { name: 'Main' })).toBeVisible();
  expect(await hasEmail(email, /password was changed/i)).toBe(true);   // security alert

  await page.getByRole('link', { name: 'Settings' }).click();
  await page.getByRole('button', { name: 'Sign out' }).click();
  await signIn(page, email, 'brand-new-pass-9');
  await expect(page.getByRole('navigation', { name: 'Main' })).toBeVisible();
});

test('privacy notice is reachable before signing up', async ({ page }) => {
  await page.goto('/signup');
  await page.getByRole('link', { name: 'privacy notice and rules' }).click();
  await expect(page.getByRole('heading', { name: 'Privacy and rules' })).toBeVisible();
  await expect(page.getByText(/cannot read your chats, Snaps or photos/)).toBeVisible();
  await expect(page.getByText(/not end-to-end encrypted/)).toBeVisible();
});
