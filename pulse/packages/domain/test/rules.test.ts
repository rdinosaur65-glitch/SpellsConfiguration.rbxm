import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { AUDIO_MIME, LIMITS, MB, PHOTO_MIME, VIDEO_MIME } from '../src/limits.ts';
import {
  canEditMessage, nextUsernameChangeAt, remainingClipBudget, remainingViewMs, sha256Hex,
  splitIntoStorySegments, storageState, validateMedia, validateSnapTimer, validateUsername,
} from '../src/rules.ts';

test('usernames', () => {
  assert.deepEqual(validateUsername('  Alice_99 '), { ok: true, value: 'alice_99' });
  for (const bad of ['ab', 'a'.repeat(21), '_alice', 'alice.', 'al__ice', 'al ice', 'ålice']) {
    assert.equal(validateUsername(bad).ok, false, bad);
  }
  assert.deepEqual(validateUsername('Admin'), { ok: false, error: 'username_reserved', detail: undefined });
});

test('username cooldown: 48 h, owner exempt', () => {
  const last = new Date('2026-11-14T00:00:00Z');
  assert.ok(nextUsernameChangeAt(last, new Date('2026-11-15T00:00:00Z'), false));
  assert.equal(nextUsernameChangeAt(last, new Date('2026-11-16T00:00:01Z'), false), null);
  assert.equal(nextUsernameChangeAt(last, new Date('2026-11-14T00:01:00Z'), true), null);
  assert.equal(nextUsernameChangeAt(null, new Date(), false), null);
});

test('snap timer: whole seconds 1..10 or unlimited', () => {
  for (const s of [1, 5, 10]) assert.ok(validateSnapTimer({ kind: 'seconds', seconds: s }).ok);
  for (const s of [0, 11, 2.5, -1]) assert.equal(validateSnapTimer({ kind: 'seconds', seconds: s }).ok, false);
  assert.ok(validateSnapTimer({ kind: 'unlimited' }).ok);
  assert.equal(remainingViewMs(new Date(1000), new Date(5000)), 0);
});

test('media limits', () => {
  assert.ok(validateMedia({ purpose: 'snap', mime: 'video/mp4', bytes: 10 * MB, durationSeconds: 60 }).ok);
  assert.equal(validateMedia({ purpose: 'snap', mime: 'video/mp4', bytes: 10 * MB, durationSeconds: 60.5 }).ok, false);
  assert.ok(validateMedia({ purpose: 'memory_backup', mime: 'video/webm', bytes: 40 * MB, durationSeconds: 300 }).ok);
  assert.equal(validateMedia({ purpose: 'memory_backup', mime: 'video/webm', bytes: 40 * MB, durationSeconds: 301 }).ok, false);
  assert.equal(validateMedia({ purpose: 'chat', mime: 'image/jpeg', bytes: 6 * MB }).ok, false);
  assert.equal(validateMedia({ purpose: 'chat', mime: 'image/svg+xml', bytes: 100 }).ok, false);
  assert.equal(validateMedia({ purpose: 'profile', mime: 'video/mp4', bytes: 100, durationSeconds: 1 }).ok, false);
  assert.equal(validateMedia({ purpose: 'snap', mime: 'audio/webm', bytes: 100, durationSeconds: 1 }).ok, false);
});

test('multi-clip budget and story splitting', () => {
  assert.equal(remainingClipBudget([20, 25]), 15);
  assert.equal(remainingClipBudget([40, 30]), 0);
  assert.deepEqual(splitIntoStorySegments(135), [[0, 60], [60, 120], [120, 135]]);
  assert.deepEqual(splitIntoStorySegments(60), [[0, 60]]);
  assert.deepEqual(splitIntoStorySegments(0), []);
});

test('storage meter warnings', () => {
  assert.deepEqual(storageState(0), { percent: 0, warning: null, backupsPaused: false });
  assert.equal(storageState(0.8 * LIMITS.memoriesQuotaBytes).warning, 80);
  assert.equal(storageState(0.95 * LIMITS.memoriesQuotaBytes).warning, 90);
  assert.deepEqual(storageState(LIMITS.memoriesQuotaBytes), { percent: 100, warning: 100, backupsPaused: true });
  assert.equal(storageState(1, undefined, true).backupsPaused, true, 'platform pool full also pauses backups');
});

test('edit window', () => {
  const sent = new Date('2026-11-14T10:00:00Z');
  assert.ok(canEditMessage(sent, new Date('2026-11-14T10:15:00Z'), true));
  assert.equal(canEditMessage(sent, new Date('2026-11-14T10:15:01Z'), true), false);
  assert.equal(canEditMessage(sent, sent, false), false);
});

test('sha256 for dedupe', async () => {
  assert.equal(await sha256Hex(new TextEncoder().encode('abc')),
    'ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad');
});

