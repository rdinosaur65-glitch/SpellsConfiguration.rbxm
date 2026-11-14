# PULSE — €0 Infrastructure Decision Record

Status: **Adopted** (2026-11-14). Authorised spend: **€0**. All paid services are denied.

This record follows the six checks required by the €0 override for every provider:
current free terms, card requirement, overage risk, behaviour at the limit, practical
capacity, and resulting limitations. Terms were checked on 2026-11-14 against provider
documentation and recent third-party pricing summaries. **Re-check each provider's
pricing page at signup; if any signup flow asks for a payment card, stop and do not
proceed.**

---

## 1. Summary of choices

| Concern | Choice | Card needed? | Overage charges possible? | At the limit |
|---|---|---|---|---|
| Frontend hosting | Cloudflare Pages (static only, **no Pages Functions**) | Not expected — confirm at signup | No (static requests are free and unlimited) | n/a for static assets |
| Database, Auth, Realtime, Storage, Edge Functions, cron | Supabase **Free plan** | No | **No** on the Free plan | Notification → grace period → service restriction (read-only DB, paused project, or HTTP 402) |
| Object storage for media | Supabase Storage (inside the Free plan, 1 GB total) | No | No | As above |
| Cloudflare R2 | **Rejected** | **Yes** — payment method required to enable | **Yes** — usage above free tier is billed with no hard cap | — |
| Push notifications | Standard Web Push (VAPID) sent from a Supabase Edge Function | No | No (browser push services are free) | Edge Function invocation quota |
| Call signalling | Supabase Realtime broadcast channels | No | No | Realtime quota |
| STUN | Public STUN servers | No | No | No SLA |
| TURN | **Off by default.** Optional: Open Relay (Metered) free tier, owner signup required | No | Reported as no overages on free tier — confirm at signup | Relay stops; calls behind strict NATs fail |
| Group-call SFU | **None** (no free SFU verified). Mesh capped at 4 participants | — | — | — |
| Background jobs | Supabase `pg_cron` + SQL functions | No | No | Runs inside DB quota |
| Domain | Free `*.pages.dev` subdomain | No | No | — |

## 2. Verified provider terms

### Supabase Free plan
- Two active free projects, 500 MB database per project, 1 GB file storage, 5 GB egress
  (+5 GB cached egress), 50,000 monthly active users. Edge Functions: 500,000
  invocations/month. Realtime: 200 concurrent connections.
- **No time limit and no card requirement** on the Free plan.
- **No overage billing on the Free plan.** Supabase states that you are not charged for
  over-usage; instead services are restricted under its Fair Use Policy if you
  consistently exceed quota. Restrictions can include pausing projects, switching
  databases to read-only, or answering API requests with HTTP 402.
- The grace period is effectively one-time; a second overage may be restricted immediately.
- **Free projects pause after 7 days of inactivity.** Data is retained, but the project
  stops serving requests until restored from the dashboard. An actively used friends
  app will not normally hit this, but a quiet week will take PULSE offline.
- Spend Cap is a Pro-plan setting and is irrelevant here: PULSE stays on Free.

### Cloudflare Pages / Workers
- Requests to static assets are free and unlimited on both free and paid plans.
- Pages Functions count against the Workers Free daily quota of 100,000 requests,
  resetting at midnight UTC; when exceeded Cloudflare returns Error 1027 (hard stop,
  no charge).
- Pages: 500 builds/month, 20,000 files per site, 25 MB per file.
- Cloudflare's terms discourage using the CDN for video delivery. PULSE does not serve
  media from Cloudflare — all media comes from Supabase Storage.
- **Decision:** PULSE ships as a fully static SPA. No Pages Functions, no Workers, so the
  100k/day cap does not apply to normal use.

### Cloudflare R2 — rejected
- Free tier: 10 GB-month storage, 1M Class A and 10M Class B operations, free egress.
- Enabling R2 requires adding a payment method, and usage above the free tier is billed
  with no hard cost limit. Fails the €0 override on both counts.

### Open Relay TURN (optional)
- Free tier: 20 GB of TURN relay per month; free signup with an API key; no credit card
  required per the provider. Not enabled until the owner creates an account and sets
  `VITE_TURN_CREDENTIALS_URL`. If the quota runs out, calls that need relaying fail;
  direct peer-to-peer calls are unaffected.

## 3. Practical capacity for PULSE

These numbers are the binding constraints. PULSE enforces them in code (see §5).

