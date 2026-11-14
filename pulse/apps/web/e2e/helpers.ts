import { expect, type Page } from '@playwright/test';

const MAILPIT = process.env.MAILPIT_URL ?? 'http://127.0.0.1:54324';
export const PASSWORD = 'pulse-test-123';

export function uniq(prefix: string): string {
  return `${prefix}${Date.now().toString(36)}${Math.floor(Math.random() * 1e4)}`.slice(0, 20);
}

/** Wait for the newest email to `to` whose subject matches, and return the first link in it. */
export async function linkFromEmail(to: string, subject: RegExp): Promise<string> {
  for (let i = 0; i < 40; i++) {
    const res = await fetch(`${MAILPIT}/api/v1/search?query=${encodeURIComponent(`to:"${to}"`)}`);
    const list = (await res.json()) as { messages: Array<{ ID: string; Subject: string }> };
    const msg = list.messages.find((m) => subject.test(m.Subject));
    if (msg) {
      const full = (await (await fetch(`${MAILPIT}/api/v1/message/${msg.ID}`)).json()) as { HTML: string; Text: string };
      const m = /href="([^"]+)"/.exec(full.HTML) ?? /(https?:\/\/\S+)/.exec(full.Text);
      if (m?.[1]) return m[1].replace(/&amp;/g, '&');
    }
    await new Promise((r) => setTimeout(r, 500));
  }
  throw new Error(`no email "${subject}" for ${to}`);
}

export async function hasEmail(to: string, subject: RegExp): Promise<boolean> {
  for (let i = 0; i < 20; i++) {
    const res = await fetch(`${MAILPIT}/api/v1/search?query=${encodeURIComponent(`to:"${to}"`)}`);
    const list = (await res.json()) as { messages: Array<{ Subject: string }> };
    if (list.messages.some((m) => subject.test(m.Subject))) return true;
    await new Promise((r) => setTimeout(r, 500));
  }
  return false;
}

/** Full sign-up through the UI, including the emailed confirmation link. Ends signed in. */
export async function signUp(page: Page, username: string, displayName: string): Promise<string> {
  const email = `${username}@example.test`;
  await page.goto('/signup');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Username').fill(username);
  await page.getByLabel('Display name (optional)').fill(displayName);
  await page.getByLabel('Password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Create account' }).click();
  await expect(page.getByText('We sent a confirmation link')).toBeVisible();
  const link = await linkFromEmail(email, /confirm/i);
  await page.goto(link);
  await expect(page.getByRole('navigation', { name: 'Main' })).toBeVisible();
  return email;
}

export async function signIn(page: Page, email: string, password = PASSWORD): Promise<void> {
  await page.goto('/signin');
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Password').fill(password);
  await page.getByRole('button', { name: 'Sign in' }).click();
}

const mainNav = (p: Page, name: string) => p.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: new RegExp(`^${name}`) });

/** `a` sends a friend request to username `ub`; page `b` accepts it. */
export async function befriendUi(a: Page, b: Page, ub: string, aDisplayName: string): Promise<void> {
  await mainNav(a, 'Friends').click();
  await a.getByLabel('Search by username').fill(ub);
  await a.getByRole('button', { name: `Add @${ub}` }).click();
  await expect(a.getByText('Requested')).toBeVisible();
  await mainNav(b, 'Friends').click();
  await b.getByTestId('incoming-request').filter({ hasText: aDisplayName }).getByRole('button', { name: 'Accept' }).click();
  await expect(b.getByTestId('friend-row').filter({ hasText: aDisplayName })).toBeVisible();
}
