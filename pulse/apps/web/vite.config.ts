import { defineConfig } from 'vite';
import react from '@vitejs/plugin-react';
import { VitePWA } from 'vite-plugin-pwa';

// Static SPA for Cloudflare Pages (free, no per-request cost). See docs/ARCHITECTURE.md §2.
export default defineConfig({
  plugins: [
    react(),
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
      },
    }),
  ],
  server: { port: 5173, strictPort: true },
  preview: { port: 4173, strictPort: true },
  build: { target: 'es2022', sourcemap: false },
});
