# PULSE — Implementation checklist

Status key: ✅ implemented & tested · 🟡 implemented, untested · 🟠 partial · ⛔ blocked · ⬜ not started

"Tested" now means three layers, all run in this workspace (report 2):
- **SQL suites** on plain Postgres 16 with a Supabase shim (`scripts/test-db.sh`), and
- the same suites on a **real local Supabase stack** (Postgres 17, GoTrue, PostgREST, Realtime,
  Storage, pg_cron) via `scripts/test-supabase-local.sh`, and
- **Playwright end-to-end** tests driving the built PWA against that stack (`apps/web/e2e`).

Nothing has run against a *hosted* Supabase project yet (none exists; creating one is the owner's step).

## Cross-cutting
| Item | Status | Notes |
|---|---|---|
| €0 infrastructure research & decision | ✅ | `INFRASTRUCTURE_ZERO_COST.md` |
| Architecture & stack justification | ✅ | `ARCHITECTURE.md` |
| Environment variables documented | ✅ | `ENVIRONMENT.md`, `.env.example` |
| Security model | ✅ | `SECURITY_MODEL.md` |
| Migrations (15) apply cleanly | ✅ | shim + real local Supabase |
| RLS on every table, function lockdown | ✅ | tests 10, 60, 80 (catalog checks incl. 2FA + account-state gates, definer RPCs check the caller, indexed FKs) |
| API contract: no STABLE function writes (PostgREST read-only) | ✅ | test 80 now also flags STABLE→VOLATILE calls (caught conversation_gallery, fixed in 0015) |
| Rate limiting | ✅ | Every write RPC; test 75 drives send/edit/react/mute/report/friend-request limits, test 50 search |
| Free-tier guards: registration cap, pools, per-user quotas, egress share, DB-size write guard, daily text quota | ✅ | tests 10, 50, 75 (0014) |
| Unconfirmed sign-ups purged after 6 h (from the latest confirmation email) and not searchable | ✅ | 0010/0015, tests 70, 75 |
| Expiry / purge job (`pg_cron`) | ✅ | Steps isolated (one failure no longer undoes the rest), batched; test 75 forces a failure |
| Storage-janitor Edge Function | ✅ | `supabase/functions/storage-janitor`; pg_cron → pg_net → function (0016, Vault secrets); functions.test.mjs |
| media-url Edge Function (signing) | ✅ | ≤ 60 s URLs, Snap URLs bound to the viewing session; functions.test.mjs + e2e |
| Realtime: postgres_changes under RLS | ✅ | e2e; every subscription filtered to the user; DELETE events no longer published (they bypass RLS) |
| Realtime: private broadcast topic authorisation | ✅ | e2e typing indicator; tests 60, 75 (policies on realtime.messages), 90 |
| Error monitoring / logging | 🟠 | Error boundary + Supabase logs; no client error table yet |
| CI | 🟡 | `.github/workflows/pulse.yml` written; not yet run (push to GitHub was refused) |

## Phase 1 — Foundation
| Item | Status | Notes |
|---|---|---|
| Project structure (npm workspaces) | ✅ | |
| DB schema: profiles, settings, presence, reservations | ✅ | |
| Signup trigger (validation, cap, reservations) | ✅ | |
| Case-insensitive unique usernames, 48 h cooldown, 30-day reservation | ✅ | UI: Settings → Username |
| Domain rules package (TS) | ✅ | Shared by UI; 9 unit tests |
| Email/password sign-up with email confirmation | ✅ | e2e via local mail catcher |
| Password reset by email | ✅ | e2e; token-hash links work across devices/browsers |
| Optional 2FA (TOTP) — app + **server-side enforcement** | ✅ | 0013, test 90 (every admin + direct-auth RPC), e2e enrol, sign-in, and account deletion with 2FA |
| Security alert emails (password, email, 2FA changes) | ✅ | Supabase Auth notifications; e2e checks two of them |
| Session list & remote sign-out | ✅ | e2e across two devices |
| Appearance settings synced across devices | ✅ | e2e |
| Web app shell, navigation, design system, dark/light | ✅ | |
| PWA manifest, service worker, offline shell, update prompt | ✅ | e2e offline reload |
| Google sign-in | ⛔ | Needs owner's free Google OAuth credentials |
| Apple sign-in | ⛔ | Requires paid Apple Developer membership → not available at €0 |

## Phase 2 — Friends & messaging
| Item | Status | Notes |
|---|---|---|
| Username search (partial, rate-limited, block-aware) | ✅ | UI + e2e |
| Requests: send/accept/decline/cancel, mutual auto-accept, live updates | ✅ | UI + e2e |
| Remove friend, block (also from requests/search), unblock list, report user | ✅ | UI; block in e2e; blocks with an existing chat tested (75) |
| Private nicknames + colours | ✅ | UI |
| Direct & group conversations | ✅ | DB tested; direct chats in e2e; new-group sheet not yet in e2e |
| Group admin UI (roles, add/remove, transfer, leave) | 🟠 | RPCs tested; UI not built |
| Text messages, realtime, optimistic + idempotent retry | ✅ | e2e |
| Chat list with status labels, no previews; folders; pins; mute | ✅ | e2e (labels) |
| Read status & disappearing modes (after view / 24 h / 7 d / never) | ✅ | e2e: mode switch announced in chat, Delivered → Opened live; mode fixed per message (75) |
| Edit (15 min), delete tombstones, reply, save | ✅ | edit in e2e |
| Typing indicators (respect privacy setting) | ✅ | e2e, including the privacy toggle off |
| Photo messages (compressed, EXIF stripped, Data saver aware) | ✅ | e2e. Video/voice: DB ready, UI ⬜ |
| Reactions UI, message search UI, shared media gallery UI | ⬜ | RPCs tested |
| Transcription | ⬜ | On-device only; deferred |

## Phase 3 — Camera & Snaps
| Item | Status | Notes |
|---|---|---|
| Snap delivery, timers, one replay, server sessions, saving, expiry | ✅ | DB (incl. concurrency) |
| Camera preview, front/back, torch (if reported), still capture | ✅ | UI; nothing leaves the device until Send |
| Sending photo Snaps (friends + groups, 1–10 s or ∞, saving permission), viewer with one replay | ✅ | e2e with Chromium's fake camera |
| Video Snaps, editors, multi-clip | ⬜ | |

## Phase 4 — Memories (local-first per €0 override)
| Item | Status |
|---|---|
| Upload quota, pool ceiling, usage meter (UI in Settings), dedupe | ✅ |
| Local storage (OPFS/IndexedDB), albums, editor, On This Day, Vault | ⬜ |

## Phase 5 — Stories & engagement
| Stories, audiences, streaks, Pulse Score, Inner Circle, badges, profiles, avatars | ⬜ |
|---|---|

## Phase 6 — Advanced services
| Item | Status |
|---|---|
| Reports (user/message/group) with evidence snapshots | ✅ (user + message reporting in UI) |
| Owner panel RPCs; ban enforcement; account deletion workflow | ✅ (deletion in Settings UI) |
| Calls, push, map/location, owner panel UI | ⬜ |

## Phase 7 — Hardening
Security review: 🟠 → multi-agent adversarial review done (report 3): 97 confirmed findings, all
fixed or documented with tests. Still owed: a human review before inviting real users.
Known limitations (documented, not fixable at €0 or in SQL): typing-indicator payloads are
client-supplied (any member can fake another member typing); a removed member keeps an
already-joined broadcast channel until their token expires (≤1 h); the Turnstile widget is
not rendered by the web app yet; failed attempts inside a rate-limited RPC roll back their
counter (limits count successful calls). `npm audit` reports moderate advisories in
**build-time-only** PWA tooling (workbox-build → glob/minimatch); nothing shipped to browsers.
