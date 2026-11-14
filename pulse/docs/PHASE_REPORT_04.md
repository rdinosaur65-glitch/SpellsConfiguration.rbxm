# PULSE — Phase report 4: CI green, owner-verified 2FA reset, blocked chats, final review

Repository `rdinosaur65-glitch/SpellsConfiguration.rbxm`, branch
`claude/pulse-project-continuation-ji3lu1`, folder `pulse/`. Nothing has been deployed,
no external account was created and nothing was spent: total cost **€0**.

## 1. GitHub Actions

The `pulse / supabase-e2e` job had failed twice. Both causes were real app bugs, found in
the job logs and reproduced locally:

| Run | Failure | Cause | Fix |
|---|---|---|---|
| #2 | `social.spec` never saw the "quiet typing" message | The message box was `disabled` while a chat loaded, so keystrokes typed in that moment were silently dropped | The box is never disabled; sending waits until the chat has loaded |
| #4 | `social.spec` still listed the chat after a block | A block produces no realtime event, so the chat list was stale | The chat list reloads on every visit and after block/unfriend |
| all | Annotation: Node.js 20 actions deprecated | `actions/checkout@v4`, `setup-node@v4` | Moved to `@v5` (Node 24) |

The new owner-reset integration test needed the Edge Functions to have an SMTP server in
CI; the workflow now points them at the stack's own Mailpit (nothing leaves the runner).

GitHub has confirmed both jobs green on run #10 (`1d1df62`) and run #11 (`fadbfcf`).
The run for the final commit of this phase is reported in the hand-off message.

## 2. Owner-verified two-step-verification reset

Resetting someone else's 2FA (a friend who lost their phone) now needs a code emailed to the
owner. Migration `0021`, Edge Function `owner-mfa-reset`, UI `components/ResetMfa.tsx`.

