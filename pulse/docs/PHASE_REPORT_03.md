# PULSE — Phase report 3: independent review and hardening

## What happened
A multi-agent review read the whole project (SQL, web app, config, tests, docs) through
several lenses and then tried to **reproduce, refute and size** every candidate finding
on throwaway databases and on the local Supabase stack. 97 findings survived (almost all
3 of 3 votes): **1 critical, 19 high, 33 medium, 44 low**. 17 more candidates could not be
verified because the review hit its usage limit; several of those were fixed anyway
(listed at the end).

Everything below was fixed in this phase without any paid service and verified by the
same four test layers as before. Two new migrations carry the database fixes:
`20261114001400_review_hardening.sql` (guards, indexes, RLS) and
`20261114001500_review_rpcs.sql` (RPC rewrites).

## The most important fixes
- **One user could fill the free 500 MB database** (and make it read-only for everyone)
  with unlimited message edits. Edits are now rate-limited and capped per message; there is
  a daily text quota per user and a database-size guard that refuses writes above 90%.
- **Uploads could exceed their reservation** and owners could mint year-long download
  links. The Storage policy now checks the real size and type (the Storage API re-runs it
  after the bytes arrive — verified against the local Storage service), and there is no
  client read policy at all; all downloads go through ≤ 60 s signed URLs that charge egress.
