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
| Migrations (13) apply cleanly | ✅ | shim + real local Supabase |
| RLS on every table, function lockdown | ✅ | tests 10, 60, 80 (catalog checks) |
| API contract: no STABLE function writes (PostgREST read-only) | ✅ | test 80; found a real bug (0011) |
| Rate limiting | ✅ | |
| Free-tier guards: registration cap, pools, quota, egress | ✅ | tests 10, 50 |
| Unconfirmed sign-ups purged after 48 h | ✅ | 0010, test 70, pg_cron job verified |
| Expiry / purge job (`pg_cron`) | ✅ | Schedules verified on the real stack |
| Storage-janitor Edge Function | 🟠 | SQL contract tested; Deno function not written |
| media-url Edge Function (signing) | 🟠 | Authorisation RPCs tested; function not written |
| Realtime: postgres_changes under RLS | ✅ | e2e (friend requests, messages, chat list) |
| Realtime: private broadcast topic authorisation | ✅ | e2e typing indicator + test 90 |
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
| Password reset by email | ✅ | e2e |
| Optional 2FA (TOTP) — app + **server-side enforcement** | ✅ | 0013, test 90, e2e enrol + sign-in |
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
| Remove friend, block, report user | ✅ | UI; block in e2e |
| Private nicknames + colours | ✅ | UI |
| Direct & group conversations | ✅ | DB tested; direct chats in e2e; new-group sheet not yet in e2e |
| Group admin UI (roles, add/remove, transfer, leave) | 🟠 | RPCs tested; UI not built |
| Text messages, realtime, optimistic + idempotent retry | ✅ | e2e |
| Chat list with status labels, no previews; folders; pins; mute | ✅ | e2e (labels) |
| Read status & disappearing modes (after view / 24 h / 7 d / never) | ✅ | e2e switches mode live |
| Edit (15 min), delete tombstones, reply, save | ✅ | edit in e2e |
| Typing indicators (respect privacy setting) | ✅ | e2e |
| Photo/video/voice messages | 🟠 | DB + validation done; needs media-url Edge Function + UI |
| Reactions UI, message search UI, shared media gallery UI | ⬜ | RPCs tested |
| Transcription | ⬜ | On-device only; deferred |

## Phase 3 — Camera & Snaps
| Item | Status | Notes |
|---|---|---|
| Snap delivery, timers, one replay, server sessions, saving, expiry | ✅ | DB (incl. concurrency) |
| Camera preview, front/back, torch (if reported), still capture | ✅ | UI; capture saved locally only |
| Sending/viewing Snaps in UI, video, editors, multi-clip | ⬜ | Needs media upload + media-url |

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
Security review of the DB layer: 🟠 (self-review, mutation tests, real-stack tests; an
independent review is still needed). `npm audit` reports moderate advisories in
**build-time-only** PWA tooling (workbox-build → glob/minimatch); nothing shipped to browsers.
