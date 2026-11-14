# PULSE — Architecture

PULSE: *Your people. Your moments.* A camera-first, private, friends-only social PWA.

## 1. Stack and justification

| Layer | Choice | Why |
|---|---|---|
| Language | TypeScript (strict) | Spec requirement; shared types between UI and validation |
| UI | React 19 SPA, built with **Vite** | See §2 |
| Hosting | Cloudflare Pages, static only | Free and unlimited for static assets (see `INFRASTRUCTURE_ZERO_COST.md`) |
| Backend | Supabase Free: Postgres 15+, Auth (GoTrue), Realtime, Storage, Edge Functions (Deno), `pg_cron` | One free provider covering DB, auth, realtime, storage and jobs with no overage billing |
| Authorisation | Postgres **Row-Level Security** + `SECURITY DEFINER` RPCs | One rule set shared by REST queries, Storage and Realtime |
| Calls | WebRTC, signalling over Supabase Realtime broadcast, public STUN, optional TURN | Free; mesh ≤ 4 participants |
| Push | Web Push (VAPID) from an Edge Function | Free; works on iOS only for Home-Screen-installed PWAs |
| Local storage | OPFS + IndexedDB, WebCrypto for Vault | Local-first Memories |

## 2. Why Vite SPA instead of Next.js

The spec prefers Next.js "or another justified React framework". On Cloudflare's free
plan, any server-rendered or API route runs as a Worker/Pages Function and counts
against a hard 100,000 requests/day cap. A camera app gains little from SSR (every
screen is behind login and device APIs). A static Vite SPA:
- costs nothing per request on Cloudflare Pages;
- keeps every privileged operation in Postgres RPCs or Supabase Edge Functions, where
  authorisation already lives;
- avoids a second server runtime to secure.

Next.js with `output: 'export'` would also work; Vite is chosen for faster builds and
fewer moving parts. This is a documented, reversible decision.

## 3. Repository layout

```
pulse/
  docs/                      Architecture, €0 decision, checklist, env, security, reports
  supabase/
    migrations/              Ordered SQL migrations (source of truth for schema + RLS)
    tests/                   Supabase shim for local Postgres + SQL test suites
    functions/               Edge Functions (Deno) — next phase
    config.toml              Local Supabase settings (mirrors the hosted Auth settings)
  packages/domain/           Pure TypeScript rules shared by UI and Edge Functions (+ tests)
  apps/web/                  Vite React PWA (screens, design system, e2e tests in apps/web/e2e)
  scripts/                   Local test runners
```

## 4. Security model (summary — details in `SECURITY_MODEL.md`)

- Every table has RLS enabled; the `anon` role can read nothing.
- Clients never write sensitive state directly. Friend requests, Snap viewing, message
  edits, username changes, uploads and admin actions go through `SECURITY DEFINER`
  functions that check `auth.uid()`, blocks, friendship and quotas inside one
  transaction with row locks.
- The service-role key is used only inside Edge Functions and never shipped to the browser.
- The owner is identified by an immutable UUID in `private.platform_config`, never by username.
- The owner panel exposes aggregate data and report evidence only — no chat, Vault or
  location access (enforced by RLS: there is no owner bypass on those tables).
- Media lives in private buckets; access is via short-lived signed URLs issued by an
  RPC that re-checks authorisation and Snap viewing state.

## 5. Key domain rules enforced in the database

| Rule | Where |
|---|---|
| Usernames: 3–20 chars, `[a-z0-9._]`, case-insensitive unique | `citext` column + check + unique index |
| Username change cooldown 48 h (owner exempt), old name reserved 30 days | `change_username()` |
| Friend-only access | `are_friends()` used in RLS policies |
| Blocks cut every channel | `is_blocked_either()` in RLS + RPCs |
| Nicknames visible only to creator | RLS `owner_id = auth.uid()` |
| Chat list shows no message bodies | `chat_list()` RPC returns status labels only |
| Message edit window 15 min | `edit_message()` |
| Snap timer 1–10 s or unlimited; one replay; server expiry | `snap_recipients` + `open_snap()` / `close_snap_view()` with `FOR UPDATE` locks |
| Saving only with sender permission | `save_snap()` |
| Storage quotas, pool guards, registration cap | `authorize_upload()`, `platform_usage`, signup trigger |
| Rate limits | `rate_limit_hit()` |
| Privileged actions audited | `audit_log` written inside every admin RPC |

## 6. PWA limitations (documented, not hidden)

- Incoming calls cannot ring like native calls when the app is closed; a push
  notification is the best available signal.
- No background camera, no reliable screenshot detection, no background location.
- Exposure/focus/torch/4K controls appear only when `MediaStreamTrack.getCapabilities()`
  reports them.
- iOS Web Push requires iOS 16.4+ and a Home-Screen-installed PWA.
- Browser storage can be evicted; local-only Memories are labelled as not backed up.