- **Realtime DELETE events bypass RLS** and leaked user ids. DELETEs are no longer
  published (Realtime honours the publication's actions; checked in `realtime.list_changes`).
- **Blocked users kept access to an existing direct chat**, and blocks were ignored in
  groups. RLS now starts from "my conversations, minus blocked chats" and hides blocked
  people's messages, reactions and receipts in groups.
- **Banned/suspended/deleting accounts kept reading until their token expired.** A
  restrictive `active_gate` now applies to every table, the media bucket and topics.
- **Users with 2FA could never delete their account**, and a TOTP step counted as
  "re-authentication". The dialog now does password + code in place, and only a recent
  password sign-in counts.
- **Disappearing messages could stop expiring** (concurrent readers, members leaving,
  toggling the mode) or **expire unseen** (the client marked everything read). Reads are
  serialised per chat, expiry is re-evaluated when members change, the mode is stored per
  message, and the client marks read only what it rendered.
- **RLS had nothing an index could use**: a 32-member group took 5 s to load and an
  unfiltered request ran for 32 s. Policies now lead with an indexed predicate,
  `direct_blocked()` is O(1), and every foreign key with an ON DELETE action is indexed
  (test 80 enforces it — it found one more missing index).
- **Maintenance ran as one transaction**: one failing account deletion undid all expiry.
  Steps are isolated; deletions no longer wait for the (not yet written) storage janitor.

## Verification
| Layer | Result |
|---|---|
| SQL suites on Postgres 16 + shim (`scripts/test-db.sh`) | 11/11 (new suite 75 with 80 assertions; 70, 80 and 90 extended) |
| Same suites on the real local Supabase stack | 11/11 |
| Concurrency (`concurrency.sh`) | 4 races; the new read race fails without the lock (mutation-checked) |
| Domain unit tests | 9/9; the drift test now fails on a changed limit (mutation-checked) |
| Web typecheck | clean |
| Playwright e2e on the built PWA | 8/8 (+1 opt-in screenshot spec): new 2FA account deletion, "Opened" live, mode-change notice, typing privacy |

## Every confirmed finding and its resolution
| # | Severity | Finding | Resolution |
|---|---|---|---|
| 1 | critical | edit_message has no rate limit or edit cap and keeps every previous body forever: one user can fill the 500… | Rate limits (20/min, 300/day), ≤5 edits per message, no-op edits ignored, daily text quota, DB-size guard (0014/0015); test 75 |
| 2 | high | Storage policy accepts objects of any size into a pending reservation, so pool ceilings count declared byte… | Storage insert policy checks the real size/type (Storage re-runs it after upload); verified on the local Storage API; tests 50, 75 |
| 3 | high | Group members reading at the same time can stop disappearing messages from ever expiring | Per-conversation advisory lock in mark_conversation_read; concurrency race 4 (mutation-checked) |
| 4 | high | Realtime DELETE events skip RLS, the MFA gate and blocks, broadcasting user-id primary keys of reads, react… | Publication publishes insert/update only (Realtime honours it, verified in realtime.list_changes) |
| 5 | high | In the default 'after_view' mode, a message can't be reported, saved, replied to or edited once it has been… | after_view keeps a 5-min grace; read messages stay reportable until the purge (1 h); client hides Reply/Save/Edit when expired; test 75 |
| 6 | high | Blocked user keeps access to the direct chat with the blocker: conversation_participants leaks the blocker'… | my_conversation_ids() excludes blocked chats in RLS; roster, settings, reads refuse blocked chats; test 75 |
| 7 | high | Deletion re-auth accepts any fresh amr entry, so verifying or enrolling a TOTP factor bypasses the password… | Re-auth counts only a recent 'password' amr entry; test 75 (stale password + fresh TOTP refused) |
| 8 | high | Users with 2FA can never delete their account: password re-auth drops the session to aal1, request_account_… | Delete dialog does password then TOTP in place (global 2FA prompt suppressed); e2e |
| 9 | high | Chat never catches up after a reconnect or join gap, but markRead still marks the whole conversation read, … | Chat refetches on reconnect/foreground/online and reconciles; reads bounded to rendered range |
| 10 | high | Blocks are only tested before a chat exists: blocking an existing chat, its history, its realtime topic and… | Test 75: block with an existing chat, history, topic, roster, settings, Snaps |
| 11 | high | Test 90 checks only a sample of 2FA (aal2) enforcement: owner/admin RPCs, five direct-auth RPCs and Storage… | Test 90 covers every admin RPC, direct-auth RPCs, Storage and am_i_owner at aal1; test 80 checks definer RPCs verify the caller |
| 12 | high | run_maintenance runs as one transaction: any failure in account hard-delete rolls back all expiry for the w… | run_maintenance isolates every step; deletions per-account subtransactions with attempts/last_error; test 75 forces a failure |
| 13 | high | Unindexed FK columns make every message purge and account hard-delete cost (rows deleted x messages table):… | Indexes on every FK with ON DELETE; test 80 enforces it (found username_reservations) |
| 14 | high | Account deletion never completes: with no storage-janitor the account stays in 'deleting' indefinitely, wit… | Hard delete no longer waits for the janitor (paths go to storage_trash); deleting accounts excluded from the cap; test 60 |
| 15 | high | No per-user or database-size quota on text: send_message within its own limit fills the database in ~8 h, a… | DB-size guard, daily text quota and daily message cap; groups need another member; test 75 |
| 16 | high | Unthrottled no-op writes to Realtime-published tables, plus N² read fan-out, let one member use up the proj… | Rate limits + no-op suppression on pin/mute/read/expiry/create-direct; filtered subscriptions |
| 17 | high | Project-wide auth email cap with no captcha and a 1 s per-user frequency: anyone holding the anon key can b… | max_frequency 60 s; Turnstile documented (dashboard) and config stub; unconfirmed purge 6 h |
| 18 | high | RLS on messages, message_reads, message_reactions and saved_messages has nothing an index can use, so one u… | Policies lead with conversation_id = ANY(my ids) (index), per-row work bounded |
| 19 | high | direct_blocked() is O(members^2) for group chats and runs once per message row, so the app's own chat load … | direct_blocked() O(1) via direct_key; block checks once per statement |
| 20 | high | Chat list subscribes to unfiltered postgres_changes (twice per tab), so Realtime RLS-checks every write on … | One shared LiveProvider; subscriptions filtered (own member rows, own receipts, own chats via id=in.()) |
| 21 | medium | Owner read policy lets users skip the egress budget and mint long-lived signed URLs (free public file hosting) | Owner read policy removed; owners download via authorize_media_access (egress charged, ≤60 s URLs); test 50 |
| 22 | medium | No per-user cap on the ephemeral and profile pools: one user can block all media uploads with reservations … | Per-user ephemeral/profile shares, ≤5 outstanding reservations, 15-min pending TTL; test 75 |
| 23 | medium | Uploaded assets that are never attached (and replaced avatars or banners) are never reclaimed | Maintenance reclaims unreferenced uploads after 24 h; test 75 |
| 24 | medium | Deduplicated media shared by several messages or Snaps is deleted when any one of them expires or is deleted | Media released only when unreferenced (asset_referenced); open_snap checks media; test 75 |
| 25 | medium | Platform-wide daily egress budget has no per-user share (and authorize_snap_media no rate limit); one user … | Per-user daily egress share, 10-min re-fetch dedupe, authorize_snap_media rate limit; test 75 |
| 26 | medium | A blocked user can detect the block: 'not_allowed' error codes and their own request turning 'cancelled' | Block looks like a missing account; blocked person's request reads 'declined'; tests 20, 75 |
| 27 | medium | Disappearing messages never expire once the last unread member leaves, is removed or is suspended | apply_expiry() re-runs on leave, removal, suspension and deletion; suspended members ignored; test 75 |
| 28 | medium | A recipient or group admin can silently make disappearing messages permanent by toggling the expiry mode | Expiry mode stored per message; mode changes announced as system messages; test 75, e2e |
| 29 | medium | A save by someone who has left the group keeps an expired message alive forever, and nobody can remove it | Leaving/removed members' saves and reactions are deleted; test 75 |
| 30 | medium | Co-members can read, and receive live, each member's last_read_at, read_at, mute, pin and wallpaper, bypass… | Member rows and saves self-only; receipts visible to reader and sender only; test 75 |
| 31 | medium | Blocks are ignored in group chats: blocked users read, react to, message, see typing, Snaps and profile cha… | Group blocks hide messages, reactions, receipts and roster both ways; Snap fan-out skips them; test 75 |
| 32 | medium | Removing a friend does not end the direct chat: the ex-friend keeps messaging, read receipts and profile-ca… | Direct chats need friendship to post/react/type (read-only after unfriending); test 75 |
| 33 | medium | Deleting a Snap message ('Delete for everyone') doesn't unsend the Snap; recipients can still open it and f… | Deleting a Snap message expires that chat's recipients and releases media; open_snap refuses; test 75 |
| 34 | medium | conversation_gallery is still STABLE but writes the rate-limit table through search_messages, so it always … | conversation_gallery rewritten without search_messages; test 80 flags STABLE→VOLATILE calls |
| 35 | medium | report_user lets anyone, including a blocked user or a stranger, read a target's friends-only bio and curre… | Reporters cannot select evidence/notes (column grants); stranger reports snapshot the minimal card; test 75 |
| 36 | medium | Banned, suspended and deleting accounts can keep reading chats via table RLS and Realtime until the JWT exp… | active_gate restrictive policy on every table and the bucket; test 75; test 80 enforces presence |
| 37 | medium | Permanent bans use banned_until = 'infinity', which GoTrue (pgx v4) can't read, breaking Auth admin APIs | banned_until = now() + 100 years; test 60 |
| 38 | medium | Stale needsMfa: after 2FA is turned on from another device, this device stays in the app at aal1 with no wa… | rpc() emits mfa_required → session refresh + re-check; re-check on foreground |
| 39 | medium | PKCE password-reset link always fails when opened in a different storage context (iOS home-screen PWA → Saf… | Token-hash email templates + verifyOtp in the app; e2e (reset and confirmation) |
| 40 | medium | Initial load shows only the newest 200 messages, but mark_conversation_read marks the whole backlog read an… | mark_conversation_read(p_conv, p_up_to, p_from) marks only the rendered range; test 75 |
| 41 | medium | Long messages go blank on screen when a realtime UPDATE arrives without the TOASTed body column | Realtime UPDATEs are merged into the existing row |
| 42 | medium | Every realtime UPDATE from another member fires a separate mark_conversation_read RPC, so one read can trig… | markRead only for INSERTs, debounced/coalesced, flushed on leaving the chat |
| 43 | medium | Offline sends are never retried and are lost on navigation, although the app says they will send | In-memory outbox retried on reconnect and chat open; banner text corrected |
| 44 | medium | Button's busy guard is overridden whenever a caller passes `disabled`, allowing double submits (duplicate g… | Button applies busy after caller props; NewGroup guards re-entry |
| 45 | medium | Camera stream leaks if getUserMedia resolves after unmount or after the page is hidden | Camera start() generation counter stops late streams |
| 46 | medium | No way to block or report a non-friend; a declined requester can re-send requests indefinitely | Block/report from requests and search results |
| 47 | medium | Optimistic settings rollback restores a stale full snapshot and can leave Ghost Mode showing ON while the s… | Settings rollback restores only the patched keys |
| 48 | medium | Concurrency race 3 passes even when the concurrent retry fails with a duplicate-key error | Race 3 requires both callers to get the id; races 1–2 assert the loser's code |
| 49 | medium | 'stale login refused' sends no amr at all, so the 10-minute re-auth window is never tested | Test 75: 11-minute and stale-password+fresh-TOTP cases; 9-minute case succeeds |
| 50 | medium | The realtime.messages broadcast policies are never exercised; tests call the helper directly and the e2e on… | Test 75 exercises realtime.messages policies (outsider read/insert, member insert) |
| 51 | medium | 'cannot delete twice / others' combines two conditions, so deleting someone else's live message is never te… | Split into 'others' message' and 'twice' cases; test 30 |
| 52 | medium | The domain-to-SQL limits drift test is partly vacuous (substring matches, hard-coded literals, unchecked li… | Drift test rewritten with context regexes built from LIMITS (mutation-checked) |
| 53 | medium | Test 80's read-only check only catches three named helpers; indirect writes through other private functions… | Test 80 joins prosrc calls to pg_proc volatility |
| 54 | low | Race between accepting a request and blocking leaves the friendship in place, and it silently returns after… | Pair-level advisory lock in request/accept/remove/block/unblock |
| 55 | low | Rate-limit hits are rolled back whenever the RPC later raises, so failed attempts are never counted | Documented (limits count calls that pass validation); attempts that fail roll back by design |
| 56 | low | user_settings.notifications is client-writable jsonb with no size limit | CHECK on notifications shape and size; test 75 |
| 57 | low | Memories pool guard refuses at 100% while the documented guard and the UI 'pool_full' flag use 90% | Memories pool refuses at 90% |
| 58 | low | A member removed from a group can still edit their earlier messages | edit_message requires the sender can still post |
| 59 | low | A concurrent leave or removal during ownership transfer leaves the group with no owner | Both member rows locked; update requires left_at is null |
| 60 | low | conversation_gallery filters only the 100 most recent messages | Gallery filters before the limit |
| 61 | low | chat_list keeps showing 'unread' after a received Snap has been opened | unread mirrors the Snap-opened rule |
| 62 | low | Group 'Opened' label stays at 'Delivered' forever when someone joined after the message | 'Opened' waits only for members who were there |
| 63 | low | The owner can 'restore' an account that is being deleted, and it is then silently hard-deleted | admin_set_account_state refuses 'deleting' accounts; test 75 |
| 64 | low | A block doesn't end a live Snap viewing session; media URLs and saving still work | authorize_snap_media/save_snap check blocks; block_user ends live sessions |
| 65 | low | send_snap isn't idempotent under concurrent retries; the second call raises a raw unique_violation | send_snap insert … on conflict do nothing + re-select |
| 66 | low | Owner identity is revealed to an aal1 (password-only) session: am_i_owner is not MFA-gated and assert_owner… | am_i_owner requires mfa_satisfied; assert_owner checks MFA first; tests 75, 90 |
| 67 | low | purge_unconfirmed_signups keys on created_at, so it can delete a user who has just been sent a valid confir… | Purge keys on coalesce(confirmation_sent_at, created_at); test 75 |
| 68 | low | Friends can read a user's moderation state and an expired status through the profiles table | account_state column not selectable by clients; expired status cleared by maintenance |
| 69 | low | recovering flag survives sign-out: the next account to sign in is forced onto ResetPassword with no exit | recovering cleared on SIGNED_OUT |
| 70 | low | registration_closed (capacity reached) is reported as 'That username is taken' | Generic signup error no longer claims 'username taken' only |
| 71 | low | Banned, suspended, deleting and rate-limited sign-ins show 'Something went wrong. Please try again.' | user_banned and request-rate-limit messages mapped |
| 72 | low | load() has no staleness guard: late responses overwrite state and rewrite the 'cleared on sign-out' cache a… | load() sequence guard; cache written only by the latest load |
| 73 | low | ForgotPassword says 'a reset link is on its way' when the request never reached the server (offline or netw… | Forgot-password shows network/rate-limit errors instead of success |
| 74 | low | Typing indicator trusts a client-supplied user_id, so any member can fake another member typing | Typing from non-participants ignored; payload trust documented as a limitation |
| 75 | low | New messages are marked read, and in after_view expired, even while the user is scrolled up and has not see… | Reads only while scrolled to the bottom |
| 76 | low | The 'Show when I'm typing' privacy toggle is not honoured in other open tabs or devices until reload | Settings sync across tabs (storage event) and on foreground |
| 77 | low | Friend-request state never resyncs after missed realtime events (badge and lists stay stale) | Requests re-read on reconnect and foreground |
| 78 | low | Friends list reload is keyed on requests.length, so removals by the other side are never reflected | Friends re-read on any request change and on foreground |
| 79 | low | Username search shows stale results from out-of-order or cancelled requests | Search responses sequenced; stale ones dropped |
| 80 | low | Searching '@username' (the format the app displays everywhere) always returns no results | '@name' accepted (client and server) |
| 81 | low | Block is irreversible: no blocked-users list or unblock action anywhere in the app | Blocked list with Unblock in Settings (my_blocked_users) |
| 82 | low | Report reason taps file a report immediately, with no confirmation and no in-flight guard | Report needs a confirmation step; in-flight guard |
| 83 | low | Nickname input in the friend sheet has no accessible name | Nickname input labelled |
| 84 | low | Friend options sheet is not a usable modal dialog for keyboard and screen-reader users | Accessible Sheet (aria-modal, focus trap, Escape, focus restore) |
| 85 | low | Every selectable accent colour fails text contrast with the hard-coded white foreground | Accent backgrounds/text darkened to ≥4.5:1 contrast |
| 86 | low | Ghost Mode leaves 'Show when I'm online' / 'Show last active' rendered ON with no explanation | Ghost Mode shows dependent toggles off with an explanation |
| 87 | low | 2FA status shows 'Off' and offers setup when listFactors fails (e.g., offline) | 2FA status shows an error and retry when it cannot be read |
| 88 | low | Saved settings are not written to the offline cache, so offline launches restore stale appearance and priva… | Saved settings written to the offline cache |
| 89 | low | No Content-Security-Policy on the SPA, so any XSS can send the stored refresh token to any origin | Content-Security-Policy added to _headers |
| 90 | low | ENVIRONMENT.md redirect-URL instruction reads as a `https://*.pages.dev/**` wildcard, which would let any p… | Exact redirect URL documented; wildcard warned against |
| 91 | low | ENVIRONMENT.md says the built-in mailer is enough, contradicting INFRASTRUCTURE_ZERO_COST §7; README deploy… | SMTP required for real users documented (ENVIRONMENT, README) |
| 92 | low | .gitignore does not exclude `.env` files, including supabase/functions/.env where the Supabase CLI loads Ed… | .env files ignored |
| 93 | low | The e2e test does not check the live disappearing-mode switch or the 'Opened' read status, though the check… | e2e checks the mode-change notice and Delivered → Opened |
| 94 | low | Only 1 of 16 rate limits is tested, though rate limiting is marked tested | Test 75 drives six more rate limits |
| 95 | low | Test 70's ghost-mode and nickname-privacy checks pass if the row is missing entirely | Checks require the row to exist |
| 96 | low | concurrency.sh writes fixed /tmp/race* files, so concurrent runs overwrite each other's results | Race files in mktemp dir |
| 97 | low | The typing-privacy toggle is claimed as e2e-tested but never exercised | e2e turns typing privacy off and checks no indicator |

## Unverified candidates (review stopped at its limit) — handled anyway
- One reaction per person per message (bounded rows).
- Usernames of deleted accounts are retired for 30 days.
- Group ownership on deletion goes to an **active** member.
- `request_account_deletion` is idempotent (one audit row).
- Owner can delete an account (`admin_delete_account`), e.g. a banned one.
- Unconfirmed sign-ups are not searchable and cannot receive requests; purged after 6 h.
- Display names cannot contain control, zero-width or bidi characters; group authors show @username.
- Empty groups and old `deleted` media rows are cleaned up.
- Documented, not fixable in SQL at €0: broadcast payloads are client-supplied; a removed
  member keeps an already-joined broadcast channel until the token expires (≤ 1 h);
  GoTrue keeps the first password for a re-signup of an unconfirmed email; topic-level
  broadcast rate limits are Realtime's tenant limits.

## Owner actions (unchanged, plus two)
Everything from report 2, plus: paste the two email templates and enable Cloudflare
Turnstile in the Supabase dashboard (`docs/ENVIRONMENT.md`), and use an exact redirect URL.
