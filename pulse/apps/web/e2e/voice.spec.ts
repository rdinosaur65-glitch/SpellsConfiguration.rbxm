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

test('voice messages: record, send, and play on the other phone', async ({ browser }) => {
  // The browser's fake microphone (playwright.config.ts) produces a test tone.
  const [ca, cb] = await Promise.all([browser.newContext({ permissions: ['microphone'] }), browser.newContext({ permissions: ['microphone'] })]);
  await cb.addInitScript(trackMics);
  const a = await ca.newPage(), b = await cb.newPage();
  const ua = uniq('vca_'), ub = uniq('vcb_');
  await signUp(a, ua, 'Amy'); await signUp(b, ub, 'Ben');
  await befriendUi(a, b, ub, 'Amy');
  await b.getByTestId('friend-row').getByRole('button').first().click();
  await b.getByRole('button', { name: 'Chat settings' }).click();
  await b.getByRole('button', { name: 'Messages are kept' }).click();
  const conv = b.url().split('/chats/')[1]!;

  // A double tap while the microphone opens starts only one recording; Cancel releases the mic.
  await b.evaluate(() => { (window as unknown as { __micDelay: number }).__micDelay = 800; });
  await b.getByRole('button', { name: 'Record a voice note' }).click();
  await b.getByRole('button', { name: 'Record a voice note' }).click({ force: true }).catch(() => {});
  await expect(b.getByTestId('voice-recording')).toBeVisible();
  await b.getByRole('button', { name: 'Cancel' }).click();
  await expect.poll(() => liveMics(b)).toBe(0);
  await b.evaluate(() => { (window as unknown as { __micDelay: number }).__micDelay = 0; });

  // Cancel discards it; nothing is sent.
  await b.getByRole('button', { name: 'Record a voice note' }).click();
  await expect(b.getByTestId('voice-recording')).toContainText('Recording');
  await b.getByRole('button', { name: 'Cancel' }).click();
  await expect(b.getByTestId('voice-recording')).toHaveCount(0);
  await expect.poll(() => liveMics(b)).toBe(0);

  await b.getByRole('button', { name: 'Record a voice note' }).click();
  await expect(b.getByTestId('voice-recording')).toContainText('Recording 0:01', { timeout: 5000 });
  await b.getByRole('button', { name: 'Send voice note' }).click();
  const mine = b.getByTestId('message').last();
  await expect(mine.getByTestId('voice-audio')).toBeVisible();          // plays from the phone's own copy
  await expect(mine).not.toContainText('sending', { timeout: 15_000 });
  await expect(mine).not.toContainText('not sent');
  await expect.poll(() => liveMics(b)).toBe(0);                          // microphone off after sending
  const row = sql(`select a.mime_type || '|' || (a.duration_seconds > 0) || '|' || (a.byte_size > 0)
                     from public.messages m join public.media_assets a on a.id = m.media_asset_id
                    where m.conversation_id = '${conv}' and m.kind = 'voice'`);
  expect(row).toMatch(/^audio\/(webm|mp4|ogg)\|true\|true$/);
  expect(sql(`select count(*) from public.messages where conversation_id = '${conv}' and kind = 'voice'`)).toBe('1');   // nothing from the cancelled ones

  // Amy taps play: it downloads through media-url and plays.
  await nav(a, 'Chats').click();
  await a.getByTestId('chat-row').first().getByRole('link').click();
  await a.getByRole('button', { name: 'Play voice note from ben' }).click();
  const audio = a.getByTestId('voice-audio');
  await expect(audio).toBeVisible();
  await expect.poll(() => audio.evaluate((el: HTMLAudioElement) => el.src.startsWith('blob:') && el.readyState >= 1)).toBe(true);
  await ca.close(); await cb.close();
});
