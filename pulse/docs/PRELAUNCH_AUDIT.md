# PULSE — pre-launch audit (private beta)

Four independent reviews (database security, app reliability, Edge Functions/secrets/PWA,
iPhone screenshots at 320 / 375 / 393 px with real safe-area insets), every finding
re-checked before fixing. PULSE stayed offline throughout; only disposable test
accounts were used (local stack; on the live project they were deleted afterwards).

## Fixed
Security (database, migration 0033, regression tests `supabase/tests/82_audit_fixes.sql`):
- A suspended/banned account could still delete its messages and media for up to an hour
  (evidence wiping). Now requires an active account.
- Avatar/banner could point at any asset (e.g. a Snap, keeping its bytes past expiry).
  Now only the user's own uploaded profile picture.
- Friend nicknames could be moved to non-friends. Now friends only.
- A blocked sender could still read the blocker's Snap delivery/opened state. Hidden.
- Presence of suspended/banned friends was shown. Hidden.
- App error reports could outlive 14 days. Daily purge job + 14-day window.
- A deleted account's username stayed on its invitation. Cleared.
- Malformed push keys were accepted (slowed every push batch); a signed-in device's
  push subscription could be taken over by saving its endpoint. Both closed.

Edge Functions:
- Database calls time out (8 s), Storage waits time out, SMTP connect times out (10 s).
- Internal database error text no longer reaches the browser.
- Push subscriptions that can never work are removed instead of retried.
- `build-pages.sh` builds to a temp folder and only replaces `docs/` after the secret scan;
  the scan also covers access tokens and the VAPID private key.

App reliability:
- Voice notes no longer send themselves at the 2-minute limit; leaving the app cancels a
  recording.
- First chat load can no longer drop a message that arrived meanwhile; a just-sent
  message can no longer show twice.
- A queued message can never be sent under another account that signed in mid-upload.
- No duplicate Snaps after cancelling a slow send; Cancel is disabled while sending.
- Typing indicator survives a quick Back-and-return; media cache bounded; own media
  previews kept (no second download); failed edits keep the text; owner panel ignores
  stale answers; milestone card dismissible; screen readers hear only new messages.

iPhone UI:
- 🔥 badge no longer cut off by long names; friend requests, chat rows and owner panel
  rows no longer squeeze or overlap on small phones; header height includes the safe area;
  dark native controls; 44 px controls in Settings; readable "Save to device"; voice-note
  bubble; proper reply quote; stronger contrast for small grey text and avatars; 44 px
  auth links; incomplete invitation links explained.

## Accepted risks (documented, not changed)
- Daily download budget (70 MB) is charged when a download is authorised, so two invited
  members acting deliberately could use it up for a day. Friends-only beta; the owner sees
  usage and can suspend; the budget can be raised (free plan allows ~5 GB a month).
- A Snap can be fetched more than once during one viewing session (still only two
  sessions). A screenshot defeats this anyway.
- CI actions are pinned to version tags, not commit hashes.
- The default accent is violet (current branding), not pure black-and-white.
- No iOS launch-screen images (iOS shows a plain screen while the app starts).
- "Memories" is device-only by design; profile pictures are initials (no photo upload UI).
