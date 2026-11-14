import { execFileSync } from 'node:child_process';
import { expect, test, type Page } from '@playwright/test';
import { emailText, enableTotp, freshTotp, PASSWORD, signUp, uniq } from './helpers';

const DB_URL = process.env.DB_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const sql = (q: string) => execFileSync('psql', [DB_URL, '-Atqc', q], { encoding: 'utf8' }).trim();
const nav = (p: Page, name: string) => p.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: new RegExp(`^${name}`) });

test.afterEach(() => { sql('update private.platform_config set owner_user_id = null'); });

test('owner panel: a report leads to a suspension, which takes effect at once and can be undone', async ({ browser }) => {
  const [co, cu, cr] = await Promise.all([browser.newContext(), browser.newContext(), browser.newContext()]);
  const o = await co.newPage(), u = await cu.newPage(), r = await cr.newPage();
  const uo = uniq('own_'), uu = uniq('trl_'), ur = uniq('rep_');
  await signUp(o, uo, 'Owner'); await signUp(u, uu, 'Troll'); await signUp(r, ur, 'Reporter');
  sql(`update private.platform_config set owner_user_id = (select id from public.profiles where username = '${uo}')`);

  // Owner powers need the owner's own 2FA.
  await o.reload();
  await nav(o, 'Settings').click();
  await o.getByRole('link', { name: 'Owner panel' }).click();
  await expect(o.getByText('Turn on two-step verification (Settings → Security) to use the owner panel.')).toBeVisible();
  await enableTotp(o);

  // A stranger reports the troll from search results.
  await nav(r, 'Friends').click();
  await r.getByLabel('Search by username').fill(uu);
  await r.getByRole('button', { name: `More options for ${uu}` }).click();
  await r.getByRole('button', { name: 'Report' }).click();
  await r.getByRole('button', { name: 'Spam' }).click();
  await r.getByRole('button', { name: 'Send report' }).click();
  await expect(r.getByText('Report sent. Thank you.')).toBeVisible();

  // The owner sees it (snapshot only) and suspends the account.
  await o.reload();
  await nav(o, 'Settings').click();
  await o.getByRole('link', { name: 'Owner panel' }).click();
  await expect(o.getByTestId('usage')).toContainText('Accounts');
  const report = o.getByTestId('report-row').filter({ hasText: `@${uu}` });
  await expect(report).toContainText('spam');
  o.once('dialog', (d) => d.accept('spam account'));
  await report.getByRole('button', { name: 'Suspend account' }).click();
  await expect(o.getByText('Account suspended')).toBeVisible();
  await expect(o.getByTestId('report-row').filter({ hasText: `@${uu}` })).toHaveCount(0);   // moved to "actioned"

  // Immediately effective for the suspended user, even with a still-valid token.
  await u.reload();
  await expect(u.getByText('This account is suspended')).toBeVisible();

  // Restore.
  await o.getByLabel('Search accounts').fill(uu);
  const row = o.getByTestId('admin-user-row').filter({ hasText: `@${uu}` });
  await expect(row).toContainText('suspended');
  o.once('dialog', (d) => d.accept('appeal accepted'));
  await row.getByRole('button', { name: 'Restore' }).click();
  await expect(row).toContainText('active');
  await expect(o.getByTestId('audit-row').first()).toContainText('account.set_state');

  // An app error on someone's phone shows up in the owner's error list.
  await u.evaluate(() => { setTimeout(() => { throw new Error('boom from a test phone'); }, 0); });
  await expect.poll(() => sql(`select count(*) from private.client_errors e join public.profiles p on p.id = e.user_id
                                 where p.username = '${uu}' and e.message like '%boom from a test phone%'`)).toBe('1');
  await o.reload();
  await expect(o.getByTestId('error-row').filter({ hasText: 'boom from a test phone' }).filter({ hasText: `@${uu}` })).toHaveCount(1);
  // The commonest real crash, a TypeError, is reported too.
  await u.evaluate(() => { setTimeout(() => { (null as unknown as { x: { y: number } }).x.y = 1; }, 0); });
  await expect.poll(() => sql(`select count(*) from private.client_errors e join public.profiles p on p.id = e.user_id
                                 where p.username = '${uu}' and e.message like '%null%'`)).toBe('1');

  // Non-owners cannot open the panel.
  await r.goto('/admin');
  await expect(r.getByText('Only the owner can open this page.')).toBeVisible();

  await co.close(); await cu.close(); await cr.close();
});