| Resource | Free limit | PULSE budget | What that means in practice |
|---|---|---|---|
| File storage | 1 GB total (whole platform) | 400 MB ephemeral (Snaps, Stories, chat media) · 450 MB Memories backup · 50 MB profile assets · 100 MB safety headroom | Cloud backup is a **small** allowance, not 20 GB. Default per-user Memories backup quota: **50 MB**; a global pool guard stops new backups at 90% of 450 MB even if a user has quota left |
| Egress | 5 GB/month | ~160 MB/day budget, tracked server-side when signed URLs are issued | ≈ 1,000 compressed photo views/day **or** ≈ 20 one-minute video views/day |
| Database | 500 MB | Warning at 70%, text-only writes throttled at 90% | Millions of text messages; fine for a friend network |
| Realtime | 200 concurrent connections | — | ≈ 150 simultaneously online users |
| Auth | 50,000 MAU | — | Not the binding constraint |

**Honest conclusion:** at €0, PULSE can reliably serve a **closed community of roughly
20–50 active users** with modest media use. Unlimited public usage cannot be supported
for free. Public registration stays technically open, but the server enforces a
configurable **registration cap (default 50 accounts)** and all quotas below, and the
app tells users plainly when a limit is reached.

## 4. Memories storage model (replaces the 20 GB promise)

1. **Local-first.** Memories are stored on the device in the Origin Private File System /
   IndexedDB. The app requests persistent storage (`navigator.storage.persist()`).
2. **Labelled honestly.** Local-only Memories carry a visible "Not backed up — browser
   storage can be cleared" label. No claim of permanent retention or cross-device sync
   is made for them.
3. **Optional small cloud backup.** Users may back up selected Memories within their
   quota (default 50 MB). Only backed-up Memories sync across devices.
4. **Full storage never deletes.** When a user or the global pool is full, new backups
   pause, existing Memories stay accessible, and the user is notified at 80/90/100%.
5. **Compression and deduplication.** Photos are re-encoded client-side (WebP/JPEG,
   long edge ≤ 2048 px for backup); videos are recorded with capped bitrates. Every
   upload carries a SHA-256 content hash; identical content is stored once per owner.
6. **4K** capture stays available on supported devices for local Memories, but cloud
   backup is down-scaled.
7. **Private Vault** lives locally, encrypted with a key derived from the user's PIN
   (WebCrypto PBKDF2 → AES-GCM). Vault backup to the cloud uploads only ciphertext.

## 5. Hard cost safeguards built into the backend

- Per-user storage quotas and a platform-wide storage ledger, checked transactionally
  before an upload is authorised (`media_assets` + `platform_usage`).
- Global pool guards: uploads are refused when a pool reaches its ceiling; the app
  shows a "service limit reached" state instead of failing silently.
- Daily egress budget: signed-URL issuance records bytes; when the daily budget is
  spent, new media views are deferred until the next UTC day (text keeps working).
- Request rate limits per user per action (`rate_limit_hit`), in the database so they
  apply to every client.
- Registration cap.
- Expiry jobs delete Snaps, Stories and expired chat media promptly, freeing storage.
- Usage dashboard for the owner with free-tier capacity warnings.
- No component ever calls a paid API, and no configuration path enables one.

## 6. Features restricted or deferred at €0

| Feature | Status at €0 | Why |
|---|---|---|
| 20 GB cloud Memories per user | **Replaced** by local-first + 50 MB backup | 1 GB total platform storage |
| Group video calls > 4 people | **Deferred** | Needs an SFU; no verified free SFU |
| Reliable calls behind strict NAT | **Optional** via Open Relay (20 GB/month) | TURN relay costs bandwidth |
| Server-side video transcoding | **Deferred**; client-side compression instead | No free transcoding compute |
| Cloud voice transcription | **Not enabled** | Only on-device options; Chrome's Web Speech API sends audio to Google, so it would need explicit consent |
| Always-on availability | **Not guaranteed** | Free projects pause after 7 idle days; restriction possible if quota is exceeded |
| Backups / point-in-time recovery | **Not provided by the Free plan** | Owner can run `pg_dump` manually (documented in deployment guide) |
| Auth emails to real users via Supabase's built-in mailer | **Not possible** → free SMTP provider needed | See §7 |

## 7. Email delivery (added in report 2)

Found while building sign-up: Supabase's built-in email service only delivers to
addresses on the project's **team**, is best-effort, and is capped at a few emails per
hour ([Supabase: custom SMTP](https://supabase.com/docs/guides/auth/auth-smtp)). Email
confirmation, password reset and security alerts therefore need a custom SMTP server.

€0 option: a free transactional-email tier that needs no payment card, connected in
Supabase → Authentication → SMTP. Brevo documents this integration
([Brevo + Supabase](https://developers.brevo.com/docs/supabase-smtp-integration)); its free
plan has a daily sending cap that fits a small friends-only community. **Verify the free
plan's current terms and that no card is requested at signup; stop if one is.** After
connecting SMTP, keep Supabase's Auth email rate limit low (e.g. 30/hour) so a signup
flood cannot exhaust the provider's daily cap.

Until SMTP is connected, only team members can sign up (fine for the owner's first tests).
