import { expect, test } from '@playwright/test';
import { hasEmail, signIn, signUp, uniq } from './helpers';
import { totp } from './totp';

test('two-step verification: enroll, then required at sign-in', async ({ page }) => {
  const email = await signUp(page, uniq('mfa_'), 'Two Step');
  await page.getByRole('link', { name: 'Settings' }).click();
  await page.getByRole('button', { name: 'Set up two-step verification' }).click();
  await expect(page.getByAltText('Authenticator QR code')).toBeVisible();
  const secret = (await page.locator('code').first().textContent())!.trim();
  await page.getByLabel('6-digit code').fill(totp(secret));
  await page.getByRole('button', { name: 'Verify and turn on' }).click();
  await expect(page.getByText(/On — codes from your authenticator app/)).toBeVisible();
  expect(await hasEmail(email, /two-step verification was turned on/i)).toBe(true);

  await page.getByRole('button', { name: 'Sign out' }).click();
  await signIn(page, email);
  // Password alone is not enough: the app asks for the code (and the API refuses aal1, see test 90).
  await expect(page.getByText('Two-step verification')).toBeVisible();
  await page.getByLabel('Code from your authenticator app').fill('000000');
  await page.getByRole('button', { name: 'Verify' }).click();
  await expect(page.getByRole('alert')).toContainText('didn’t work');
  await page.getByLabel('Code from your authenticator app').fill(totp(secret));
  await page.getByRole('button', { name: 'Verify' }).click();
  await expect(page.getByRole('navigation', { name: 'Main' })).toBeVisible();
  await page.getByRole('link', { name: 'Settings' }).click();
  await expect(page.getByTestId('my-username')).toBeVisible();
});

test('an account with two-step verification can delete itself (password + code)', async ({ page }) => {
  const email = await signUp(page, uniq('del_'), 'Leaving');
  await page.getByRole('link', { name: 'Settings' }).click();
  await page.getByRole('button', { name: 'Set up two-step verification' }).click();
  const secret = (await page.locator('code').first().textContent())!.trim();
  const enrolledStep = Math.floor(Date.now() / 30_000);
  await page.getByLabel('6-digit code').fill(totp(secret));
  await page.getByRole('button', { name: 'Verify and turn on' }).click();
  await expect(page.getByText(/On — codes from your authenticator app/)).toBeVisible();

  await page.getByRole('button', { name: 'Delete my account' }).click();
  await page.getByLabel('Enter your password to confirm').fill('pulse-test-123');
  await page.getByRole('button', { name: 'Permanently delete account' }).click();
  // The dialog stays put (the global 2FA prompt must not replace it) and asks for the code.
  await expect(page.getByLabel('Code from your authenticator app')).toBeVisible();
  // Use a fresh time step so the enrollment code is not replayed.
  const wait = (enrolledStep + 1) * 30_000 - Date.now();
  if (wait > 0) await page.waitForTimeout(wait + 500);
  await page.getByLabel('Code from your authenticator app').fill(totp(secret));
  await page.getByRole('button', { name: 'Confirm and delete' }).click();
  await expect(page.getByRole('button', { name: 'Sign in' })).toBeVisible();

  await signIn(page, email);
  await expect(page.getByRole('alert')).toContainText(/suspended or is being deleted|Wrong email or password/);
});

test('installed app opens offline from the service worker', async ({ page, context }) => {
  await signUp(page, uniq('off_'), 'Offline');
  await page.getByRole('link', { name: 'Settings' }).click();
  await expect(page.getByTestId('my-username')).toBeVisible();
  // The service worker installs on first visit and controls the page from the next load,
  // like reopening an installed app.
  await page.evaluate(async () => { await navigator.serviceWorker.ready; });
  await page.reload();
  await page.waitForFunction(() => navigator.serviceWorker.controller !== null, null, { timeout: 15_000 });
  await context.setOffline(true);
  await page.reload();
  await expect(page.getByText("You're offline")).toBeVisible();
  await expect(page.getByRole('navigation', { name: 'Main' })).toBeVisible();
  await expect(page.getByTestId('my-username')).toBeVisible();     // from the local profile copy
  await page.getByRole('link', { name: /^Chats/ }).click();
  await expect(page.getByRole('alert')).toContainText('offline');
  await context.setOffline(false);
});
