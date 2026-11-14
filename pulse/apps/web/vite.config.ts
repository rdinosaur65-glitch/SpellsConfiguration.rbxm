import { readFileSync, writeFileSync, existsSync } from 'node:fs';
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

// Static SPA for Cloudflare Pages (free, no per-request cost). See docs/ARCHITECTURE.md §2.
export default defineConfig(({ mode }) => ({
  plugins: [
    react(),
    pinSupabaseOrigin(mode),
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
        start_url: '/',
        scope: '/',
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
        navigateFallback: '/index.html',
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
