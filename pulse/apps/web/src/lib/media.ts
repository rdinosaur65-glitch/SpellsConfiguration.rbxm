import { FunctionsHttpError } from '@supabase/supabase-js';
import { LIMITS, sha256Hex, validateMedia, type MediaPurpose } from '@pulse/domain';
import { rpc, supabase } from './supabase';

const PROJECT_URL = (import.meta.env.VITE_SUPABASE_URL as string | undefined) ?? '';

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

/** Ask the media-url Edge Function for a short-lived signed URL. */
export async function signedMediaUrl(req: MediaRequest): Promise<{ url: string; mime_type: string; expires_in: number }> {
  const { data, error } = await supabase.functions.invoke('media-url', { body: req });
  if (error) {
    let code = 'media_not_found';
    if (error instanceof FunctionsHttpError) {
      try { code = ((await error.context.json()) as { error?: string }).error ?? code; } catch { /* keep default */ }
    } else if (/fetch|network/i.test(error.message)) code = 'Failed to fetch';
    throw new Error(code);
  }
  const d = data as { path: string; mime_type: string; expires_in: number };
  return { url: PROJECT_URL + d.path, mime_type: d.mime_type, expires_in: d.expires_in };
}

/**
 * Bytes are fetched once per app session and kept as an in-memory blob URL (never
 * written to device storage), so scrolling or re-rendering does not spend the egress
 * budget again. Released on sign-out (page reload) or via releaseMedia().
 */
const blobCache = new Map<string, Promise<string>>();
export function chatMediaObjectUrl(assetId: string): Promise<string> {
  let p = blobCache.get(assetId);
  if (!p) {
    p = (async () => {
      const { url } = await signedMediaUrl({ asset_id: assetId });
      const res = await fetch(url);
      if (!res.ok) throw new Error('media_not_found');
      return URL.createObjectURL(await res.blob());
    })();
    p.catch(() => blobCache.delete(assetId));
    blobCache.set(assetId, p);
  }
  return p;
}

/** Snap bytes are never cached: fetched for one viewing session, then released. */
export async function snapObjectUrl(snapId: string, sessionId: string): Promise<string> {
  const { url } = await signedMediaUrl({ snap_id: snapId, session_id: sessionId });
  const res = await fetch(url);
  if (!res.ok) throw new Error('snap_expired');
  return URL.createObjectURL(await res.blob());
}

export function releaseAllMedia() {
  for (const p of blobCache.values()) void p.then((u) => URL.revokeObjectURL(u)).catch(() => {});
  blobCache.clear();
}
