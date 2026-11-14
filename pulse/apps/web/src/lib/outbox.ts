import { isNetworkFailure } from '@pulse/domain';
import { rpc } from './supabase';
import { uploadMedia } from './media';
import type { Message } from './types';

/**
 * Messages waiting to be sent, in memory only (message text is never written to device
 * storage). Scoped to the signed-in account: switching or signing out clears it, so one
 * person's unsent message can never go out under someone else's name. Sends are
 * idempotent (client_msg_id; photos are deduplicated by SHA-256), so retries are safe.
 * The Shell flushes the queue on reconnect from any screen; an open chat listens for
 * the results. Each chat's messages are sent one at a time, in the order they were
 * written, and never overtake an earlier message that is still waiting.
 */
export interface Pending extends Message { local?: 'sending' | 'failed'; preview?: string; duration?: number }
export type OutboxEvent =
  | { type: 'sent'; clientId: string; id: string }
  | { type: 'failed'; clientId: string; offline: boolean; error: unknown };

let owner: string | null = null;
let generation = 0;                            // bumped on every account change
const queue = new Map<string, Pending>();     // by client_msg_id
const blobs = new Map<string, Blob>();        // photo bytes for queued photos
const inflight = new Set<string>();
const listeners = new Set<(e: OutboxEvent) => void>();

export function setOutboxOwner(uid: string | null): void {
  if (uid === owner) return;
  for (const m of queue.values()) if (m.preview) URL.revokeObjectURL(m.preview);
  queue.clear(); blobs.clear(); inflight.clear(); chains.clear(); scheduled.clear();
  owner = uid;
  generation++;                                // sends already in flight must not write back
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

const isOffline = (e: unknown) => isNetworkFailure(e, navigator.onLine !== false);

/** Per-chat send chain: one message at a time, in queue order. */
const chains = new Map<string, Promise<void>>();
const scheduled = new Set<string>();

function schedule(conv: string, clientId: string): Promise<void> {
  scheduled.add(clientId);
  const next = (chains.get(conv) ?? Promise.resolve()).then(() => send(clientId))
    .finally(() => { scheduled.delete(clientId); });
  chains.set(conv, next);
  void next.finally(() => { if (chains.get(conv) === next) chains.delete(conv); });
  return next;
}

/** (Re)try every queued message of one chat, oldest first. */
function kick(conv: string): Promise<void> {
  const mine = [...queue.values()].filter((x) => x.conversation_id === conv && x.sender_id === owner);
  for (const x of mine) if (x.local === 'failed' && !scheduled.has(x.client_msg_id)) queue.set(x.client_msg_id, { ...x, local: 'sending' });
  let last = chains.get(conv) ?? Promise.resolve();
  for (const x of mine) if (!scheduled.has(x.client_msg_id) && !inflight.has(x.client_msg_id)) last = schedule(conv, x.client_msg_id);
  return last;
}

/** Send a queued message — together with any earlier one of its chat that is still
 *  waiting, in order. Keeps messages queued when offline; drops one on other errors. */
export function deliver(clientId: string): Promise<void> {
  const m = queue.get(clientId);
  if (!m || m.sender_id !== owner) return Promise.resolve();
  return kick(m.conversation_id);
}

async function send(clientId: string): Promise<void> {
  const m = queue.get(clientId);
  if (!m || inflight.has(clientId) || m.sender_id !== owner) return;
  const sender = owner;
  // An earlier message of this chat is still waiting (offline): keep the order, wait too.
  const mine = [...queue.values()].filter((x) => x.conversation_id === m.conversation_id && x.sender_id === sender);
  if (mine.slice(0, mine.findIndex((x) => x.client_msg_id === clientId)).some((x) => x.local === 'failed')) {
    queue.set(clientId, { ...m, local: 'failed' });
    emit({ type: 'failed', clientId, offline: true, error: new Error('network: waiting for an earlier message') });
    return;
  }
  inflight.add(clientId);
  queue.set(clientId, { ...m, local: 'sending' });
  const gen = generation;
  try {
    const withMedia = m.kind === 'photo' || m.kind === 'voice';
    const blob = withMedia ? blobs.get(clientId) : undefined;
    if (withMedia && !blob) throw new Error('invalid_media');
    const asset = blob ? await uploadMedia(blob, 'chat', { durationSeconds: m.duration }) : null;
    const id = await rpc<string>('send_message', {
      p_conv: m.conversation_id, p_kind: m.kind, p_body: m.body, p_client_msg_id: m.client_msg_id,
      p_media_asset: asset, p_reply_to: m.reply_to_id,
    });
    if (gen !== generation || owner !== sender) return;   // signed out (or switched) meanwhile: forget it
    queue.delete(clientId); blobs.delete(clientId);
    emit({ type: 'sent', clientId, id });
  } catch (error) {
    if (gen !== generation || owner !== sender) return;
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
  for (const conv of new Set([...queue.values()].filter((m) => m.sender_id === owner).map((m) => m.conversation_id))) void kick(conv);
}

/** Retry from the chat's "Retry" button (re-queues a message that failed for another reason). */
export function retry(m: Pending): void {
  if (!queue.has(m.client_msg_id)) enqueue(m, blobs.get(m.client_msg_id));
  void deliver(m.client_msg_id);
}
