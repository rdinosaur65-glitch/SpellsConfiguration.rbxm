// push-send — delivers queued notifications (migration 0028) with Web Push.
//
// Called by the database through pg_net right after a message or friend request is
// committed, with the same shared secret as storage-janitor (gateway JWT checks off).
// Loop: push_claim() → encrypt + send to each device's push service → push_report()
// (subscriptions the push service no longer knows, 404/410, are removed).
// Payloads carry only who it is from and "New Chat" / "New Snap", never message text.
import { SERVICE_KEY, json, rpc, safeEqual } from '../_shared/http.ts';
import { sendWebPush, type Vapid } from '../_shared/webpush.ts';

const SECRET = Deno.env.get('JANITOR_SECRET') ?? '';
const VAPID: Vapid = {
  publicKey: Deno.env.get('VAPID_PUBLIC_KEY') ?? '',
  privateKey: Deno.env.get('VAPID_PRIVATE_KEY') ?? '',
  subject: Deno.env.get('VAPID_SUBJECT') ?? '',
};
const TIME_BUDGET_MS = 12_000;
const PARALLEL = 20;

interface Claim { subscription_id: string; endpoint: string; p256dh: string; auth: string; title: string; body: string; url: string; tag: string }

/** Send with up to two retries (after 1 s and 3 s) on a temporary failure: network error,
 *  429 or 5xx. Queue entries are claimed before sending, so retrying here is what keeps a
 *  brief push-service hiccup from losing the notification. */
async function deliver(c: Claim): Promise<number> {
  let status = 0;
  for (let attempt = 0; attempt < 3; attempt++) {
    status = await sendWebPush(c, { title: c.title, body: c.body, url: c.url, tag: c.tag }, VAPID).catch(() => 0);
    if (status !== 0 && status !== 429 && status < 500) return status;
    await new Promise((r) => setTimeout(r, attempt === 0 ? 1000 : 3000));
  }
  return status;
}

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json(405, { error: 'method_not_allowed' });
  if (!SECRET || !safeEqual(req.headers.get('x-janitor-secret') ?? '', SECRET)) return json(401, { error: 'unauthorized' });
  // Not configured yet: leave the queue alone (nothing is claimed and lost).
  if (!VAPID.publicKey || !VAPID.privateKey || !VAPID.subject) return json(200, { sent: 0, configured: false });

  const started = Date.now();
  let sent = 0, gone = 0, failed = 0;
  while (Date.now() - started < TIME_BUDGET_MS) {
    const claim = await rpc<Claim[]>('push_claim', { p_limit: 100 }, SERVICE_KEY);
    if (!claim.ok) return json(500, { error: claim.code, sent });
    if (claim.data.length === 0) {
      // A batch can claim events that no device should get; stop only when nothing is left.
      const pending = await rpc<boolean>('push_pending', {}, SERVICE_KEY);
      if (!pending.ok || !pending.data) break;
      continue;
    }
    const goneIds: string[] = [], sentIds: string[] = [];
    for (let i = 0; i < claim.data.length; i += PARALLEL) {
      const batch = claim.data.slice(i, i + PARALLEL);
      const statuses = await Promise.all(batch.map((c) => deliver(c)));
      statuses.forEach((s, j) => {
        const id = batch[j]!.subscription_id;
        if (s >= 200 && s < 300) { sent++; sentIds.push(id); }
        else if (s === 404 || s === 410) { gone++; goneIds.push(id); }
        else failed++;
      });
    }
    await rpc('push_report', { p_gone: goneIds, p_sent: sentIds }, SERVICE_KEY);
  }
  return json(200, { sent, gone, failed });
});
