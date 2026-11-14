import { LIMITS, sha256Hex, validateMedia, type MediaPurpose } from '@pulse/domain';
import { rpc, supabase } from './supabase';

const PROJECT_URL = (import.meta.env.VITE_SUPABASE_URL as string | undefined) ?? '';
const ANON_KEY = (import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined) ?? '';

/**
 * Re-encode a photo as JPEG at most `maxDim` px on its longest side. Besides saving
 * storage and egress on the free tier, re-encoding drops EXIF metadata (GPS location,
 * device details) before anything leaves the device.
 */
export async function compressImage(source: Blob | HTMLCanvasElement, maxDim = 1600): Promise<Blob> {
  let width: number, height: number, draw: (ctx: CanvasRenderingContext2D, w: number, h: number) => void;
  if (source instanceof Blob) {
    const bmp = await createImageBitmap(source);
    width = bmp.width; height = bmp.height;
    draw = (ctx, w, h) => { ctx.drawImage(bmp, 0, 0, w, h); bmp.close(); };
  } else {
    width = source.width; height = source.height;
    draw = (ctx, w, h) => ctx.drawImage(source, 0, 0, w, h);
  }
  const scale = Math.min(1, maxDim / Math.max(width, height));
  const w = Math.max(1, Math.round(width * scale)), h = Math.max(1, Math.round(height * scale));
  const canvas = document.createElement('canvas');
  canvas.width = w; canvas.height = h;
  const ctx = canvas.getContext('2d');
  if (!ctx) throw new Error('canvas_unavailable');
  draw(ctx, w, h);
  for (const q of [0.85, 0.75, 0.6, 0.45]) {
    const blob = await new Promise<Blob | null>((r) => canvas.toBlob(r, 'image/jpeg', q));
    if (blob && blob.size <= LIMITS.bytes.photo) return blob;
  }
  throw new Error('media_too_large');
}

interface Reservation { asset_id: string; bucket: string; object_path: string; deduplicated: boolean }

/**
 * Reserve → upload → confirm. Idempotent: the same bytes map to the same asset (the
 * server deduplicates by SHA-256), so a retry after a failure resumes where it stopped.
 */
export async function uploadMedia(blob: Blob, purpose: MediaPurpose): Promise<string> {
  const bytes = new Uint8Array(await blob.arrayBuffer());
  const mime = blob.type || 'image/jpeg';
  const check = validateMedia({ purpose, mime, bytes: bytes.byteLength });
  if (!check.ok) throw new Error(check.error);
  const sha = await sha256Hex(bytes);
  const [r] = await rpc<Reservation[]>('authorize_upload', {
    p_purpose: purpose, p_mime: mime, p_bytes: bytes.byteLength, p_sha256: sha,
  });
  if (!r) throw new Error('upload_failed');
  if (r.deduplicated) {
    // Already uploaded (or a previous attempt got as far as the reservation).
    try { if (await rpc<boolean>('confirm_upload', { p_asset: r.asset_id })) return r.asset_id; }
    catch (e) { if ((e as { message?: string }).message !== 'upload_missing') throw e; }
  }
  const { error } = await supabase.storage.from(r.bucket).upload(r.object_path, blob, { contentType: mime, upsert: false });
  if (error && !/exists/i.test(error.message)) throw error;
  if (!(await rpc<boolean>('confirm_upload', { p_asset: r.asset_id }))) throw new Error('upload_rejected');
  return r.asset_id;
}

export type MediaRequest = { asset_id: string } | { snap_id: string; session_id: string };

/**
 * One authorised download from the media-url Edge Function. The function streams the
 * bytes itself (no reusable URL exists) and marks them no-store; the request is also
 * made with cache: 'no-store' so nothing is written to the browser's disk cache.
 */
export async function fetchMedia(req: MediaRequest): Promise<Blob> {
  const { data } = await supabase.auth.getSession();
  const token = data.session?.access_token;
  if (!token) throw new Error('not_authenticated');
  let res: Response;
  try {
    res = await fetch(`${PROJECT_URL}/functions/v1/media-url`, {
      method: 'POST', cache: 'no-store', credentials: 'omit', referrerPolicy: 'no-referrer',
      headers: { Authorization: `Bearer ${token}`, apikey: ANON_KEY, 'Content-Type': 'application/json' },
      body: JSON.stringify(req),
    });
  } catch { throw new Error('Failed to fetch'); }
  if (!res.ok) {
    let code = 'media_not_found';
    try { code = ((await res.json()) as { error?: string }).error ?? code; } catch { /* keep default */ }
    if (code === 'mfa_required') window.dispatchEvent(new Event('pulse:mfa-required'));
    throw new Error(code);
  }
  return res.blob();
}

/**
 * Chat photos are fetched once per app session and kept as an in-memory blob URL (never
 * written to device storage), so scrolling or re-rendering does not spend the egress
 * budget again. Released on sign-out via releaseAllMedia().
 */
const blobCache = new Map<string, Promise<string>>();
export function chatMediaObjectUrl(assetId: string): Promise<string> {
  let p = blobCache.get(assetId);
  if (!p) {
    p = fetchMedia({ asset_id: assetId }).then((b) => URL.createObjectURL(b));
    p.catch(() => blobCache.delete(assetId));
    blobCache.set(assetId, p);
  }
  return p;
}

/** Snap bytes are never cached: fetched for one viewing session, then released. */
export async function snapObjectUrl(snapId: string, sessionId: string): Promise<string> {
  return URL.createObjectURL(await fetchMedia({ snap_id: snapId, session_id: sessionId }));
}

export function releaseAllMedia() {
  for (const p of blobCache.values()) void p.then((u) => URL.revokeObjectURL(u)).catch(() => {});
  blobCache.clear();
}
