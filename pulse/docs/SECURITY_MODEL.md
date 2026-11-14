# PULSE — Security model

## Trust boundaries
- **Browser**: untrusted. Holds only the anon key and the user's JWT.
- **Postgres (Supabase)**: the authority. RLS on every table; all state changes via
  `SECURITY DEFINER` RPCs with `search_path = ''`, which re-check `auth.uid()`,
  account state, friendship, blocks, membership and quotas inside one transaction.
- **Edge Functions**: hold the service-role key; used only for media URL signing,
  storage deletion and push delivery. Each calls an authorisation RPC *with the
  caller's JWT* before using service-role powers.

## Function surface
- Every function is closed to `PUBLIC`/`anon` by `20261114000900_privileges.sql`, then
  the RPC list is granted to `authenticated` explicitly. Janitor functions are
  `service_role` only.
- Helpers that answer relationship questions (`are_friends`, `is_blocked_either`,
  `is_member`, `is_owner`) live in the non-exposed `private` schema so they cannot be
  used to probe other users' relationships through the API.

## Abuse controls
- Per-user fixed-window rate limits on search, requests, messages, uploads, reports, Snap opens.
- Search needs ≥ 3 characters, returns ≤ 20 minimal cards, hides blocked/non-active accounts.
- A blocked user cannot see the block, find the blocker, message, request, open
  Snaps, or use the conversation's realtime topic.
- Registration cap and storage/egress ceilings protect the free tier.

## Media
- Single private bucket; uploads only into paths reserved by `authorize_upload()`;
  stored size and MIME re-verified by `confirm_upload()`; bucket-level size/MIME limits.
- No public URLs. Viewers get ≤ 60 s signed URLs after an authorisation RPC.
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
Re-authentication within 10 minutes (JWT `amr` timestamp) → profile set to
`deleting`, auth ban, all sessions deleted, all media queued → janitor removes objects
→ rows deleted (cascade). Report evidence snapshots are retained with the user link
nulled, per the retention policy to be published. Any platform-level backups Supabase
keeps expire on Supabase's own schedule; the privacy policy must say so rather than
promise instant erasure everywhere. (Verify current Free-plan backup terms at launch.)
