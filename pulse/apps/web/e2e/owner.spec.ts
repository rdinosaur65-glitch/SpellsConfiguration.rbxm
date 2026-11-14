import { execFileSync } from 'node:child_process';
import { expect, test, type Page } from '@playwright/test';
import { signUp, uniq } from './helpers';

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

  // Non-owners cannot open the panel.
  await r.goto('/admin');
  await expect(r.getByText('Only the owner can open this page.')).toBeVisible();

  await co.close(); await cu.close(); await cr.close();
});
