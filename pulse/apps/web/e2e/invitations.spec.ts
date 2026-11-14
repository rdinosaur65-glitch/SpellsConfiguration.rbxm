import { execFileSync } from 'node:child_process';
import { expect, test, type Page } from '@playwright/test';
import { enableTotp, linkFromEmail, PASSWORD, signUp, uniq } from './helpers';

const DB_URL = process.env.DB_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const sql = (q: string) => execFileSync('psql', [DB_URL, '-Atqc', q], { encoding: 'utf8' }).trim();
const nav = (p: Page, name: string) => p.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: new RegExp(`^${name}`) });

test.afterEach(() => {
  sql(`update private.platform_config set owner_user_id = null, registration_mode = 'invite_only'`);
});

async function openPanel(o: Page) {
  await nav(o, 'Settings').click();
  await o.getByRole('link', { name: 'Owner panel' }).click();
  await expect(o.getByTestId('invitations')).toBeVisible();
}
async function createInvite(o: Page, note: string, validFor = '7 days'): Promise<string> {
  await o.getByTestId('invitations').getByLabel('Valid for').selectOption({ label: validFor });
  await o.getByTestId('invitations').getByLabel(/Note/).fill(note);
  await o.getByRole('button', { name: 'Create invitation' }).click();
  const fresh = o.getByTestId('new-invitation');
  await expect(fresh).toContainText('/signup?invite=');
  return (await fresh.locator('span.small').textContent())!.trim();
}
async function fillSignUp(p: Page, username: string) {
  await p.getByLabel('Email').fill(`${username}@example.test`);
  await p.getByLabel('Username').fill(username);
  await p.getByLabel('Password').fill(PASSWORD);
}

test('invite-only registration: the owner invites, a friend joins once, nobody else can', async ({ browser }) => {
  test.setTimeout(120_000);
  const [co, cf, cx] = await Promise.all([browser.newContext(), browser.newContext(), browser.newContext()]);
  const o = await co.newPage(), f = await cf.newPage(), x = await cx.newPage();
  const uo = uniq('own_');
  const run = uniq('');                       // notes unique per run (the database is shared)
  const [SAM, KIM, LEE, MAX] = ['Sam', 'Kim', 'Lee', 'Max'].map((n) => `${n} ${run}`);
  await signUp(o, uo, 'Owner');
  sql(`update private.platform_config set owner_user_id = (select id from public.profiles where username = '${uo}')`);
  await o.reload();
  await enableTotp(o);
  await openPanel(o);
  await expect(o.getByTestId('registration').getByLabel(/Invite only/)).toBeChecked();   // the default

  // Without an invitation, nobody can sign up.
  await x.goto('/signup');
  await expect(x.getByTestId('invite-only')).toBeVisible();
  await fillSignUp(x, uniq('nope_'));
  await expect(x.getByRole('button', { name: 'Create account' })).toBeDisabled();
  await x.getByLabel('Invitation code').fill('zzzz-zzzz-zzzz');
  await expect(x.getByText('That invitation code doesn’t exist')).toBeVisible();
  await expect(x.getByRole('button', { name: 'Create account' })).toBeDisabled();

  // The owner creates an invitation; the friend opens the link and joins.
  const link = await createInvite(o, SAM);
  const path = new URL(link).pathname + new URL(link).search;
  const sam = uniq('sam_');
  await f.goto(path);
  await expect(f.getByText('Invitation accepted ✓')).toBeVisible();
  await fillSignUp(f, sam);
  await f.getByRole('button', { name: 'Create account' }).click();
  await expect(f.getByText('We sent a confirmation link')).toBeVisible();

  // Redeemed at once; shown as waiting for the email until confirmed.
  await o.reload();
  await o.getByRole('button', { name: /^Redeemed/ }).click();
  const redeemed = o.getByTestId('invitation-row').filter({ hasText: `@${sam}` });
  await expect(redeemed).toContainText('waiting for email confirmation');
  await expect(redeemed).toContainText(SAM);
  await f.goto(await linkFromEmail(`${sam}@example.test`, /verify your email/i));
  await expect(f.getByRole('navigation', { name: 'Main' })).toBeVisible();
  await o.reload();
  await o.getByRole('button', { name: /^Redeemed/ }).click();
  await expect(o.getByTestId('invitation-row').filter({ hasText: `@${sam}` })).not.toContainText('waiting');

  // The same link a second time: refused.
  await x.goto(path);
  await expect(x.getByText('That invitation has already been used')).toBeVisible();
  await fillSignUp(x, uniq('dup_'));
  await expect(x.getByRole('button', { name: 'Create account' })).toBeDisabled();

  // Revoked: the link stops working at once.
  const link2 = await createInvite(o, KIM);
  o.once('dialog', (d) => d.accept());
  await o.getByTestId('invitation-row').filter({ hasText: KIM }).getByRole('button', { name: 'Revoke' }).click();
  await expect(o.getByText('Invitation revoked')).toBeVisible();
  await o.getByRole('button', { name: /^Revoked/ }).click();
  await expect(o.getByTestId('invitation-row').filter({ hasText: KIM })).toHaveAttribute('data-status', 'revoked');
  await x.goto(new URL(link2).pathname + new URL(link2).search);
  await expect(x.getByText('That invitation was cancelled')).toBeVisible();

  // Expired (time moved forward in the database): refused, listed as expired.
  const link3 = await createInvite(o, LEE, '1 day');
  const code3 = new URL(link3).searchParams.get('invite')!.replace(/-/g, '');
  sql(`update private.invitations set expires_at = now() - interval '1 minute' where code = '${code3}'`);
  await x.goto(new URL(link3).pathname + new URL(link3).search);
  await expect(x.getByText('That invitation has expired')).toBeVisible();
  await o.reload();
  await o.getByRole('button', { name: /^Expired/ }).click();
  await expect(o.getByTestId('invitation-row').filter({ hasText: LEE })).toHaveAttribute('data-status', 'expired');

  // Pending ones are listed with their code until used.
  const link4 = await createInvite(o, MAX, '3 days');
  await o.getByRole('button', { name: /^Pending/ }).click();
  await expect(o.getByTestId('invitation-row').filter({ hasText: MAX })).toContainText(new URL(link4).searchParams.get('invite')!);

  // Public registration (owner switch), then back to invite only.
  o.once('dialog', (d) => d.accept());
  await o.getByTestId('registration').getByLabel(/Public registration/).check();
  await o.getByTestId('registration').getByRole('button', { name: 'Save' }).click();
  await expect(o.getByText('Public registration is on')).toBeVisible();
  const pub = uniq('pub_');
  await x.goto('/signup');
  await expect(x.getByTestId('invite-only')).toHaveCount(0);
  await fillSignUp(x, pub);
  await x.getByRole('button', { name: 'Create account' }).click();
  await expect(x.getByText('We sent a confirmation link')).toBeVisible();
  await o.getByTestId('registration').getByLabel(/Invite only/).check();
  await o.getByTestId('registration').getByRole('button', { name: 'Save' }).click();
  await expect(o.getByText('PULSE is invite-only')).toBeVisible();
  await x.goto('/signup');
  await expect(x.getByTestId('invite-only')).toBeVisible();

  await co.close(); await cf.close(); await cx.close();
});