| # | Requirement | How it is met | Tested by |
|---|---|---|---|
| 1 | Fresh, cryptographically secure six-digit code per attempt | `private.random_six_digits()` — pgcrypto `gen_random_bytes` (OS CSPRNG), rejection sampling for a uniform 000000–999999; one code per request, issued once | test 77 (six digits, one code per request) |
| 2 | Only to the owner's verified email | The database returns only the owner's address, and only if `email_confirmed_at` is set; the function sends there | test 77, functions.test.mjs (target never gets it), e2e |
| 3 | Pending until the correct code | Request → `pending`; nothing changes on the target until `verified` | test 77 ("verification alone changes nothing", "nothing before verification") |
| 4 | 5-minute expiry, single use | `expires_at = sent + 5 min`; a verified/completed request answers `used`; execution only once | test 77 (expiry, replay, single use), functions.test.mjs (replay) |
| 5 | Max 5 wrong attempts; rate limits on new codes | Locked at the 5th wrong code; 5 requests/hour, 20/day, 30 confirms/10 min; wrong codes never raise, so the counter is not rolled back | test 77 (lockout, 6th request refused) |
| 6 | Bound to one target and request | Hash = sha256(request id ‖ code); request bound to the owner who made it; a new request for the target cancels the old one | test 77 (another request's code fails; cancelled) |
| 7 | All verification server-side | Code generated, hashed, checked and executed in SQL; execution and issuing are service-role only; the browser never sees the code or the address | test 77 (users cannot issue/execute), functions.test.mjs (response holds only `request_id`, `expires_in`) |
| 8 | Fresh owner authentication first | Password sign-in within 10 minutes (JWT `amr`) **and** — since 0024 — an aal2 session (the owner must have 2FA on) | tests 77, 90; functions.test.mjs; e2e enters password then the owner's own TOTP |
| 9 | Audit request, outcome, target, completion | `account.mfa_reset.requested / code_sent / code_incorrect / expired / locked / email_failed / verified / completed / user_notified / notify_failed`, each with the target and request id | test 77 (8 actions), functions.test.mjs (6 rows) |
| 10 | Only after success: remove 2FA and revoke sessions | `mfa_reset_execute` runs only for a request verified within 2 minutes; deletes the target's factors and sessions | test 77, functions.test.mjs, e2e |
| 11 | Notify the target without the owner's email | Notice names "the PULSE administrator"; the function **refuses to run** if the SMTP sender or login is the owner's own address | functions.test.mjs (notice text and From; sender check), e2e |
| 12 | Email failure → no reset, no bypass | Delivery failure marks the request `failed`; it can never be confirmed; the UI has no other path | test 77, functions.test.mjs (Mailpit stopped mid-test → 502, request failed, guesses refused, nothing reset) |

The code and the owner's address are never written to frontend code, logs or the audit log.
Production uses the same free Gmail account as Auth email (`PULSE_SMTP_*` secrets, port 465,
see LAUNCH_GUIDE §5); it must be a PULSE mailbox, not the owner's own address.

## 3. Blocked chats with an ×

When you block someone, your direct chat with them stays in your list, labelled **Blocked**,
with an × beside their name. Pressing × removes the chat **from your own list only**. It is a
per-person visibility setting (`hide_chat`, `conversation_members.hidden_at`, migration
0025), not a deletion: the conversation record, every message, receipt, Snap and file stay
exactly as they were, and the other person's chat and history are untouched. The setting is
stored in the database, so it holds on all your devices and after you sign out and back in,
and each participant's setting is independent. Blocking rules are unchanged: while blocked,
the blocked person cannot see or use the chat and neither side can send.

(An earlier version in this phase, migration 0022, erased the chat for both people; at your
request it was replaced — 0025 drops that function.)

Tests: SQL 76 (only the blocker can remove; nothing deleted; the other member's row
untouched; independent for both; returns on a new message or reopening; blocking still stops
sending), e2e `blocking.spec.ts` (Ada blocks and removes → Bea's data untouched → still removed
after Ada signs out and in → after unblocking, Bea sees the full history while Ada's stays
removed → Bea blocks and removes independently → persists after Bea signs in again → shared
messages still in the database) and `social.spec.ts`.

## 4. Final adversarial review and fixes

A multi-agent review of the beta changes reported 17 issues with reproductions (its verify
stage crashed on a script error, so every claim was re-checked by reading the code and, where
possible, by a regression test that failed before the fix):

| Severity | Issue | Fix | Regression test |
|---|---|---|---|
| High | Long names widened lists and sheets past the screen, pushing Block/Report/Pin buttons and the Snap save switch off-screen | Grid tracks `minmax(0, 1fr)`, `min-width: 0` on flexible children | e2e mobile (iPhone SE, 39-character name) |
| Medium | A Snap close racing a download refunded a view whose bytes were served (27/100 attempts) | `authorize_snap_media` locks the recipient row | concurrency race 6 (failed before) |
| Medium | Owner powers worked with a password alone while the owner had no 2FA | `assert_owner` requires aal2 | test 90, functions.test.mjs, e2e owner |
| Medium | Refresh kept messages that had disappeared on the server | Rows are kept only if older than a full page or received live after the refresh began | e2e mobile |
| Medium | Offline messages were sent in parallel and arrived out of order | Per-chat serial queue; any retry re-sends the chat's queue oldest first | e2e mobile (5 messages, server order) |
| Medium | Opening the keyboard hid the newest messages | ResizeObserver keeps the list pinned to the bottom | e2e mobile (Pixel 7, 300 px keyboard) |
| Medium | Sheets taller than the screen could not scroll (Report's Back unreachable) | Sheets capped to the visible height, scroll inside | e2e mobile (375×548) |
| Medium | Offline launch of the installed app showed a spinner for ~7 s | Opens from the cached profile at once, refreshes in the background | e2e security (shell within 3 s) |
| Medium | Egress: media is metered once but leaves Supabase twice | Daily budget 160 → 70 MB, per person 40 → 25 MB; docs rewritten | test 75 |
| Medium | Launch guide said a paused project wakes by itself | Corrected: manual Resume in the dashboard | — |
| Medium | Sign-up open to anyone with the URL | Launch guide §9: cap = invited people, then disable sign-ups | — |
| Low | Member removal racing a read could deadlock | Chat lock taken first everywhere | concurrency race 7 (deadlocked before) |
| Low | "Load earlier messages" kept the place only thanks to scroll anchoring (not Safari) | Restores the previously first message's position after commit | e2e history (with `overflow-anchor: none`) |
| Low | Pinch-zoom re-laid out the app | Viewport tracking ignores zoomed states | — |
| Low | Touch targets under 44 px | Icon buttons, chips, small buttons, text links ≥ 44 px | — |
| Low | Gap above the iOS keyboard | `kb-open` drops the home-indicator padding | — |
| Low | Stale statements in docs | Corrected (functions, env table, migration count, README, Turnstile order) | — |

Also fixed: a 50 MB backup could be uploaded but never downloaded (per-person share smaller
than the largest file) — the first download of a day is now always allowed (0023, test 75);
live rows older than the loaded window no longer slip into a long chat out of order.

## 5. Test results (this workspace, final commit)

| Suite | Result |
|---|---|
| Domain unit tests | 9/9 |
| SQL on plain Postgres 16 + shim (`scripts/test-db.sh`) | 13/13 files (incl. concurrency races 1–7) |
| SQL + Edge Functions on the real local Supabase stack | 14/14 (incl. `functions.test.mjs`: media-url, storage-janitor, owner-mfa-reset with real email) |
| Playwright end-to-end (built PWA + local stack) | 20 passed, 1 skipped (the screenshot capture, by design) |
| GitHub Actions | `unit` ✅ and `supabase-e2e` ✅ confirmed by GitHub on runs #10 and #11 |

## 6. Remaining limitations and risks (honest list)

- Nothing has run on a hosted Supabase project or real phones yet; both are owner steps.
  Safari/WebKit was not available here: iPhone behaviour is reasoned from documented Safari
  behaviour and emulated in Chromium.
- Turnstile is implemented but untested against Cloudflare.
- Typing indicators are client-supplied (a member could fake "X is typing"); a removed
  member keeps an already-joined typing channel until their token expires (≤ 1 h).
- Once bytes reach a device they can be captured (screenshots, modified clients). Snap
  limits are enforced on the server, not against a hostile device.
- Free-plan pause after ~7 idle days needs a manual Resume; egress caps are a target, not a
  guarantee — check Supabase → Usage weekly.
- Sign-up has no invite codes; keep it closed with the cap and the "Allow new users to sign
  up" switch (LAUNCH_GUIDE §9).
- `npm audit`: moderate advisories in build-time PWA tooling only.
- A human security review is still recommended before inviting people.

## 7. Not in this beta (planned)
Video Snaps, voice notes, Stories, streaks, Memories backup and Vault, calls, push
notifications, map/location, reactions/search/gallery UI (the RPCs exist and are tested),
Google sign-in (needs the owner's free OAuth credentials); Apple sign-in is not possible at €0.

## 8. Free-tier capacity (Supabase Free, Cloudflare Pages Free, Gmail SMTP)

| Resource | Free limit | PULSE's own ceiling |
|---|---|---|
| Accounts | 50,000 MAU | `registration_cap` (default 50; set it to the people invited) |
| Database | 500 MB | Refuses new text at 90 %; daily text quota per person |
| File storage | 1 GB | Pools: profile 50 MB, memories 450 MB, ephemeral 400 MB; per-person shares |
| Egress | ~5 GB/month | 70 MB/day media budget, 25 MB/person after the first download (≈ 4.2 GB/month counted twice) |
| Edge Functions | 500,000 calls/month | One call per photo/Snap view; janitor only when something is waiting |
| Realtime | 200 connections, 2 M messages/month | Ample for a friend group |
| Email | Gmail ~500/day | Auth emails + owner-reset codes and notices |
| Hosting | Cloudflare Pages Free | Static PWA |

## 9. Exact owner steps (none done; each is free and needs your OK)
Follow `docs/LAUNCH_GUIDE.md`; in order:
1. Create a free Supabase project (no card), link it, `npx supabase db push`.
2. Gmail account for PULSE with an app password → Supabase Auth SMTP (port 465).
3. Auth settings and the two email templates; minimum 60 s between emails.
4. Optional but recommended: Cloudflare Turnstile (site key + secret).
5. `npx supabase functions deploy media-url storage-janitor owner-mfa-reset`, set
   `JANITOR_SECRET` and the `PULSE_SMTP_*` secrets (a PULSE mailbox, not your own address),
   create the two Vault secrets.
6. Cloudflare Pages: connect the repository, root `pulse`, build `npm run build -w @pulse/web`,
   output `apps/web/dist`, the `VITE_*` variables; set Site/Redirect URL to the exact address.
7. Sign up, set yourself as owner by id, **turn on 2FA** (required for the Owner panel).
8. Smoke test with a second account, then set `registration_cap` to the number of friends,
   invite them, and switch off "Allow new users to sign up" once they have joined.
