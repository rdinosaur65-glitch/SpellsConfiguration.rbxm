import { test } from 'node:test';
import assert from 'node:assert/strict';
import { readFileSync, readdirSync } from 'node:fs';
import { join } from 'node:path';
import { LIMITS, MB } from '../src/limits.ts';
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
  const sql = readdirSync(dir).map((f) => readFileSync(join(dir, f), 'utf8')).join('\n');
  const expectInSql = (n: number, label: string) => assert.ok(sql.includes(String(n)), `${label} (${n}) missing from SQL`);
  expectInSql(LIMITS.bytes.photo, 'photo bytes');
  expectInSql(LIMITS.bytes.memoryPhoto, 'memory photo bytes');
  expectInSql(LIMITS.bytes.shortVideo, 'short video bytes');
  expectInSql(LIMITS.bytes.memoryVideo, 'memory video bytes');
  expectInSql(LIMITS.bytes.voice, 'voice bytes');
  expectInSql(LIMITS.memoriesQuotaBytes, 'memories quota');
  assert.match(sql, /message_edit_window interval not null default interval '15 minutes'/);
  assert.match(sql, /username_cooldown interval not null default interval '48 hours'/);
  assert.match(sql, /view_seconds between 1 and 10/);
  assert.match(sql, /pinned_rank between 1 and 3/);
  assert.match(sql, /v_max_duration := 300/);
  assert.match(sql, /v_max_duration := 60/);
});
