import { rpc } from './supabase';
import { uploadMedia } from './media';
import type { Message } from './types';

/**
 * Messages waiting to be sent, in memory only (message text is never written to device
 * storage). Scoped to the signed-in account: switching or signing out clears it, so one
 * person's unsent message can never go out under someone else's name. Sends are
 * idempotent (client_msg_id; photos are deduplicated by SHA-256), so retries are safe.
 * The Shell flushes the queue on reconnect from any screen; an open chat listens for
 * the results.
 */
export interface Pending extends Message { local?: 'sending' | 'failed'; preview?: string }
export type OutboxEvent =
  | { type: 'sent'; clientId: string; id: string }
  | { type: 'failed'; clientId: string; offline: boolean; error: unknown };

let owner: string | null = null;
const queue = new Map<string, Pending>();     // by client_msg_id
const blobs = new Map<string, Blob>();        // photo bytes for queued photos
const inflight = new Set<string>();
const listeners = new Set<(e: OutboxEvent) => void>();

export function setOutboxOwner(uid: string | null): void {
  if (uid === owner) return;
  for (const m of queue.values()) if (m.preview) URL.revokeObjectURL(m.preview);
  queue.clear(); blobs.clear(); inflight.clear();
  owner = uid;
}

export function onOutbox(l: (e: OutboxEvent) => void): () => void {
  listeners.add(l);
  return () => { listeners.delete(l); };
}
const emit = (e: OutboxEvent) => listeners.forEach((l) => l(e));

/** Messages of the current account still waiting in this chat. */
export function pendingFor(conv: string): Pending[] {
  return [...queue.values()].filter((m) => m.conversation_id === conv && m.sender_id === owner);
}

export function enqueue(m: Pending, blob?: Blob): void {
  if (!owner || m.sender_id !== owner) return;
  queue.set(m.client_msg_id, { ...m, local: 'sending' });
  if (blob) blobs.set(m.client_msg_id, blob);
}

const isOffline = (e: unknown) => navigator.onLine === false || /fetch|network/i.test((e as Error)?.message ?? '');

/** Try to send one queued message. Keeps it queued when offline; drops it on other errors. */
export async function deliver(clientId: string): Promise<void> {
  const m = queue.get(clientId);
  if (!m || inflight.has(clientId) || m.sender_id !== owner) return;
  const sender = owner;
  inflight.add(clientId);
  queue.set(clientId, { ...m, local: 'sending' });
  try {
    const blob = m.kind === 'photo' ? blobs.get(clientId) : undefined;
    if (m.kind === 'photo' && !blob) throw new Error('invalid_media');
    const asset = blob ? await uploadMedia(blob, 'chat') : null;
    const id = await rpc<string>('send_message', {
      p_conv: m.conversation_id, p_kind: m.kind, p_body: m.body, p_client_msg_id: m.client_msg_id,
      p_media_asset: asset, p_reply_to: m.reply_to_id,
    });
    if (owner !== sender) return;           // signed out meanwhile: forget it
    queue.delete(clientId); blobs.delete(clientId);
    emit({ type: 'sent', clientId, id });
  } catch (error) {
    if (owner !== sender) return;
    const offline = isOffline(error);
    if (offline) queue.set(clientId, { ...m, local: 'failed' });
    else { queue.delete(clientId); }       // the chat keeps it on screen with Retry
    emit({ type: 'failed', clientId, offline, error });
  } finally {
    inflight.delete(clientId);
  }
}

/** Send everything still queued for the current account (called on reconnect). */
export function flushOutbox(): void {
  for (const m of queue.values()) if (m.local === 'failed' && m.sender_id === owner) void deliver(m.client_msg_id);
}

/** Retry from the chat's "Retry" button (re-queues a message that failed for another reason). */
export function retry(m: Pending): void {
  if (!queue.has(m.client_msg_id)) enqueue(m, blobs.get(m.client_msg_id));
  void deliver(m.client_msg_id);
}
