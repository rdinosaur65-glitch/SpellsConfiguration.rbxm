import { expect, test, type Page } from '@playwright/test';
import { befriendUi, signUp, uniq } from './helpers';

// Needs the Edge Functions served: npx supabase functions serve --env-file supabase/functions/.env
const nav = (p: Page, name: string) => p.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: new RegExp(`^${name}`) });

// 4×4 PNG, generated once (solid colour) — a real image the browser can decode.
const PNG = Buffer.from(
  'iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEElEQVR4nGN44NAARwzEcQCqUhoBIWH54wAAAABJRU5ErkJggg==', 'base64');


async function imageLoaded(p: Page, testId: string) {
  const img = p.getByTestId(testId).last();
  await expect(img).toBeVisible();
  await expect(img).toHaveAttribute('src', /^blob:/);
  await expect.poll(() => img.evaluate((el) => (el as HTMLImageElement).naturalWidth)).toBeGreaterThan(0);
}

test('photos in chat and Snaps from the camera, through media-url', async ({ browser }) => {
  const ctxA = await browser.newContext(); const ctxB = await browser.newContext();
  const a = await ctxA.newPage(); const b = await ctxB.newPage();
  const ua = uniq('pia_'); const ub = uniq('pib_');
  await signUp(a, ua, 'Pia'); await signUp(b, ub, 'Ben');
  await befriendUi(a, b, ub, 'Pia');

  // Ben sends a photo; Pia sees it (fetched once through a ≤60 s signed URL).
  await b.getByTestId('friend-row').getByRole('button').first().click();
  await b.getByRole('button', { name: 'Chat settings' }).click();
  await b.getByRole('button', { name: 'Messages are kept' }).click();
  await b.getByTestId('photo-input').setInputFiles({ name: 'pic.png', mimeType: 'image/png', buffer: PNG });
  await expect(b.getByTestId('message').last()).not.toContainText('sending', { timeout: 15_000 });
  await expect(b.getByTestId('message').last()).not.toContainText('not sent');

  await nav(a, 'Chats').click();
  await a.getByTestId('chat-row').first().getByRole('link').click();
  await imageLoaded(a, 'chat-photo');

  // Pia takes a Snap with the camera and sends it to Ben with a 3-second timer.
  await a.getByRole('link', { name: 'Back to chats' }).click();
  await nav(a, 'Camera').click();
  await a.getByRole('button', { name: 'Open camera' }).click();
  await a.getByRole('button', { name: 'Take photo' }).click();
  await a.getByRole('button', { name: 'Send to…' }).click();
  await a.getByRole('checkbox', { name: 'Send to Ben' }).check();
  await a.getByRole('group', { name: 'Snap timer' }).getByRole('button', { name: '3s' }).click();
  await a.getByRole('button', { name: 'Send', exact: true }).click();
  await expect(a.getByText('Snap sent to 1 chat')).toBeVisible({ timeout: 15_000 });

  // Ben: the chat list says "New Snap"; he views it once, then replays it once.
  await b.getByRole('link', { name: 'Back to chats' }).click();
  await expect(b.getByTestId('chat-row').first()).toContainText('New Snap');
  await b.getByTestId('chat-row').first().getByRole('link').click();
  await b.getByTestId('snap-received').filter({ hasText: 'Tap to view Snap' }).click();
  await expect(b.getByTestId('snap-viewer')).toBeVisible();
  await imageLoaded(b, 'snap-image');
  await expect(b.getByTestId('snap-viewer')).toBeHidden({ timeout: 10_000 });   // timer ends the view
  await b.getByTestId('snap-received').filter({ hasText: 'Tap to replay' }).click();
  await imageLoaded(b, 'snap-image');
  await expect(b.getByTestId('snap-timer')).toContainText('replay');
  await b.getByRole('button', { name: 'Close' }).click();
  await expect(b.getByTestId('snap-received').last()).toHaveText(/Snap opened/);
  await expect(b.getByTestId('snap-received').last()).toBeDisabled();

  // Pia sees it was opened.
  await nav(a, 'Chats').click();
  await expect(a.getByTestId('chat-row').first()).toContainText('Opened');
  await a.getByTestId('chat-row').first().getByRole('link').click();
  await expect(a.getByTestId('snap-sent').last()).toContainText('Opened');

  await ctxA.close(); await ctxB.close();
});