test('owner panel: resetting someone\'s 2FA needs a code emailed to the owner', async ({ browser }) => {
  test.setTimeout(120_000);
  const [co, ct] = await Promise.all([browser.newContext(), browser.newContext()]);
  const o = await co.newPage(), t = await ct.newPage();
  const uo = uniq('own_'), ut = uniq('lost_');
  const ownerEmail = await signUp(o, uo, 'Owner');
  const targetEmail = await signUp(t, ut, 'Lost Phone');
  sql(`update private.platform_config set owner_user_id = (select id from public.profiles where username = '${uo}')`);
  const targetId = sql(`select id from public.profiles where username = '${ut}'`);
  const { secret, step } = await enableTotp(o);
  sql(`insert into auth.mfa_factors (id, user_id, friendly_name, factor_type, status, created_at, updated_at)
       values (gen_random_uuid(), '${targetId}', 'phone', 'totp', 'verified', now(), now())`);

  await o.reload();
  await nav(o, 'Settings').click();
  await o.getByRole('link', { name: 'Owner panel' }).click();
  await o.getByLabel('Search accounts').fill(ut);
  await o.getByTestId('admin-user-row').filter({ hasText: `@${ut}` }).getByRole('button', { name: 'Reset 2FA' }).click();

  // Fresh sign-in first; a wrong password goes nowhere.
  const sheet = o.getByRole('dialog', { name: `Reset two-step verification for ${ut}` });
  await sheet.getByLabel('Reason (kept in the audit log)').fill('lost phone, confirmed by call');
  await sheet.getByLabel('Your password').fill('not-my-password-1');
  await sheet.getByRole('button', { name: 'Continue' }).click();
  await expect(sheet.getByRole('alert')).toBeVisible();
  const started = Date.now() - 1000;
  await sheet.getByLabel('Your password').fill(PASSWORD);
  await sheet.getByRole('button', { name: 'Continue' }).click();
  // …then the owner's own second factor.
  await sheet.getByLabel('Code from your authenticator app').fill(await freshTotp(o, secret, step));
  await sheet.getByRole('button', { name: 'Continue' }).click();
  await expect(sheet.getByText('We emailed a 6-digit code to your owner email address')).toBeVisible();

  // The code goes to the owner's address only; the page never sees it.
  const text = await emailText(ownerEmail, /security verification/i, started);
  const code = /Verification code: (\d{6})/.exec(text)?.[1] ?? '';
  expect(code).toMatch(/^\d{6}$/);
  expect(await o.content()).not.toContain(code);

  // A wrong code changes nothing.
  await sheet.getByLabel('Code from the email').fill(code === '000000' ? '111111' : '000000');
  await sheet.getByRole('button', { name: 'Reset two-step verification' }).click();
  await expect(sheet.getByText('That code is not right. 4 attempt(s) left.')).toBeVisible();
  expect(sql(`select count(*) from auth.mfa_factors where user_id = '${targetId}'`)).toBe('1');

  // The right one resets it, signs the target out and tells them (without the owner's address).
  await sheet.getByLabel('Code from the email').fill(code);
  await sheet.getByRole('button', { name: 'Reset two-step verification' }).click();
  await expect(o.getByText(`Two-step verification reset for @${ut}. They were emailed.`)).toBeVisible();
  expect(sql(`select count(*) from auth.mfa_factors where user_id = '${targetId}'`)).toBe('0');
  expect(sql(`select count(*) from auth.sessions where user_id = '${targetId}'`)).toBe('0');
  const notice = await emailText(targetEmail, /two-step verification was reset/i, started);
  expect(notice).not.toContain(ownerEmail);
  await expect(o.getByTestId('audit-row').first()).toContainText('account.mfa_reset.');

  await co.close(); await ct.close();
});
