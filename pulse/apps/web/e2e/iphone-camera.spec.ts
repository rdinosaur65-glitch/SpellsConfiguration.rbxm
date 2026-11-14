import { execFileSync } from 'node:child_process';
import { readFileSync } from 'node:fs';
import { fileURLToPath } from 'node:url';
import { expect, test, devices, type Page } from '@playwright/test';
import { befriendUi, signUp, uniq } from './helpers';

// On iPhone the Camera tab hands over to Apple's Camera app (a file input with `capture`);
// what it returns — a photo or a QuickTime video — comes back into PULSE as a Snap.
// This is a browser simulation with an iPhone user agent, not a real-device check.
const DB_URL = process.env.DB_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const sql = (q: string) => execFileSync('psql', [DB_URL, '-Atqc', q], { encoding: 'utf8' }).trim();
const PNG = Buffer.from('iVBORw0KGgoAAAANSUhEUgAAAAQAAAAECAIAAAAmkwkpAAAAEElEQVR4nGN44NAARwzEcQCqUhoBIWH54wAAAABJRU5ErkJggg==', 'base64');
const fixture = (f: string) => readFileSync(fileURLToPath(new URL(`./fixtures/${f}`, import.meta.url)));
const nav = (p: Page, name: string) => p.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: new RegExp(`^${name}`) });
const { defaultBrowserType: _ignored, ...iPhone } = devices['iPhone 14'];

async function sendTo(p: Page, friend: string) {
  await p.getByRole('button', { name: 'Send to…' }).click();
  await p.getByRole('checkbox', { name: `Send to ${friend}` }).check();
  await p.getByRole('button', { name: 'Send', exact: true }).click();
  await expect(p.getByText('Snap sent to 1 chat')).toBeVisible({ timeout: 20_000 });
}

test('iPhone: Camera opens the iPhone camera; its photo or video is sent as a Snap', async ({ browser }) => {
  test.setTimeout(120_000);
  const [ca, cb] = await Promise.all([browser.newContext(iPhone), browser.newContext()]);
  const a = await ca.newPage(), b = await cb.newPage();
  const ua = uniq('ia_'), ub = uniq('ib_');
  await signUp(a, ua, 'Ivy'); await signUp(b, ub, 'Ike');
  await befriendUi(a, b, ub, 'Ivy');

  await nav(a, 'Camera').click();
  await expect(a.getByText('Take a photo or video with your iPhone camera')).toBeVisible();
  await expect(a.getByRole('button', { name: 'Use the camera inside PULSE' })).toBeVisible();
  const input = a.getByTestId('camera-file');
  await expect(input).toHaveAttribute('capture', 'environment');
  await expect(input).toHaveAttribute('accept', 'image/*,video/*');
  // "Open camera" hands over to the system camera (here: the file chooser stands in for it).
  const chooser = a.waitForEvent('filechooser');
  await a.getByRole('button', { name: 'Open camera', exact: true }).click();
  await (await chooser).setFiles({ name: 'IMG_0001.png', mimeType: 'image/png', buffer: PNG });
  await expect(a.getByRole('img', { name: 'Captured' })).toBeVisible();
  await sendTo(a, 'Ike');

  // A video from the iPhone camera (QuickTime) is sent as a video Snap.
  await input.setInputFiles({ name: 'IMG_0002.MOV', mimeType: 'video/quicktime', buffer: fixture('iphone-clip.mov') });
  await expect(a.getByTestId('clip-preview')).toBeVisible();
  await a.getByRole('button', { name: 'Send to…' }).click();
  await expect(a.getByText(/^Video · 2\.0 s/)).toBeVisible();
  await a.keyboard.press('Escape');
  await sendTo(a, 'Ike');
  await expect.poll(() => sql(`select string_agg(s.media_kind || ':' || m.mime_type, ',' order by s.created_at) from public.snaps s
                join public.media_assets m on m.id = s.media_asset_id
                join public.profiles p on p.id = s.sender_id where p.username = '${ua}'`), { timeout: 20_000 }).toBe('photo:image/jpeg,video:video/mp4');

  // Longer than the video Snap limit: explained, nothing to send.
  await input.setInputFiles({ name: 'IMG_0003.MOV', mimeType: 'video/quicktime', buffer: fixture('iphone-long.mov') });
  await expect(a.getByText('Video Snaps can be up to 60 seconds')).toBeVisible();
  await expect(a.getByTestId('clip-preview')).toHaveCount(0);

  // Ike receives both Snaps.
  await nav(b, 'Chats').click();
  await b.getByTestId('chat-row').filter({ hasText: 'Ivy' }).getByRole('link').click();
  await expect(b.getByTestId('snap-received')).toHaveCount(2);
  await ca.close(); await cb.close();
});
