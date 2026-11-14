import { expect, test, type Page } from '@playwright/test';
import { befriendUi, signUp, uniq } from './helpers';

const nav = (p: Page, name: string) => p.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: new RegExp(`^${name}`) });

test('group: create, roles, remove, rename, hand over ownership and leave', async ({ browser }) => {
  const [ca, cb, cc] = await Promise.all([browser.newContext(), browser.newContext(), browser.newContext()]);
  const a = await ca.newPage(), b = await cb.newPage(), c = await cc.newPage();
  const ua = uniq('gow_'), ub = uniq('gbe_'), uc = uniq('gcy_');
  await signUp(a, ua, 'Olga'); await signUp(b, ub, 'Bert'); await signUp(c, uc, 'Cleo');
  await befriendUi(a, b, ub, 'Olga');
  await befriendUi(a, c, uc, 'Olga');

  // Olga creates the group from the Chats tab.
  await nav(a, 'Chats').click();
  await a.getByRole('button', { name: 'New group' }).click();
  await a.getByLabel('Group name').fill('Weekend crew');
  await a.getByRole('dialog', { name: 'New group' }).getByRole('checkbox').nth(0).check();
  await a.getByRole('dialog', { name: 'New group' }).getByRole('checkbox').nth(1).check();
  await a.getByRole('button', { name: 'Create group' }).click();
  await expect(a.getByTestId('chat-title')).toHaveText('Weekend crew');
  await a.getByLabel('Message').fill('welcome!');
  await a.getByRole('button', { name: 'Send', exact: true }).click();

  // Group info: three members, Olga is the owner.
  await a.getByRole('button', { name: 'Chat settings' }).click();
  await a.getByRole('link', { name: 'Group info and members' }).click();
  await expect(a.getByTestId('member-row')).toHaveCount(3);
  await expect(a.getByTestId('member-row').filter({ hasText: 'You' })).toContainText('Owner');

  // Make Bert an admin; remove Cleo.
  await a.getByRole('button', { name: `Manage ${ub}` }).click();
  await a.getByRole('button', { name: 'Make admin' }).click();
  await expect(a.getByTestId('member-row').filter({ hasText: ub })).toContainText('Admin');
  await a.getByRole('button', { name: `Manage ${uc}` }).click();
  a.once('dialog', (d) => d.accept());
  await a.getByRole('button', { name: 'Remove from group' }).click();
  await expect(a.getByTestId('member-row')).toHaveCount(2);
  await nav(c, 'Chats').click();
  await expect(c.getByText('No chats yet')).toBeVisible();

  // Rename.
  await a.getByRole('button', { name: 'Edit name and description' }).click();
  await a.getByLabel('Group name').fill('Weekend squad');
  await a.getByRole('button', { name: 'Save' }).click();
  await expect(a.getByTestId('group-name')).toHaveText('Weekend squad');

  // The owner must hand over ownership before leaving.
  await a.getByRole('button', { name: 'Leave group' }).click();
  await expect(a.getByText('Make someone else the owner first')).toBeVisible();
  await a.getByRole('button', { name: `Manage ${ub}` }).click();
  a.once('dialog', (d) => d.accept());
  await a.getByRole('button', { name: 'Make owner' }).click();
  await expect(a.getByTestId('member-row').filter({ hasText: ub })).toContainText('Owner');
  a.once('dialog', (d) => d.accept());
  await a.getByRole('button', { name: 'Leave group' }).click();
  await expect(a).toHaveURL(/\/chats$/);

  // Bert now owns the renamed group and sees just himself.
  await nav(b, 'Chats').click();
  await b.getByTestId('chat-row').filter({ hasText: 'Weekend squad' }).getByRole('link').click();
  await expect(b.getByTestId('messages')).toContainText('welcome!');
  await b.getByRole('button', { name: 'Chat settings' }).click();
  await b.getByRole('link', { name: 'Group info and members' }).click();
  await expect(b.getByTestId('member-row')).toHaveCount(1);
  await expect(b.getByTestId('member-row')).toContainText('Owner');

  await ca.close(); await cb.close(); await cc.close();
});