test('limits match the database migrations', () => {
  const dir = join(import.meta.dirname, '../../../supabase/migrations');
  const sql = readdirSync(dir).sort().map((f) => readFileSync(join(dir, f), 'utf8')).join('\n');
  /** Capture numbers from one specific SQL context (never a bare substring search). */
  const grab = (re: RegExp, label: string): number[] => {
    const m = re.exec(sql);
    assert.ok(m, `${label}: SQL pattern not found`);
    return m.slice(1).map(Number);
  };
  const [memoryPhoto, photo] = grab(/elsif p_mime in \('image\/jpeg', 'image\/webp', 'image\/png'\) then\s+if p_purpose = 'memory_backup' then v_max_bytes := (\d+); else v_max_bytes := (\d+);/, 'photo caps');
  assert.equal(photo, LIMITS.bytes.photo, 'photo bytes');
  assert.equal(memoryPhoto, LIMITS.bytes.memoryPhoto, 'memory photo bytes');
  const [memVideo, memVideoSecs, shortVideo, shortVideoSecs] = grab(/elsif p_mime in \('video\/mp4', 'video\/webm'\) then[\s\S]*?v_max_bytes := (\d+); v_max_duration := (\d+);\s+else v_max_bytes := (\d+); v_max_duration := (\d+);/, 'video caps');
  assert.equal(memVideo, LIMITS.bytes.memoryVideo, 'memory video bytes');
  assert.equal(memVideoSecs, LIMITS.memoriesVideoMaxSeconds, 'memory video seconds');
  assert.equal(shortVideo, LIMITS.bytes.shortVideo, 'short video bytes');
  assert.equal(shortVideoSecs, LIMITS.snap.maxVideoSeconds, 'short video seconds');
  assert.equal(grab(/elsif p_mime in \('audio\/webm', 'audio\/mp4', 'audio\/ogg'\) then[\s\S]*?v_max_bytes := (\d+);/, 'voice cap')[0], LIMITS.bytes.voice, 'voice bytes');
  assert.equal(grab(/if p_mime <> 'application\/octet-stream' then perform private\.fail\('invalid_media_type'\); end if;\s+v_max_bytes := (\d+);/, 'vault cap')[0], LIMITS.bytes.vaultBlob, 'vault bytes');
  assert.equal(grab(/memories_quota_bytes bigint not null default (\d+)/, 'memories quota')[0], LIMITS.memoriesQuotaBytes);
  assert.equal(grab(/body text check \(char_length\(body\) <= (\d+)\)/, 'message length')[0], LIMITS.messageMaxChars);
  assert.equal(grab(/char_length\(btrim\(display_name\)\) between 1 and (\d+)/, 'display name')[0], LIMITS.displayNameMax);
  const [mid1, mid2] = grab(/username::text ~ '\^\[a-z0-9\]\(\?:\[a-z0-9\._\]\{(\d+),(\d+)\}\)\[a-z0-9\]\$'/, 'username pattern');
  assert.equal(mid1! + 2, LIMITS.username.min, 'username min');
  assert.equal(mid2! + 2, LIMITS.username.max, 'username max');
  assert.equal(grab(/username_cooldown interval not null default interval '(\d+) hours'/, 'cooldown')[0], LIMITS.username.cooldownHours);
  assert.equal(grab(/username_reservation interval not null default interval '(\d+) days'/, 'reservation')[0], LIMITS.username.reservationDays);
  assert.equal(grab(/message_edit_window interval not null default interval '(\d+) minutes'/, 'edit window')[0], LIMITS.messageEditWindowMinutes);
  assert.equal(grab(/pinned_rank smallint check \(pinned_rank between 1 and (\d+)\)/, 'pins')[0], LIMITS.maxPins);
  assert.equal(grab(/if v_count > (\d+) then perform private\.fail\('group_too_large'/, 'group size')[0], LIMITS.groupMaxMembers);
  assert.equal(grab(/array_length\(p_members, 1\) > (\d+) then perform private\.fail\('group_too_large'/, 'group invite size')[0], LIMITS.groupMaxMembers - 1);
  const [vMin, vMax] = grab(/view_seconds smallint check \(view_seconds between (\d+) and (\d+)\)/, 'snap timer');
  assert.equal(vMin, LIMITS.snap.minViewSeconds); assert.equal(vMax, LIMITS.snap.maxViewSeconds);
  const bucket = /allowed_mime_types\)\s+values \('media', 'media', false, \d+,\s+array\[([^\]]+)\]/.exec(sql);
  assert.ok(bucket, 'bucket MIME list');
  const listed = bucket[1]!.split(',').map((x) => x.trim().replace(/'/g, '')).sort();
  assert.deepEqual(listed, [...PHOTO_MIME, ...VIDEO_MIME, ...AUDIO_MIME, 'application/octet-stream'].sort(), 'bucket MIME types');
});
