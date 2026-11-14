# PULSE — Security model

## Trust boundaries
- **Browser**: untrusted. Holds only the anon key and the user's JWT.
- **Postgres (Supabase)**: the authority. RLS on every table; all state changes via
  `SECURITY DEFINER` RPCs with `search_path = ''`, which re-check `auth.uid()`,
  account state, friendship, blocks, membership and quotas inside one transaction.
- **Edge Functions**: hold the service-role key; used only for media URL signing,
  storage deletion and push delivery. Each calls an authorisation RPC *with the
  caller's JWT* before using service-role powers.

## Two-step verification (migration 0013)
Once a user has a *verified* TOTP factor, the database requires an `aal2` session
(password + code) everywhere: `assert_active()`/`assert_owner()` (nearly every RPC), the
RPCs that check `auth.uid()` directly, a restrictive `mfa_gate` policy on every public
table and on the media bucket, and Realtime topic authorisation. A password alone yields
`aal1` and is refused with `mfa_required`. Test 80 fails if a new table lacks the gate.

## Function surface
- Every function is closed to `PUBLIC`/`anon` by `20261114000900_privileges.sql`, then
  the RPC list is granted to `authenticated` explicitly. Janitor functions are
  `service_role` only.
- Helpers that answer relationship questions (`are_friends`, `is_blocked_either`,
  `is_member`, `is_owner`) live in the non-exposed `private` schema so they cannot be
  used to probe other users' relationships through the API.

## Client-side data
The browser keeps the Supabase session (localStorage, managed by supabase-js) and a copy
of the user's **own** profile and settings so the offline shell can open. No chats,
friends or media are cached by the app; the service worker precaches only static assets
and never caches API, Auth or Storage responses. Both are cleared on sign-out.

## Account state (migration 0014)
A restrictive `active_gate` policy sits next to `mfa_gate` on every table and on the media
bucket: a suspended, banned or deleting account loses table, Storage and Realtime access
immediately, not when its JWT expires. Its own state is readable only through
`my_profile()`; friends can no longer read anyone's moderation state.

## Abuse controls
- Per-user fixed-window rate limits on every RPC that creates data or can be repeated
  cheaply (messages, edits, deletes, reactions, reads, pins, mutes, mode changes, reports,
  requests, uploads and deletions, Snap opens/saves, media downloads), plus a daily cap of
  2,000 messages that also counts Snap messages and mode-change notices. The remaining
  write RPCs are bounded by those (e.g. confirm_upload by authorize_upload). A refused call
  rolls back its own counter, so limits count calls that pass validation.
- Database-size guard: text and metadata writes are refused above 90% of the 500 MB budget
  (cached size, refreshed by maintenance). Daily text quota per user (2 MB). Edits: at most
  5 per message, no-op edits ignored.
- Search needs ≥ 3 characters, returns ≤ 20 minimal cards, hides blocked, non-active and
  unconfirmed accounts. In search and friend requests a block looks like a missing account
  (`user_not_found`) and a blocked person's pending request reads "declined". A blocked
  person can still infer the block, because their direct chat with the blocker disappears.
- Blocks: the blocked person loses the direct chat entirely (history, roster, settings,
  read receipts, topic, Snaps, live Snap sessions). In groups, each side stops seeing the
  other's messages, reactions and receipts and they are left out of the roster.
- Ending a friendship makes the direct chat read-only (no messages, reactions, typing).
- Co-members cannot read each other's member rows (pins, mutes, wallpaper, last read),
  saves, or read receipts; a sender sees who read their own messages.
- Registration cap (deleting accounts excluded), storage pools, per-user pool shares and a
  per-user share of the daily egress budget protect the free tier.

## Media
- Single private bucket; uploads only into paths reserved by `authorize_upload()`. The
  Storage API re-checks the insert policy with the real size and type after the bytes
  arrive, so an object larger than its reservation (or of another type) is refused;
  `confirm_upload()` re-verifies as defence in depth. At most 5 reservations per user may
  be outstanding; unconfirmed ones are released after 15 minutes.
- No public URLs, no signed URLs and no client read policy on the bucket — not even for
  owners. The media-url function authorises each request with the viewer's JWT (charging
  that download to the viewer's daily share) and streams exactly one copy back, marked
  `no-store`; the app also fetches with `cache: 'no-store'`, so media is not written to the
  browser's disk cache. Snap bytes are released only during a live viewing session and only
  to current members of the chat.
- Deduplicated media shared by several messages is deleted only when nothing references it;
  uploads never attached (and replaced avatars) are reclaimed after a day. Deleted media
  keeps counting against the user's share and the pool until the janitor has removed it.
  Snap media additionally requires a live viewing session and the URL lifetime is
  capped to the session's remaining time.
- Honest limitation: once bytes reach a device they can be captured (screenshots,
  screen recording, devtools). Saving permission is an in-app rule only.

## Owner
- Identified by UUID in `private.platform_config`, never by username.
- Owner RPCs: user search (minimal fields), reports with evidence snapshots, account
  state, aggregate usage, audit log. No owner bypass exists in chat, Snap, Memories,
  Vault or location policies. Every privileged action writes `private.audit_log`,
  which is append-only by trigger.

## Private Vault (design — implemented in Phase 4)
- Vault media is encrypted on the device before storage or backup: AES-256-GCM with a
  random per-item key; item keys are wrapped by a vault key derived from the PIN with
  PBKDF2-SHA-256 (≥ 600,000 iterations) and a random salt. Optional WebAuthn
  (device authentication) can gate unlocking but is not itself the key.
- Cloud backup stores ciphertext only (`vault_backup`, `application/octet-stream`); the
  server never sees PINs or keys. **Not end-to-end encrypted messaging** — it is
  at-rest encryption of the user's own Vault items.
- Limitation: a 4–6 digit PIN is brute-forceable offline if an attacker obtains the
  ciphertext and salt; the UI will recommend a longer passcode. Forgotten PIN = Vault
  content is unrecoverable (by design).

## Account deletion
Re-authentication: a **password** sign-in within 10 minutes (JWT `amr`; verifying or
enrolling a TOTP factor does not count); accounts with 2FA then enter their code in the same
dialog. → profile set to `deleting`, auth ban, all sessions deleted, all media queued →
on the next maintenance run (≤ 5 min) groups are handed to an active member, memberships
end, object paths move to a janitor queue and the rows are deleted (cascade) without
waiting for Storage. The username stays retired for 30 days (no impersonation). The owner
can also delete an account (e.g. a banned one). Report evidence snapshots are retained with the user link
nulled, per the retention policy to be published. Any platform-level backups Supabase
keeps expire on Supabase's own schedule; the privacy policy must say so rather than
promise instant erasure everywhere. (Verify current Free-plan backup terms at launch.)
