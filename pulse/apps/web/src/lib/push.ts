import { rpc } from './supabase';

/**
 * Web Push on this device (standard browser push with VAPID — free, no extra account).
 * The browser's push service gives an endpoint and keys; the server stores them for the
 * signed-in account and this sign-in session only, so signing out stops notifications.
 * iPhone/iPad: only for PULSE installed on the Home Screen (iOS 16.4 or later).
 */
const KEY = (import.meta.env.VITE_VAPID_PUBLIC_KEY as string | undefined) ?? '';

export function pushSupported(): boolean {
  return Boolean(KEY) && 'serviceWorker' in navigator && 'PushManager' in window && 'Notification' in window;
}

function keyBytes(b64url: string): ArrayBuffer {
  const b64 = b64url.replace(/-/g, '+').replace(/_/g, '/') + '='.repeat((4 - (b64url.length % 4)) % 4);
  return Uint8Array.from(atob(b64), (c) => c.charCodeAt(0)).buffer;
}

/** The active service worker, without waiting for ever when there is none. */
async function registration(waitMs: number): Promise<ServiceWorkerRegistration | null> {
  const reg = await navigator.serviceWorker.getRegistration();
  if (reg?.active || !waitMs) return reg?.active ? reg : null;
  return Promise.race([navigator.serviceWorker.ready,
    new Promise<null>((r) => setTimeout(() => r(null), waitMs))]);
}

async function current(): Promise<PushSubscription | null> {
  const reg = await registration(0);
  return reg ? reg.pushManager.getSubscription() : null;
}

async function save(sub: PushSubscription): Promise<void> {
  const j = sub.toJSON() as { keys?: { p256dh?: string; auth?: string } };
  await rpc('save_push_subscription', { p_endpoint: sub.endpoint, p_p256dh: j.keys?.p256dh, p_auth: j.keys?.auth });
}

/** Is this device set to receive notifications for the signed-in account? */
export async function pushEnabled(): Promise<boolean> {
  if (!pushSupported() || Notification.permission !== 'granted') return false;
  const sub = await current();
  return sub ? rpc<boolean>('has_push_subscription', { p_endpoint: sub.endpoint }) : false;
}

export async function enablePush(): Promise<'enabled' | 'denied' | 'unsupported'> {
  if (!pushSupported()) return 'unsupported';
  const permission = await Notification.requestPermission();
  if (permission !== 'granted') return 'denied';
  const reg = await registration(10_000);
  if (!reg) return 'unsupported';
  const sub = (await reg.pushManager.getSubscription())
    ?? await reg.pushManager.subscribe({ userVisibleOnly: true, applicationServerKey: keyBytes(KEY) });
  await save(sub);
  return 'enabled';
}

/** Stop notifications on this device (also called before signing out). */
export async function disablePush(): Promise<void> {
  if (!pushSupported()) return;
  const sub = await current().catch(() => null);
  if (!sub) return;
  await rpc('delete_push_subscription', { p_endpoint: sub.endpoint }).catch(() => {});
  await sub.unsubscribe().catch(() => false);
}

/** After signing out: drop this device's browser subscription. (The server already stops
 *  sending once the session has ended, and removes the record on its next run.) */
export async function forgetPushOnThisDevice(): Promise<void> {
  if (!pushSupported()) return;
  const sub = await current().catch(() => null);
  await sub?.unsubscribe().catch(() => false);
}

/** After signing in again, re-attach this device to the new session — only if this same
 *  account had turned notifications on here (another person signing in on the device
 *  never inherits them). */
export async function resyncPush(): Promise<void> {
  if (!pushSupported() || Notification.permission !== 'granted') return;
  const sub = await current().catch(() => null);
  if (!sub) return;
  const mine = await rpc<boolean>('has_push_subscription', { p_endpoint: sub.endpoint }).catch(() => false);
  if (mine) await save(sub).catch(() => {});
}
