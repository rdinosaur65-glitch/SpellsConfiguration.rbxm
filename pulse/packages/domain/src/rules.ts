import { AUDIO_MIME, LIMITS, MB, PHOTO_MIME, VIDEO_MIME, type MediaPurpose } from './limits.ts';

export type Result<T = void> = { ok: true; value: T } | { ok: false; error: string; detail?: string };
const ok = <T>(value: T): Result<T> => ({ ok: true, value });
const fail = (error: string, detail?: string): Result<never> => ({ ok: false, error, detail });

// ---------------------------------------------------------------------------
// Usernames (mirrors private.validate_username)
// ---------------------------------------------------------------------------
const USERNAME_RE = /^[a-z0-9](?:[a-z0-9._]{1,18})[a-z0-9]$/;
const RESERVED = new Set(['pulse', 'admin', 'owner', 'support', 'help', 'moderator', 'official', 'system', 'root']);

export function normalizeUsername(raw: string): string {
  return raw.trim().toLowerCase();
}

export function validateUsername(raw: string): Result<string> {
  const v = normalizeUsername(raw);
  if (!USERNAME_RE.test(v) || /[._]{2}/.test(v)) return fail('invalid_username');
  if (RESERVED.has(v)) return fail('username_reserved');
  return ok(v);
}

/** When may this user change username again? null = now. Owner is exempt. */
export function nextUsernameChangeAt(lastChange: Date | null, now: Date, isOwner: boolean): Date | null {
  if (isOwner || !lastChange) return null;
  const next = new Date(lastChange.getTime() + LIMITS.username.cooldownHours * 3600_000);
  return next > now ? next : null;
}

// ---------------------------------------------------------------------------
// Snap timer (photo: 1..10 s or unlimited; video: its own length)
// ---------------------------------------------------------------------------
export type SnapTimer = { kind: 'seconds'; seconds: number } | { kind: 'unlimited' };

export function validateSnapTimer(t: SnapTimer): Result<SnapTimer> {
  if (t.kind === 'unlimited') return ok(t);
  const { minViewSeconds, maxViewSeconds } = LIMITS.snap;
  if (!Number.isInteger(t.seconds) || t.seconds < minViewSeconds || t.seconds > maxViewSeconds) {
    return fail('invalid_view_seconds');
  }
  return ok(t);
}

/**
 * Client-side countdown is cosmetic: the UI must stop rendering at whichever comes
 * first — the local timer or the server deadline returned by open_snap().
 */
export function remainingViewMs(serverDeadline: Date, now: Date): number {
  return Math.max(0, serverDeadline.getTime() - now.getTime());
}

// ---------------------------------------------------------------------------
// Media validation (mirrors private.validate_media)
// ---------------------------------------------------------------------------
export interface MediaCandidate { purpose: MediaPurpose; mime: string; bytes: number; durationSeconds?: number }

export function validateMedia(m: MediaCandidate): Result<void> {
  const b = LIMITS.bytes;
  let maxBytes: number;
  let maxDuration: number | undefined;

  if (m.purpose === 'vault_backup') {
    if (m.mime !== 'application/octet-stream') return fail('invalid_media_type');
    maxBytes = b.vaultBlob;
  } else if ((PHOTO_MIME as readonly string[]).includes(m.mime)) {
    maxBytes = m.purpose === 'memory_backup' ? b.memoryPhoto : b.photo;
  } else if ((VIDEO_MIME as readonly string[]).includes(m.mime)) {
    if (m.purpose === 'profile' || m.purpose === 'group_icon') return fail('invalid_media_type');
    if (m.purpose === 'memory_backup') { maxBytes = b.memoryVideo; maxDuration = LIMITS.memoriesVideoMaxSeconds; }
    else { maxBytes = b.shortVideo; maxDuration = LIMITS.snap.maxVideoSeconds; }
  } else if ((AUDIO_MIME as readonly string[]).includes(m.mime)) {
    if (m.purpose !== 'chat') return fail('invalid_media_type');
    maxBytes = b.voice; maxDuration = 300;
  } else {
    return fail('invalid_media_type');
  }

  if (!(m.bytes > 0) || m.bytes > maxBytes) return fail('media_too_large', String(maxBytes));
  if (maxDuration !== undefined) {
    if (!(m.durationSeconds && m.durationSeconds > 0)) return fail('duration_required');
    if (m.durationSeconds > maxDuration) return fail('media_too_long', String(maxDuration));
  }
  return ok(undefined);
}

// ---------------------------------------------------------------------------
// Multi-clip recording and Story splitting
// ---------------------------------------------------------------------------
/** Multi-clip Snaps share one 60-second budget. Returns seconds still recordable. */
export function remainingClipBudget(clipSeconds: readonly number[]): number {
  const used = clipSeconds.reduce((s, c) => s + c, 0);
  return Math.max(0, LIMITS.snap.maxVideoSeconds - used);
}

/** Split a long Story recording into valid ≤60 s segments: [start, end) pairs. */
export function splitIntoStorySegments(totalSeconds: number): Array<[number, number]> {
  if (!(totalSeconds > 0)) return [];
  const max = LIMITS.storySegmentMaxSeconds;
  const out: Array<[number, number]> = [];
  for (let start = 0; start < totalSeconds; start += max) {
    out.push([start, Math.min(start + max, totalSeconds)]);
  }
  return out;
}

// ---------------------------------------------------------------------------
// Storage meter (80/90/100 % warnings; full never deletes anything)
// ---------------------------------------------------------------------------
export type StorageState = { percent: number; warning: 80 | 90 | 100 | null; backupsPaused: boolean };

export function storageState(usedBytes: number, quotaBytes = LIMITS.memoriesQuotaBytes, poolFull = false): StorageState {
  const percent = quotaBytes > 0 ? Math.min(100, Math.round((usedBytes / quotaBytes) * 1000) / 10) : 100;
  const warning = [...LIMITS.storageWarnings].reverse().find((w) => percent >= w) ?? null;
  return { percent, warning, backupsPaused: percent >= 100 || poolFull };
}

export function formatBytes(n: number): string {
  if (n < 1024) return `${n} B`;
  if (n < MB) return `${(n / 1024).toFixed(1)} KB`;
  return `${(n / MB).toFixed(1)} MB`;
}

// ---------------------------------------------------------------------------
// Message editing window
// ---------------------------------------------------------------------------
export function canEditMessage(sentAt: Date, now: Date, isOwnText: boolean): boolean {
  return isOwnText && now.getTime() - sentAt.getTime() <= LIMITS.messageEditWindowMinutes * 60_000;
}

// ---------------------------------------------------------------------------
// Content hash for duplicate-upload prevention (Web Crypto; works in browsers,
// Deno Edge Functions and Node ≥ 20).
// ---------------------------------------------------------------------------
export async function sha256Hex(data: ArrayBuffer | Uint8Array): Promise<string> {
  const digest = await crypto.subtle.digest('SHA-256', data as BufferSource);
  return [...new Uint8Array(digest)].map((x) => x.toString(16).padStart(2, '0')).join('');
}
