import { execFileSync } from 'node:child_process';
import { expect, type Page } from '@playwright/test';
import { totp } from './totp';

const MAILPIT = process.env.MAILPIT_URL ?? 'http://127.0.0.1:54324';
export const PASSWORD = 'pulse-test-123';
const DB_URL = process.env.DB_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const psql = (q: string) => execFileSync('psql', [DB_URL, '-Atqc', q], { encoding: 'utf8' }).trim();

/** A fresh invitation code, as the owner would create it (registration is invite-only). */
export function newInvite(validFor = "interval '1 day'"): string {
  return psql(`insert into private.invitations (code, expires_at) values (private.new_invite_code(), now() + ${validFor}) returning code`);
}

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

/** Wait for an email to `to` whose subject matches and that arrived after `afterMs`; return its text. */
export async function emailText(to: string, subject: RegExp, afterMs = 0): Promise<string> {
  for (let i = 0; i < 40; i++) {
    const res = await fetch(`${MAILPIT}/api/v1/search?query=${encodeURIComponent(`to:"${to}"`)}`);
    const list = (await res.json()) as { messages: Array<{ ID: string; Subject: string; Created: string }> };
    const msg = list.messages.find((m) => subject.test(m.Subject) && Date.parse(m.Created) >= afterMs);
    if (msg) return ((await (await fetch(`${MAILPIT}/api/v1/message/${msg.ID}`)).json()) as { Text: string }).Text;
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
  await page.goto(`/signup?invite=${newInvite()}`);
  await expect(page.getByText('Invitation accepted ✓')).toBeVisible();
  await page.getByLabel('Email').fill(email);
  await page.getByLabel('Username').fill(username);
  await page.getByLabel('Display name (optional)').fill(displayName);
  await page.getByLabel('Password').fill(PASSWORD);
  await page.getByRole('button', { name: 'Create account' }).click();
  await expect(page.getByText('We sent a confirmation link')).toBeVisible();
  const link = await linkFromEmail(email, /verify your email/i);
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

/** Turns on two-step verification from Settings; returns the secret and the time step used. */
export async function enableTotp(page: Page): Promise<{ secret: string; step: number }> {
  await page.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: /^Settings/ }).click();
  await page.getByRole('button', { name: 'Set up two-step verification' }).click();
  const secret = (await page.locator('code').first().textContent())!.trim();
  const step = Math.floor(Date.now() / 30_000);
  await page.getByLabel('6-digit code').fill(totp(secret));
  await page.getByRole('button', { name: 'Verify and turn on' }).click();
  await expect(page.getByText(/On — codes from your authenticator app/)).toBeVisible();
  return { secret, step };
}

/** A TOTP code from a later time step than `after` (servers refuse a reused step). */
export async function freshTotp(page: Page, secret: string, after: number): Promise<string> {
  const wait = (after + 1) * 30_000 - Date.now();
  if (wait > 0) await page.waitForTimeout(wait + 500);
  return totp(secret);
}
