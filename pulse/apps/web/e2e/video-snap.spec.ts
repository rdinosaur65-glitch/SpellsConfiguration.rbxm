import { execFileSync } from 'node:child_process';
import { expect, test, type Page } from '@playwright/test';
import { befriendUi, signUp, uniq } from './helpers';

const DB_URL = process.env.DB_URL ?? 'postgresql://postgres:postgres@127.0.0.1:54322/postgres';
const sql = (q: string) => execFileSync('psql', [DB_URL, '-Atqc', q], { encoding: 'utf8' }).trim();
const trackMics = `(() => {
  const real = navigator.mediaDevices.getUserMedia.bind(navigator.mediaDevices);
  window.__mics = [];
  navigator.mediaDevices.getUserMedia = async (c) => {
    if (c && c.audio && !c.video) await new Promise((r) => setTimeout(r, window.__micDelay || 0));
    const s = await real(c);
    if (c && c.audio) window.__mics.push(...s.getAudioTracks());
    return s;
  };
})();`;
const liveMics = (p: Page) => p.evaluate(() => ((window as unknown as { __mics: MediaStreamTrack[] }).__mics ?? []).filter((t) => t.readyState === 'live').length);
const nav = (p: Page, name: string) => p.getByRole('navigation', { name: 'Main' }).getByRole('link', { name: new RegExp(`^${name}`) });

test('video Snaps: hold the shutter to record, the friend watches it once', async ({ browser }) => {
  test.setTimeout(90_000);
  // Fake camera and microphone (playwright.config.ts).
  const [ca, cb] = await Promise.all([
    browser.newContext({ permissions: ['camera', 'microphone'] }), browser.newContext()]);
  await ca.addInitScript(trackMics);
  const a = await ca.newPage(), b = await cb.newPage();
  const ua = uniq('vsa_'), ub = uniq('vsb_');
  await signUp(a, ua, 'Amy'); await signUp(b, ub, 'Ben');
  await befriendUi(a, b, ub, 'Amy');

  await nav(a, 'Camera').click();
  await a.getByRole('button', { name: 'Open camera' }).click();
  const shutter = a.getByRole('button', { name: /^Take photo/ });
  // Let go while the microphone is still opening: nothing is recorded and the mic is released.
  await a.evaluate(() => { (window as unknown as { __micDelay: number }).__micDelay = 1500; });
  await shutter.hover();
  await a.mouse.down();
  await a.waitForTimeout(600);
  await a.mouse.up();
  await a.waitForTimeout(2500);
  await expect(a.getByTestId('clip-recording')).toHaveCount(0);
  await expect(a.getByTestId('clip-preview')).toHaveCount(0);
  expect(await liveMics(a)).toBe(0);
  await a.evaluate(() => { (window as unknown as { __micDelay: number }).__micDelay = 0; });

  await shutter.hover();
  await a.mouse.down();
  await expect(a.getByTestId('clip-recording')).toContainText('2s', { timeout: 6000 });
  await a.mouse.up();
  await expect(a.getByTestId('clip-preview')).toBeVisible();
  await expect.poll(() => liveMics(a)).toBe(0);                          // microphone off once recorded
  await a.getByRole('button', { name: 'Send to…' }).click();
  await expect(a.getByText(/^Video · \d+\.\d s/)).toBeVisible();
  await expect(a.getByRole('group', { name: 'Snap timer' })).toHaveCount(0);   // a video plays its own length
  await a.getByRole('checkbox', { name: 'Send to Ben' }).check();
  await a.getByRole('button', { name: 'Send', exact: true }).click();
  await expect(a.getByText('Snap sent to 1 chat')).toBeVisible({ timeout: 20_000 });
  const snap = sql(`select media_kind || '|' || (video_seconds between 1.5 and 15) from public.snaps s
                      join public.profiles p on p.id = s.sender_id where p.username = '${ua}'`);
  expect(snap).toBe('video|true');

  // Ben opens it: it plays, then closes by itself when it ends; no replay timer for videos.
  await nav(b, 'Chats').click();
  await b.getByTestId('chat-row').first().getByRole('link').click();
  await b.getByTestId('snap-received').filter({ hasText: 'Tap to view Snap' }).click();
  const video = b.getByTestId('snap-video');
  await expect(video).toBeVisible();
  await expect.poll(() => video.evaluate((el: HTMLVideoElement) => el.currentTime > 0.2 || el.ended), { timeout: 10_000 }).toBe(true);
  await expect(b.getByTestId('snap-viewer')).toBeHidden({ timeout: 20_000 });
  await expect(b.getByTestId('snap-received').first()).toContainText(/replay|opened/i);
  await ca.close(); await cb.close();
});
