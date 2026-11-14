// media-url — the only way media leaves the private bucket.
//
// 1. Authorise with the CALLER's JWT: authorize_media_access(asset) or, for a Snap,
//    authorize_snap_media(snap, session). Those RPCs check membership, friendship,
//    blocks, account state, 2FA, rate limits and the egress budget, and say how long
//    the URL may live (≤ 60 s; for a Snap, never past the viewing session).
// 2. Sign with the service role for exactly that long.
// The response carries a path relative to the project URL; the app prefixes its own
// Supabase URL (inside the platform the function sees an internal hostname).
import { CORS, SERVICE_KEY, SUPABASE_URL, UUID, json, rpc } from '../_shared/http.ts';

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

  const seconds = Math.max(1, Math.min(60, Math.floor(g.valid_seconds)));
  const path = g.object_path.split('/').map(encodeURIComponent).join('/');
  const signed = await fetch(`${SUPABASE_URL}/storage/v1/object/sign/${encodeURIComponent(g.bucket)}/${path}`, {
    method: 'POST',
    headers: { Authorization: `Bearer ${SERVICE_KEY}`, apikey: SERVICE_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify({ expiresIn: seconds }),
  });
  if (!signed.ok) return json(502, { error: 'signing_failed' });
  const { signedURL } = await signed.json() as { signedURL?: string };
  if (!signedURL) return json(502, { error: 'signing_failed' });
  return json(200, { path: `/storage/v1${signedURL}`, mime_type: g.mime_type, expires_in: seconds });
});
