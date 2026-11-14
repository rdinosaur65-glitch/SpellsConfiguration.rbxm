# PULSE — Implementation checklist

Status key: ✅ implemented & tested · 🟡 implemented, untested · 🟠 partial · ⛔ blocked · ⬜ not started
"Tested" means automated tests ran against real Postgres 16 in this workspace.
Nothing here has run against a live Supabase project yet (none exists).

## Cross-cutting
| Item | Status | Notes |
|---|---|---|
| €0 infrastructure research & decision | ✅ | `INFRASTRUCTURE_ZERO_COST.md` |
| Architecture & stack justification | ✅ | `ARCHITECTURE.md` |
| Environment variables documented | ✅ | `ENVIRONMENT.md`, `.env.example` |
| Security model | ✅ | `SECURITY_MODEL.md` |
| Migrations (9) apply cleanly | ✅ | `scripts/test-db.sh` |
| RLS on every table, function lockdown | ✅ | tests 10, 60; mutation-checked |
| Rate limiting | ✅ | search limit tested; others share the mechanism |
| Free-tier guards: registration cap, pools, quota, egress | ✅ | tests 10, 50 |
| Expiry / purge job | ✅ | tests 30, 40; `pg_cron` schedule only verifiable on Supabase |
| Storage-janitor Edge Function | 🟠 | SQL contract tested; Deno function not written |
| media-url Edge Function (signing) | 🟠 | Authorisation RPCs tested; function not written |
| Realtime: publication + broadcast topic auth | 🟠 | Topic rule tested; live Realtime untested |
| Error monitoring / logging | ⬜ | Plan: Supabase logs + client error table (no paid Sentry) |
| CI | ⬜ | Plan: GitHub Actions free tier runs `test-db.sh` + domain tests |

## Phase 1 — Foundation
| Item | Status | Notes |
|---|---|---|
| Project structure | ✅ | |
| DB schema: profiles, settings, presence, reservations | ✅ | |
| Signup trigger (validation, cap, reservations) | ✅ | |
| Case-insensitive unique usernames | ✅ | |
| 48 h username cooldown, owner exempt, 30-day reservation | ✅ | |
| Column-level update restrictions | ✅ | |
| Appearance settings persisted (sync via DB) | ✅ | DB side; UI not built |
| Session history & remote revocation | ✅ | Against shimmed `auth.sessions`; verify on Supabase |
| Owner identity by UUID | ✅ | |
| Domain rules package (TS) | ✅ | 9 unit tests, strict typecheck |
| Email/password auth with verification, password reset | ⛔ | Supabase Auth config + UI; needs a project |
| Google sign-in | ⛔ | Needs owner's free Google OAuth credentials |
| Apple sign-in | ⛔ | Requires paid Apple Developer membership → not available at €0 |
| Optional 2FA (TOTP) | ⛔ | Supabase Auth MFA + UI |
| Security alerts | ⬜ | |
| Web app shell, navigation, design system, settings UI | ⛔ | npm packages cannot be installed in this workspace (network off) |
| PWA manifest, service worker, offline shell | ⛔ | Same |

## Phase 2 — Friends & messaging
| Item | Status | Notes |
|---|---|---|
| Username search (partial, rate-limited, block-aware) | ✅ | |
| Requests: send/accept/decline/cancel, mutual auto-accept | ✅ | |
| Canonical friendship rows; remove friend | ✅ | |
| Blocking across all endpoints | ✅ | |
| Private nicknames + colours (owner-only visibility) | ✅ | |
| Direct & group conversations, roles, ownership transfer | ✅ | |
| Messages: text/photo/video/voice with media validation | ✅ | |
| Duplicate prevention (client ids), incl. concurrent retries | ✅ | concurrency.sh |
| Chat list with status labels, no previews | ✅ | |
| Read status, after-view / 24 h / 7 d / never expiry | ✅ | |
| Saved messages survive expiry | ✅ | |
| Editing (15 min), deletion tombstones | ✅ | |
| Reactions (expire with parent) | ✅ | |
| Replies | ✅ | |
| Pins (max 3, personal), mute | ✅ | |
| Automatic folders (All/Private/Groups/Unread) | 🟡 | Derivable from `chat_list()` fields; UI pending |
| Message search with filters | ✅ | |
| Shared media gallery | ✅ | test 50 (found and fixed a column bug) |
| Typing / recording indicators | 🟠 | Topic auth tested; client broadcast pending |
| Voice notes recording/waveform/speed | ⬜ | UI |
| Transcription | ⬜ | On-device only; deferred |
| Two-account live realtime verification | ⛔ | Needs Supabase project + UI |

## Phase 3 — Camera & Snaps
| Item | Status | Notes |
|---|---|---|
| Snap delivery to friends and groups | ✅ | |
| Timer 1–10 s / unlimited, video = own length | ✅ | |
| Server-enforced viewing sessions & deadlines | ✅ | |
| Exactly one replay, multi-device concurrency | ✅ | concurrency.sh + mutation check |
| Sender-controlled saving | ✅ | |
| Snap media only during live session | ✅ | |
| Expiry & media release | ✅ | |
| Camera UI, capture, timers, burst, editors, multi-clip | ⬜ | Duration/clip-budget rules done in domain package |

## Phase 4 — Memories (local-first per €0 override)
| Item | Status |
|---|---|
| Upload quota (50 MB/user), pool ceiling, usage meter, dedupe | ✅ |
| Local storage (OPFS/IndexedDB), "not backed up" labels | ⬜ |
| Albums, shared albums, editor, On This Day | ⬜ |
| Private Vault (client-side encryption) | ⬜ (design in SECURITY_MODEL.md) |

## Phase 5 — Stories & engagement
| Stories, audiences, streaks, Pulse Score ledger, Inner Circle, badges, profiles, avatars | ⬜ |
|---|---|

## Phase 6 — Advanced services
| Item | Status |
|---|---|
| Reports (user/message/group) with evidence snapshots | ✅ |
| Owner panel RPCs: search, reports, bans, analytics, audit | ✅ |
| Ban enforcement (state + auth ban + session revocation) | ✅ |
| Account deletion workflow | ✅ |
| Story reporting | ⬜ (Stories not built) |
| Calls (WebRTC, ≤4 mesh), push, map/location, Ghost Mode for location | ⬜ |
| Owner panel UI | ⬜ |

## Phase 7 — Hardening
All items ⬜ except the security review of the DB layer, which is 🟠 (self-review + mutation tests; an independent review is still needed).
