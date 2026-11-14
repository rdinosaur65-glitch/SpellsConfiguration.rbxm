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
    if (claim.data.length === 0) break;
    const goneIds: string[] = [], sentIds: string[] = [];
    for (let i = 0; i < claim.data.length; i += PARALLEL) {
      const batch = claim.data.slice(i, i + PARALLEL);
      const statuses = await Promise.all(batch.map((c) => sendWebPush(c,
        { title: c.title, body: c.body, url: c.url, tag: c.tag }, VAPID).catch(() => 0)));
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
