# PULSE — Progress report 2 (2026-11-14)

## Summary
The UI blocker from report 1 is gone: npm packages could be installed and Docker was
available. So this phase (1) ran the whole backend on a **real local Supabase stack**,
(2) built the first working **web app**, and (3) tested it **end-to-end** in a browser
against that stack. Testing at this level found **five real defects** that the shim-based
tests could not see. All are fixed and guarded by tests. Spend so far: **€0**. Nothing
is deployed and no external account was created.

## 1. What now works (tested)
- **Accounts:** sign-up with username, email confirmation (link opened from the captured
  email), sign-in, password reset, change password, **two-step verification (TOTP)**
  enforced by the database, security-alert emails, devices list and remote sign-out,
  account deletion with password re-entry.
- **Friends:** partial username search, live friend requests with a nav badge,
  accept/decline/cancel, private nicknames and colours, remove, block, report.
- **Chats:** label-only chat list (no previews) with All/Private/Groups/Unread folders,
  pins and mute; new groups; realtime messages with optimistic, idempotent sending and
  retry; edit (15 min), delete, reply, save; typing indicator over an authorised
  private channel; disappearing-message modes that switch live for both people.
- **Settings:** theme (dark/light/system), accent, font, bubble style, reduced motion,
  Ghost Mode and privacy toggles, all synced across devices; profile and username.
- **Camera:** preview, front/back switch, torch where the device reports it, still capture
  saved on the device. Sending Snaps is the next phase.
- **PWA:** installable manifest and icons, service worker with offline shell (opens offline
  with the user's own cached profile), update prompt, Cloudflare Pages headers/redirects.

## 2. Defects found by testing on the real stack (all fixed)
| # | Defect | Effect | Fix |
|---|---|---|---|
| 1 | `search_users` / `search_messages` declared STABLE but write the rate-limit table | PostgREST runs STABLE functions read-only → **every search through the API failed** | 0011 makes them VOLATILE; test 80 scans the catalog for any STABLE function that writes (mutation-checked) |
| 2 | Profile row created before email confirmation | An unconfirmed sign-up held its username and a registration slot **forever** | 0010 purges unconfirmed accounts after 48 h (pg_cron, hourly) |
| 3 | Non-friends' profiles are hidden (by design) | The UI **could not show who sent a friend request** | 0010 adds `my_friend_requests()` (minimal cards) and `list_friends()` |
| 4 | `conversations` not in the Realtime publication | Realtime rejected the whole chat channel → **no live messages** | 0012 publishes it (RLS-filtered) |
| 5 | 2FA enforced only by the app | A stolen password could use the API with an `aal1` session | 0013: aal2 required in every RPC, table, Storage read and Realtime topic once 2FA is on; test 90 |

App-level issues found and fixed: duplicate Realtime channel names crashed the app
(blank screen), now unique, with an error boundary as a safety net; the tab bar covered
the message composer; offline error wording; a "Someone" title flash while loading.
Supabase Auth only *sometimes* passes the signup trigger's error code through (otherwise
"Database error saving new user"), so the UI maps both to a username message.

## 3. Database migrations added
0010 app support · 0011 volatility fix · 0012 realtime conversations · 0013 MFA enforcement.

## 4. Tests and results
| Suite | Result |
|---|---|
| `scripts/test-db.sh` (shim, Postgres 16): 9 SQL suites + concurrency | 10/10 pass |
| `scripts/test-supabase-local.sh` (real Supabase: Postgres 17, GoTrue, PostgREST, Realtime, Storage, pg_cron) | 10/10 pass |
| `packages/domain` unit tests + strict typecheck | 9/9 pass, clean |
| `apps/web` strict typecheck + production build | clean (138 KB gzip JS) |
| Playwright e2e (Pixel 7 profile, built app + service worker, real stack) | 7/7 pass, repeated 3× without flakes |
| Mutation checks | test 80 fails without fix #1 |

## 5. Known issues / limits
- **Email at €0:** Supabase's built-in mailer only reaches the project's team. Real users
  need a free SMTP provider (see `INFRASTRUCTURE_ZERO_COST.md` §7).
- After "sign out everywhere else", a revoked device keeps its current access token until
  it expires (≤ 1 h). Sessions and refresh are revoked immediately.
- The chat list subscription receives full message rows for the user's own chats (needed
  for live labels); the UI never displays them in the list.
- CI workflow written but **not yet run**: pushing to GitHub was refused (no GitHub App access).
- `npm audit`: moderate advisories in build-time PWA tooling only.
- With "disappear after viewing", a chat whose messages have all been seen shows "Start
  chatting" again. This is by design and worth a product decision.

## 6. Next
Edge Functions `media-url` and `storage-janitor` → photo/voice messages and Snap
send/view UI → group admin UI → Memories (local-first) → Stories.

## 7. Owner actions (all free)
1. **Connect GitHub access** so the branch can be pushed (Claude GitHub App on the repo).
2. When ready to go live: free Supabase project, free Cloudflare Pages, free SMTP
   provider (stop if any signup asks for a card). Steps in `README.md` and `ENVIRONMENT.md`.
