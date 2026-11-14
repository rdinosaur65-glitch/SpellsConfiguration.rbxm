// Shared helpers for PULSE Edge Functions. No third-party imports: everything goes
// through plain fetch to the PostgREST and Storage HTTP APIs of the same project.

export const SUPABASE_URL = Deno.env.get('SUPABASE_URL') ?? '';
export const ANON_KEY = Deno.env.get('SUPABASE_ANON_KEY') ?? '';
export const SERVICE_KEY = Deno.env.get('SUPABASE_SERVICE_ROLE_KEY') ?? '';

/**
 * Headers that act as the service role. Hosted projects created since the new API keys
 * hand functions a secret key (sb_secret_…), which is not a JWT: it must travel in
 * `apikey` (the API gateway turns it into a service-role JWT) and must not be paired with
 * another key. Legacy service-role keys are JWTs and also go in Authorization.
 */
export function serviceHeaders(): Record<string, string> {
  return SERVICE_KEY.split('.').length === 3
    ? { apikey: SERVICE_KEY, Authorization: `Bearer ${SERVICE_KEY}` }
    : { apikey: SERVICE_KEY };
}

export const CORS: Record<string, string> = {
  'Access-Control-Allow-Origin': '*',   // auth is a bearer token, never a cookie
  'Access-Control-Allow-Headers': 'authorization, x-client-info, apikey, content-type',
  'Access-Control-Allow-Methods': 'POST, OPTIONS',
  'Access-Control-Max-Age': '86400',
};

export function json(status: number, body: unknown): Response {
  return new Response(JSON.stringify(body), {
    status,
    headers: { ...CORS, 'Content-Type': 'application/json', 'Cache-Control': 'no-store' },
  });
}

/** Call a Postgres function through PostgREST with the given bearer token (a user's JWT,
 *  or SERVICE_KEY to act as the service role). */
export async function rpc<T>(fn: string, args: Record<string, unknown>, bearer: string): Promise<
  { ok: true; data: T } | { ok: false; status: number; code: string }> {
  let res: Response;
  try {
    res = await fetch(`${SUPABASE_URL}/rest/v1/rpc/${fn}`, {
      method: 'POST',
      headers: { ...(bearer === SERVICE_KEY ? serviceHeaders() : { apikey: ANON_KEY, Authorization: `Bearer ${bearer}` }),
                 'Content-Type': 'application/json' },
      body: JSON.stringify(args),
      signal: AbortSignal.timeout(8_000),      // a stalled call must not outlive the function's own time budget
    });
  } catch {
    return { ok: false, status: 504, code: 'upstream_timeout' };
  }
  const text = await res.text();
  let body: unknown = null;
  try { body = text ? JSON.parse(text) : null; } catch { body = null; }
  if (!res.ok) {
    // Our own error codes (private.fail) are short snake_case words; anything else is an
    // internal message (SQL, permissions, timeouts) that must not reach the browser.
    const raw = (body as { message?: string } | null)?.message ?? '';
    const code = /^[a-z][a-z0-9_]{1,62}$/.test(raw) ? raw : 'internal_error';
    if (code === 'internal_error') console.error(`rpc ${fn} failed (${res.status}): ${raw.slice(0, 200)}`);
    return { ok: false, status: res.status, code };
  }
  return { ok: true, data: body as T };
}

export const UUID = /^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$/i;

/** Constant-time string comparison (shared-secret checks). */
export function safeEqual(a: string, b: string): boolean {
  const x = new TextEncoder().encode(a), y = new TextEncoder().encode(b);
  let diff = x.length ^ y.length;
  for (let i = 0; i < Math.max(x.length, y.length); i++) diff |= (x[i] ?? 0) ^ (y[i] ?? 0);
  return diff === 0;
}
