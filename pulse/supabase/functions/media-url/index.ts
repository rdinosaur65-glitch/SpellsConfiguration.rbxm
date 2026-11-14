// media-url — the only way media leaves the private bucket.
//
// 1. Authorise with the CALLER's JWT: authorize_media_access(asset) or, for a Snap,
//    authorize_snap_media(snap, session). Those RPCs check membership, friendship,
//    blocks, account state, 2FA, rate limits and the egress budget, and charge the
//    caller's daily share for exactly one download.
// 2. Stream that one copy back from Storage (read with the service role).
// No URL is ever handed out, so nothing can be re-downloaded or shared, and the
// response is marked no-store so browsers and proxies do not keep it on disk.
import { CORS, SUPABASE_URL, UUID, json, rpc, serviceHeaders } from '../_shared/http.ts';

interface Grant { bucket: string; object_path: string; mime_type: string; valid_seconds: number }

const STATUS: Record<string, number> = {
  not_authenticated: 401, mfa_required: 401, account_not_active: 403, rate_limited: 429,
  egress_budget_exhausted: 429, egress_quota_exceeded: 429,
  media_not_found: 404, snap_expired: 410, snap_session_invalid: 403,
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json(405, { error: 'method_not_allowed' });

  const auth = req.headers.get('Authorization') ?? '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  if (!token) return json(401, { error: 'not_authenticated' });

  let body: { asset_id?: string; snap_id?: string; session_id?: string };
  try { body = await req.json(); } catch { return json(400, { error: 'invalid_body' }); }

  let grant;
  if (body.snap_id) {
    if (!UUID.test(body.snap_id) || !UUID.test(body.session_id ?? '')) return json(400, { error: 'invalid_body' });
    grant = await rpc<Grant[]>('authorize_snap_media', { p_snap: body.snap_id, p_session: body.session_id }, token);
  } else if (body.asset_id && UUID.test(body.asset_id)) {
    grant = await rpc<Grant[]>('authorize_media_access', { p_asset: body.asset_id }, token);
  } else {
    return json(400, { error: 'invalid_body' });
  }
  if (!grant.ok) return json(STATUS[grant.code] ?? (grant.status === 401 ? 401 : 403), { error: grant.code });
  const g = grant.data[0];
  if (!g) return json(404, { error: 'media_not_found' });

  const path = g.object_path.split('/').map(encodeURIComponent).join('/');
  // Time out only while waiting for Storage to answer; the body then streams as long as it needs.
  const ctl = new AbortController();
  const wait = setTimeout(() => ctl.abort(), 10_000);
  const obj = await fetch(`${SUPABASE_URL}/storage/v1/object/${encodeURIComponent(g.bucket)}/${path}`, {
    headers: serviceHeaders(), signal: ctl.signal,
  }).catch(() => null).finally(() => clearTimeout(wait));
  if (!obj) return json(504, { error: 'storage_unavailable' });
  if (!obj.ok || !obj.body) return json(obj.status === 404 ? 404 : 502, { error: obj.status === 404 ? 'media_not_found' : 'storage_unavailable' });

  const headers: Record<string, string> = {
    ...CORS,
    'Content-Type': g.mime_type,
    'Cache-Control': 'no-store, private, max-age=0',
    'X-Content-Type-Options': 'nosniff',
    'Content-Disposition': 'inline',
    'Access-Control-Expose-Headers': 'Content-Type, Content-Length',
  };
  const len = obj.headers.get('Content-Length');
  if (len) headers['Content-Length'] = len;
  return new Response(obj.body, { status: 200, headers });
});
