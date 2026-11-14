// storage-janitor — removes media objects the database has released.
//
// Called by pg_cron through pg_net (see migration 0016) with a shared secret header;
// gateway JWT checks are off for this function (config.toml), the secret is the gate.
// Loop: janitor_claim_deletions() → Storage bulk delete → janitor_mark_deleted().
// Objects that are already gone count as removed. Time-boxed so one run stays short.
import { SERVICE_KEY, SUPABASE_URL, json, rpc, safeEqual, serviceHeaders } from '../_shared/http.ts';

const SECRET = Deno.env.get('JANITOR_SECRET') ?? '';
const BATCH = 100;
const TIME_BUDGET_MS = 20_000;

interface Claim { asset_id: string; bucket: string; object_path: string }

Deno.serve(async (req) => {
  if (req.method !== 'POST') return json(405, { error: 'method_not_allowed' });
  if (!SECRET || !safeEqual(req.headers.get('x-janitor-secret') ?? '', SECRET)) {
    return json(401, { error: 'unauthorized' });
  }
  const started = Date.now();
  let removed = 0, failed = 0, rounds = 0;
  while (Date.now() - started < TIME_BUDGET_MS) {
    rounds++;
    const claim = await rpc<Claim[]>('janitor_claim_deletions', { p_limit: BATCH }, SERVICE_KEY);
    if (!claim.ok) return json(500, { error: claim.code, removed });
    if (claim.data.length === 0) break;

    const byBucket = new Map<string, Claim[]>();
    for (const c of claim.data) byBucket.set(c.bucket, [...(byBucket.get(c.bucket) ?? []), c]);
    const done: string[] = [];
    for (const [bucket, items] of byBucket) {
      const res = await fetch(`${SUPABASE_URL}/storage/v1/object/${encodeURIComponent(bucket)}`, {
        method: 'DELETE',
        headers: { ...serviceHeaders(), 'Content-Type': 'application/json' },
        body: JSON.stringify({ prefixes: items.map((i) => i.object_path) }),
      });
      // 200 with the list of removed objects; missing objects are simply not listed,
      // which is the state we want, so the whole batch is confirmed.
      if (res.ok) done.push(...items.map((i) => i.asset_id)); else failed += items.length;
    }
    if (done.length) {
      const mark = await rpc<number>('janitor_mark_deleted', { p_assets: done }, SERVICE_KEY);
      if (!mark.ok) return json(500, { error: mark.code, removed });
      removed += done.length;
    }
    if (done.length === 0) break;   // Storage refused everything: stop, retry next run
  }
  return json(200, { removed, failed, rounds });
});
