import { defineConfig, devices } from '@playwright/test';

// End-to-end tests against the real local Supabase stack (`npm run sb:start` at repo root).
// The app is served by `vite preview` from a production build, so the service worker is real.
export default defineConfig({
  testDir: './e2e',
  timeout: 60_000,
  expect: { timeout: 10_000 },
  fullyParallel: false,
  workers: 1,
  reporter: [['list']],
  use: {
    baseURL: 'http://127.0.0.1:4173',
    trace: 'off',
    ...devices['Pixel 7'],
  },
  webServer: {
    command: 'npm run build && npm run preview',
    url: 'http://127.0.0.1:4173',
    reuseExistingServer: true,
    timeout: 120_000,
  },
});
