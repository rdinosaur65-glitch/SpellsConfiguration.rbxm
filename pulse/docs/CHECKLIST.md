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
| Environment variables documented | ✅ | `ENVIRONMENT.md`, `.env.example`; owner walkthrough in `LAUNCH_GUIDE.md` |
| Privacy notice and house rules page | ✅ | `/privacy`, linked from sign-up and Settings (owner should review) |
| Bot protection (Turnstile) | 🟡 | Widget on sign-up/sign-in/reset/resend/re-auth when `VITE_TURNSTILE_SITE_KEY` is set; not exercised against Cloudflare here |
| Security model | ✅ | `SECURITY_MODEL.md` |
| Migrations (24) apply cleanly | ✅ | shim + real local Supabase (CI runs both) |
| RLS on every table, function lockdown | ✅ | tests 10, 60, 80 (catalog checks incl. 2FA + account-state gates, definer RPCs check the caller, indexed FKs) |
| API contract: no STABLE function writes (PostgREST read-only) | ✅ | test 80 now also flags STABLE→VOLATILE calls (caught conversation_gallery, fixed in 0015) |
| Rate limiting | ✅ | Every data-creating or cheaply repeatable RPC (others bounded by those); tests 50, 75, 76 |
| Free-tier guards: registration cap, pools, per-user quotas, egress share, DB-size write guard, daily text quota | ✅ | tests 10, 50, 75 (0014) |
| Unconfirmed sign-ups purged after 6 h (from the latest confirmation email) and not searchable | ✅ | 0010/0015, tests 70, 75 |
| Expiry / purge job (`pg_cron`) | ✅ | Steps isolated (one failure no longer undoes the rest), batched; test 75 forces a failure |
| Storage-janitor Edge Function | ✅ | `supabase/functions/storage-janitor`; pg_cron → pg_net → function (0016, Vault secrets); functions.test.mjs |
| media-url Edge Function | ✅ | Streams one copy per authorisation (no reusable URLs), no-store, Snap bytes only in a live session for current members; functions.test.mjs + e2e |
| Realtime: postgres_changes under RLS | ✅ | e2e; every subscription filtered to the user; DELETE events no longer published (they bypass RLS) |
| Realtime: private broadcast topic authorisation | ✅ | e2e typing indicator; tests 60, 75 (policies on realtime.messages), 90 |
| Error monitoring / logging | 🟠 | Error boundary + Supabase logs; no client error table yet |
| CI | ✅ | `.github/workflows/pulse.yml`: `unit` (domain, build, SQL on shim) and `supabase-e2e` (real stack, Edge Functions with Mailpit, Playwright) — green on GitHub (report 4) |

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
| Lost authenticator: owner-assisted 2FA reset — code emailed to the owner, 5 min, single use, 5 tries, audited, target notified | ✅ | 0021, owner-mfa-reset, tests 77, 90, functions.test.mjs, e2e owner |
| Appearance settings synced across devices | ✅ | e2e |
| Web app shell, navigation, design system, dark/light | ✅ | |
| PWA manifest, service worker, offline shell, update prompt | ✅ | e2e offline reload |
| Install guidance (Android prompt, iOS Share → Add to Home Screen), iOS home-screen meta | ✅ | Settings → Install PULSE |
| Mobile layout: safe areas, keyboard-aware height (visualViewport), auto-growing composer, sheets above the tab bar | ✅ | Screenshots at 375×667 and 360×640; real-device check still owed |
| Google sign-in | ⛔ | Needs owner's free Google OAuth credentials |
| Apple sign-in | ⛔ | Requires paid Apple Developer membership → not available at €0 |

## Phase 2 — Friends & messaging
| Item | Status | Notes |
|---|---|---|
| Username search (partial, rate-limited, block-aware) | ✅ | UI + e2e |
| Requests: send/accept/decline/cancel, mutual auto-accept, live updates | ✅ | UI + e2e |
| Remove friend, block (also from requests/search), unblock list, report user | ✅ | UI; block in e2e; blocks with an existing chat tested (75) |
| Blocked chat stays for the blocker; × removes it from that person's list only (per-member setting, nothing deleted, persists across sign-in, independent for both people; returns on a new message and stays; blocking keeps the other person's saves) | ✅ | 0025, 0027, test 76, concurrency race 8, e2e blocking + social |
| Owner panel requires the owner's own 2FA (aal2) | ✅ | 0024, tests 90, functions.test.mjs, e2e owner |
| Final review fixes: Snap view race, member-removal deadlock, egress budget for double metering | ✅ | 0024, concurrency.sh races 6–7, test 75 |
| Small phones: long names, tall sheets, 44 px touch targets, keyboard keeps newest message, pinch-zoom | ✅ | e2e mobile.spec.ts (iPhone SE, Pixel 7, 375×548) |
| Offline messages keep their order; refresh drops disappeared messages; "Load earlier" keeps place without scroll anchoring | ✅ | e2e mobile.spec.ts, history.spec.ts |
| Installed app opens offline at once (cached profile, refreshed in background) | ✅ | e2e security (shell within 3 s) |
| Private nicknames + colours | ✅ | UI |
| Direct & group conversations | ✅ | DB tested; direct chats and the new-group sheet in e2e |
| Group admin UI (roles, add/remove, transfer, leave, rename, report, shared photos) | ✅ | e2e (create → roles → remove → rename → transfer → leave) |
| Text messages, realtime, optimistic + idempotent retry | ✅ | e2e |
| Offline queue (in memory, per account, flushed on reconnect from any screen) | ✅ | |
| Long chats: load earlier messages | ✅ | e2e (230 messages) |
| Chat list with status labels, no previews; folders; pins; mute | ✅ | e2e (labels) |
| Read status & disappearing modes (after view / 24 h / 7 d / never) | ✅ | e2e: mode switch announced in chat, Delivered → Opened live; mode fixed per message (75) |
| Edit (15 min), delete tombstones, reply, save | ✅ | edit in e2e |
| Typing indicators (respect privacy setting) | ✅ | e2e, including the privacy toggle off |
| Photo messages (compressed, EXIF stripped, Data saver aware) | ✅ | e2e. Video/voice: DB ready, UI ⬜ |
| Reactions (one per person, live), message search (this chat with jump-to-message, all chats, saved only), photos/links/saved view | ✅ | e2e extras.spec.ts; RPCs tested in SQL |
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
| Owner panel UI (usage, reports, suspend/ban/restore/delete, audit log) | ✅ (e2e) |
| Push notifications (Web Push/VAPID; new chats, Snaps, friend requests; per-category settings; mutes/blocks respected; no message text) | ✅ (0028, push-send; tests 78, functions.test.mjs with a mock push service, e2e push) |
| Calls, map/location | ⬜ |

## Phase 7 — Hardening
Security review: 🟠 → multi-agent adversarial reviews done (report 3: 97 confirmed findings;
report 4: 17 more on the beta changes), all fixed or documented with tests. Still owed: a human review before inviting real users.
Known limitations (documented, not fixable at €0 or in SQL): typing-indicator payloads are
client-supplied (any member can fake another member typing); a removed member keeps an
already-joined broadcast channel until their token expires (≤1 h); the Turnstile widget is
implemented but not exercised against Cloudflare from this sandbox; failed attempts inside a rate-limited RPC roll back their
counter (limits count successful calls). `npm audit` reports moderate advisories in
**build-time-only** PWA tooling (workbox-build → glob/minimatch); nothing shipped to browsers.
