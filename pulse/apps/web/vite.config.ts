import { readFileSync, writeFileSync, existsSync, unlinkSync } from 'node:fs';
import { join } from 'node:path';
import { defineConfig, loadEnv, type Plugin } from 'vite';
import react from '@vitejs/plugin-react';
import { VitePWA } from 'vite-plugin-pwa';

/**
 * Pins the Content-Security-Policy in dist/_headers to this deployment's own Supabase
 * project. A wildcard (*.supabase.co) would let injected script send a stolen session to
 * any other project; the exact origin does not.
 */
function pinSupabaseOrigin(mode: string): Plugin {
  let outDir = join(__dirname, 'dist');
  return {
    name: 'pulse-pin-supabase-origin',
    apply: 'build',
    configResolved(c) { outDir = c.build.outDir.startsWith('/') ? c.build.outDir : join(c.root, c.build.outDir); },
    closeBundle() {
      const file = join(outDir, '_headers');
      if (!existsSync(file)) return;
      const url = loadEnv(mode, __dirname, 'VITE_').VITE_SUPABASE_URL ?? '';
      let host = '';
      try { host = new URL(url).host; } catch { /* missing */ }
      if (!/^[a-z0-9]+\.supabase\.co$/.test(host)) {
        this.warn(`CSP: VITE_SUPABASE_URL (${url || 'unset'}) is not a hosted project; keeping *.supabase.co`);
        return;
      }
      const pinned = readFileSync(file, 'utf8')
        .replaceAll('https://*.supabase.co', `https://${host}`)
        .replaceAll('wss://*.supabase.co', `wss://${host}`);
      writeFileSync(file, pinned);
    },
  };
}

/**
 * GitHub Pages build (PULSE_HOST=github-pages). GitHub Pages cannot send custom headers, so:
 * - the same Content-Security-Policy (pinned to this project) goes into a <meta> tag;
 *   frame-ancestors is not allowed there, so frame-guard.js hides the page when framed
 *   (clickjacking), replacing X-Frame-Options / frame-ancestors;
 * - referrer policy via <meta name="referrer">; noindex (a private beta stays out of search engines);
 * - 404.html is a copy of index.html so deep links (/chats/…) load the app;
 * - .nojekyll so every file is served as built.
 */
function githubPages(mode: string, base: string): Plugin {
  let outDir = join(__dirname, 'dist');
  const enabled = process.env.PULSE_HOST === 'github-pages';
  return {
    name: 'pulse-github-pages',
    apply: 'build',
    configResolved(c) { outDir = c.build.outDir.startsWith('/') ? c.build.outDir : join(c.root, c.build.outDir); },
    transformIndexHtml(html) {
      if (!enabled) return html;
      const host = supabaseHost(mode);
      if (!host) throw new Error('PULSE_HOST=github-pages needs VITE_SUPABASE_URL set to the hosted project');
      const line = readFileSync(join(__dirname, 'public', '_headers'), 'utf8').split('\n')
        .map((l) => l.trim()).find((l) => l.startsWith('Content-Security-Policy:'));
      if (!line) throw new Error('CSP missing from public/_headers');
      const csp = line.slice('Content-Security-Policy:'.length).trim()
        .replaceAll('https://*.supabase.co', `https://${host}`).replaceAll('wss://*.supabase.co', `wss://${host}`)
        .split(';').map((d) => d.trim()).filter((d) => d && !d.startsWith('frame-ancestors')).join('; ');
      return html.replace('<meta charset="UTF-8" />', `<meta charset="UTF-8" />
    <meta http-equiv="Content-Security-Policy" content="${csp}" />
    <meta name="referrer" content="strict-origin-when-cross-origin" />
    <meta name="robots" content="noindex, nofollow" />
    <script src="${base}frame-guard.js"></script>`);
    },
    closeBundle() {
      if (!enabled) return;
      writeFileSync(join(outDir, '404.html'), readFileSync(join(outDir, 'index.html')));
      writeFileSync(join(outDir, '.nojekyll'), '');
      for (const f of ['_headers', '_redirects']) if (existsSync(join(outDir, f))) unlinkSync(join(outDir, f));   // Cloudflare-only
    },
  };
}

function supabaseHost(mode: string): string {
  const url = loadEnv(mode, __dirname, 'VITE_').VITE_SUPABASE_URL ?? '';
  try { const h = new URL(url).host; return /^[a-z0-9]+\.supabase\.co$/.test(h) ? h : ''; } catch { return ''; }
}

// Static SPA for Cloudflare Pages (free, no per-request cost). See docs/ARCHITECTURE.md §2.
// PULSE_BASE: the folder the app is served from, e.g. "/SpellsConfiguration.rbxm/" on
// GitHub Pages. Defaults to "/" (Cloudflare Pages, local dev, tests).
const BASE = (() => {
  const b = process.env.PULSE_BASE ?? '/';
  if (!/^\/([A-Za-z0-9._-]+\/)*$/.test(b)) throw new Error(`PULSE_BASE must look like /folder/ (got ${b})`);
  return b;
})();

export default defineConfig(({ mode }) => ({
  base: BASE,
  // Shown next to error reports in the Owner panel (Cloudflare Pages and CI set these).
  define: { __APP_VERSION__: JSON.stringify((process.env.CF_PAGES_COMMIT_SHA ?? process.env.GITHUB_SHA ?? 'dev').slice(0, 12)) },
  plugins: [
    react(),
    pinSupabaseOrigin(mode),
    githubPages(mode, BASE),
    VitePWA({
      registerType: 'prompt',
      includeAssets: ['icon.svg', 'apple-touch-icon.png'],
      manifest: {
        name: 'PULSE',
        short_name: 'PULSE',
        description: 'Your people. Your moments.',
        theme_color: '#0b0b10',
        background_color: '#0b0b10',
        display: 'standalone',
        orientation: 'portrait',
        start_url: BASE,
        scope: BASE,
        icons: [
          { src: 'icon-192.png', sizes: '192x192', type: 'image/png' },
          { src: 'icon-512.png', sizes: '512x512', type: 'image/png' },
          { src: 'icon-maskable-512.png', sizes: '512x512', type: 'image/png', purpose: 'maskable' },
        ],
      },
      workbox: {
        // Offline shell only. API, auth and media responses are never cached: they are
        // private, short-lived and must always pass server-side authorisation.
        globPatterns: ['**/*.{js,css,html,svg,png,woff2}'],
        navigateFallback: `${BASE}index.html`,
        navigateFallbackDenylist: [/^\/auth\//, /^\/rest\//, /^\/storage\//, /^\/functions\//],
        runtimeCaching: [],
        importScripts: ['push-sw.js'],        // push + notificationclick handlers
      },
    }),
  ],
  server: { port: 5173, strictPort: true },
  preview: { port: 4173, strictPort: true },
  build: { target: 'es2022', sourcemap: false },
}));
