import { isNetworkFailure } from '@pulse/domain';
import { rpc, supabase } from './supabase';

/**
 * Sends uncaught app errors to the owner's error list (Owner panel), so problems on real
 * phones are visible without screenshots. Signed-in users only; at most 10 different
 * errors per session; network failures and harmless browser warnings are ignored.
 * Only the error text, a short stack, the page path (no query) and the browser are sent.
 */
declare const __APP_VERSION__: string;
const seen = new Set<string>();
let sent = 0;
const IGNORE = /ResizeObserver loop|Script error\.?$|AbortError|The user aborted|Load failed|Failed to fetch|NetworkError/i;

export function reportError(err: unknown, where: string): void {
  try {
    const e = err instanceof Error ? err : new Error(typeof err === 'string' ? err : (JSON.stringify(err) ?? 'unknown').slice(0, 200));
    if (!e.message || IGNORE.test(e.message) || isNetworkFailure(e, navigator.onLine !== false)) return;
    const key = `${where}:${e.message.slice(0, 120)}`;
    if (seen.has(key) || sent >= 10) return;
    seen.add(key); sent++;
    void supabase.auth.getSession().then(({ data }) => {
      if (!data.session) return undefined;
      return rpc('report_client_error', {
        p_message: `[${where}] ${e.message}`.slice(0, 300),
        p_stack: (e.stack ?? '').slice(0, 2000),
        p_path: location.pathname.slice(0, 200),
        p_user_agent: navigator.userAgent.slice(0, 200),
        p_app_version: typeof __APP_VERSION__ === 'string' ? __APP_VERSION__ : 'dev',
      });
    }).catch(() => {});
  } catch { /* never let reporting break the app */ }
}

export function installErrorReporting(): void {
  window.addEventListener('error', (ev) => reportError(ev.error ?? ev.message, 'window'));
  window.addEventListener('unhandledrejection', (ev) => reportError(ev.reason, 'promise'));
}
