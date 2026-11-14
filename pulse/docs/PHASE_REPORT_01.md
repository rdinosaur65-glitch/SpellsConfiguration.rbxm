# PULSE — Progress report 1 (2026-11-14)

## Summary
The €0 architecture is chosen and documented. The backend for Phase 1 and most of
the server side of Phases 2, 3 and 6 is built. All of it was tested on a real
Postgres 16 database with a shim that mimics Supabase. **No user interface exists
yet.** It is blocked because this workspace cannot install npm packages (network
access is off). Nothing is deployed, and no external account was created or used.
Spend so far: €0.

## 1. Features completed (implemented & tested)
- Accounts: signup trigger with username validation, registration cap and reservations;
  case-insensitive unique usernames; 48 h change cooldown (owner exempt); 30-day
  old-name reservation; column-level update restrictions; synced appearance and
  privacy settings; session list and remote revocation.
- Friends: partial username search (rate-limited and block-aware); requests (send,
  accept, decline, cancel, mutual auto-accept); remove friend; blocking across every
  endpoint; private nicknames with colours; presence filtered by Ghost Mode.
- Messaging: direct and group chats with owner/admin/member roles and ownership
  transfer; text/photo/video/voice messages; idempotent sends (also under concurrency);
  chat list with status labels only; read tracking; after-view / 24 h / 7 d / never
  expiry; saved messages; 15-minute edit window; deletion tombstones; reactions;
  replies; pins (max 3); mute; scoped search; shared-media gallery.
- Snaps: delivery to friends and groups; photo timer 1–10 s or unlimited (bounded);
  video timer = clip length; server-side viewing sessions; exactly one replay, proven
  under real concurrent connections; sender-controlled saving; media access only
  during a live session; expiry and media release.
- Media and €0 guards: upload validation (type, size, duration); SHA-256 dedupe;
  reserved-path storage policy; stored size/MIME re-verification; 50 MB per-user
  Memories quota; platform storage-pool ceilings; daily egress budget; usage meter.
- Safety and admin: user/message/group reports with evidence snapshots; owner-only
  RPCs (search, reports, bans, analytics, audit); ban enforcement (state + auth ban +
  session revocation); append-only audit log; account deletion (re-auth → immediate
  disablement → staged purge); Realtime topic authorisation.

## 2. Files created
`docs/` (6 documents), `.env.example`, `supabase/migrations/` (9 migrations,
~2,400 lines of SQL), `supabase/tests/` (shim, helpers, 6 SQL suites, concurrency
script), `scripts/test-db.sh`, `packages/domain/` (shared TypeScript rules + tests).

## 3. Database migrations
0001 foundation · 0002 accounts · 0003 social · 0004 media · 0005 messaging ·
0006 snaps · 0007 safety/admin/deletion · 0008 jobs/realtime · 0009 privileges.

## 4–5. Tests performed and results
| Suite | Result |
|---|---|
| `scripts/test-db.sh`: 6 SQL suites, 188 assertions, on a fresh Postgres 16 cluster | 6/6 pass |
| `concurrency.sh`: parallel Snap open, parallel replay, parallel duplicate message | pass |
| `packages/domain`: 9 unit tests incl. TS↔SQL limit drift check | 9/9 pass |
| `tsc --strict` on domain package | clean |
| Mutation checks (deliberately broken rules) | 4/4 regressions caught* |

\*Removing the Snap row lock alone was not caught at first: a rate-limit row lock was
serialising requests by accident. With both removed, the test sees a double view.
With the lock alone, it sees exactly one. So the row lock is confirmed as the real
guarantee and the test can detect its loss.

Bugs found and fixed by testing:
- Anonymous callers could execute RPCs, because Postgres' default EXECUTE grant to
  PUBLIC cannot be revoked per schema.
- `are_friends(a, b)` and similar helpers would have let any user check arbitrary
  friendships and blocks through the API.
- A column bug in the media gallery.
- The gallery returned empty results to outsiders instead of refusing them.

## 6. Known issues
- The shim is not Supabase. On a real project these still need checking: auth/session
  tables, Storage metadata fields, Realtime Authorization and `pg_cron`.
- Edge Functions (`media-url`, `storage-janitor`, push) are not written yet. Their
  SQL contracts exist and are tested.
- In groups, a block between two members does not hide their messages from each
  other (matches common practice; documented).
- "After viewing" messages disappear as soon as they are read server-side. The client
  must keep already-loaded messages visible until the chat is closed.

## 7. Browser limitations
See `ARCHITECTURE.md §6`: no native-style incoming calls, background camera,
background location or reliable screenshot detection. Camera controls depend on the
device. iOS push needs an installed PWA.

## 8. Remaining work
Every UI item; Edge Functions; Stories, streaks, score, badges, profiles and avatars;
local-first Memories, albums and Vault; calls; push; map; owner panel UI; Phase 7
hardening. Full list in `CHECKLIST.md`.

## 9. External configuration required (all free, all done by the owner)
1. A free **Supabase** account and project (no card), to apply the migrations.
2. A free **Cloudflare** account for Pages hosting (stop if a card is requested).
3. Optional: free Google OAuth credentials; an optional Open Relay TURN key.
4. Not possible at €0: Sign in with Apple (needs a paid Apple Developer membership).
5. To let me build the UI here, **allow package installs in network settings**
   (takes effect in a new chat). Otherwise the UI can be built on your own machine.
