import { useEffect, useRef } from 'react';

/**
 * Cloudflare Turnstile (free) — shown only when VITE_TURNSTILE_SITE_KEY is set, which
 * must match Supabase Auth's bot protection (docs/ENVIRONMENT.md). Without a key the
 * component renders nothing and Auth calls carry no token (local development).
 * Tokens are single-use: remount the widget (change its `key`) after every attempt.
 */
const SITE_KEY = import.meta.env.VITE_TURNSTILE_SITE_KEY as string | undefined;
export const captchaEnabled = Boolean(SITE_KEY);

interface TurnstileApi {
  render: (el: HTMLElement, opts: Record<string, unknown>) => string;
  remove: (id: string) => void;
}
declare global { interface Window { turnstile?: TurnstileApi } }

let loader: Promise<TurnstileApi> | null = null;
function loadTurnstile(): Promise<TurnstileApi> {
  if (window.turnstile) return Promise.resolve(window.turnstile);
  loader ??= new Promise((resolve, reject) => {
    const s = document.createElement('script');
    s.src = 'https://challenges.cloudflare.com/turnstile/v0/api.js?render=explicit';
    s.async = true;
    s.onload = () => (window.turnstile ? resolve(window.turnstile) : reject(new Error('turnstile_unavailable')));
    s.onerror = () => { loader = null; reject(new Error('turnstile_unavailable')); };
    document.head.appendChild(s);
  });
  return loader;
}

export function Captcha({ onToken }: { onToken: (token: string | null) => void }) {
  const ref = useRef<HTMLDivElement>(null);
  const cb = useRef(onToken);
  cb.current = onToken;
  useEffect(() => {
    if (!SITE_KEY || !ref.current) return;
    let id: string | null = null, alive = true;
    loadTurnstile().then((t) => {
      if (!alive || !ref.current) return;
      id = t.render(ref.current, {
        sitekey: SITE_KEY,
        callback: (token: string) => cb.current(token),
        'expired-callback': () => cb.current(null),
        'error-callback': () => cb.current(null),
      });
    }).catch(() => cb.current(null));
    return () => { alive = false; if (id && window.turnstile) window.turnstile.remove(id); };
  }, []);
  if (!SITE_KEY) return null;
  return <div ref={ref} className="captcha" aria-label="Security check" />;
}
