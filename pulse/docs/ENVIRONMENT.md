# PULSE — Environment variables

Nothing here costs money. Every value comes from a free account the **owner** creates
(Claude cannot create accounts). If any signup asks for a payment card, stop.

## Web app (`apps/web/.env.local`) — public, shipped to browsers

| Variable | Required | Source | Notes |
|---|---|---|---|
| `VITE_SUPABASE_URL` | Yes | Supabase → Project Settings → API | e.g. `https://abcd.supabase.co` |
| `VITE_SUPABASE_ANON_KEY` | Yes | Same page, "anon / publishable" key | Safe to expose: RLS protects data |
| `VITE_TURNSTILE_SITE_KEY` | Recommended | Cloudflare Turnstile widget (free) | Turn on together with captcha in Supabase Auth |
| `VITE_OWNER_CONTACT` | Recommended | You | How friends reach you (shown on the privacy page), e.g. an email address |
| `VITE_VAPID_PUBLIC_KEY` | For notifications | `node scripts/gen-vapid.mjs` (local, free) | Public half only; without it the Notifications switch is hidden |
| `VITE_TURN_CREDENTIALS_URL` | Future (calls) | Open Relay dashboard (free, 20 GB/month) | Not used by this beta |
| `VITE_STUN_URLS` | Future (calls) | Default `stun:stun.l.google.com:19302` | Not used by this beta |

## Edge Functions (Supabase → Edge Functions → Secrets) — never in the browser

| Variable | Required | Notes |
|---|---|---|
| `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` | Auto-provided by Supabase | Service role used by `media-url` (streaming after an authorisation RPC), `storage-janitor` and `owner-mfa-reset` |
| `VAPID_PUBLIC_KEY`, `VAPID_PRIVATE_KEY` | For notifications | The pair from `node scripts/gen-vapid.mjs`; used by `push-send` |
| `VAPID_SUBJECT` | For notifications | `mailto:` address of a PULSE mailbox (push services may contact it) |
| `PULSE_PUSH_TEST_PREFIXES` | Tests only | Extra allowed endpoint prefixes for a local mock push service — never set in production |
| `TURN_API_KEY` | Future (calls) | Open Relay API key — not used by this beta |
| `JANITOR_SECRET` | Yes | Shared secret between the pg_cron job (Vault) and `storage-janitor` |
| `PULSE_SMTP_HOST`, `PULSE_SMTP_PORT`, `PULSE_SMTP_TLS` | For owner 2FA resets | `smtp.gmail.com`, `465`, `implicit` (ports 25/587 are blocked for Edge Functions) |
| `PULSE_SMTP_USER`, `PULSE_SMTP_PASS` | For owner 2FA resets | A PULSE mailbox and its app password — never the owner's own address |
| `PULSE_SMTP_FROM`, `PULSE_SMTP_FROM_NAME` | For owner 2FA resets | Sender address (the same PULSE mailbox) and name `PULSE` |

## Database configuration (one-time SQL, run by the owner in the SQL editor)

```sql
-- After the owner signs up in the app, record their immutable account id:
update private.platform_config set owner_user_id = '<owner-uuid>';
-- Optional tuning (defaults shown):
update private.platform_config set registration_cap = 50,
  memories_quota_bytes = 52428800, daily_egress_budget_bytes = 73400320,
  daily_egress_user_bytes = 26214400;
```

## Supabase Auth settings (dashboard) — mirror `supabase/config.toml`
- Email confirmations **on**; minimum password length 8, "letters and digits" required.
- Secure password change **on**.
- MFA → TOTP (App Authenticator) **enabled** (free on all plans; phone MFA is a paid add-on — leave off).
- Email notifications **on** for: password changed, email changed, MFA factor enrolled/removed
  (template: `supabase/templates/security_alert.html`).
- Redirect URLs: list your **exact** deployment origin, e.g. `https://pulse-abc.pages.dev/**`.
  Never a wildcard host such as `https://*.pages.dev/**`: anyone can create a `pages.dev`
  site, and a wildcard would let it receive your users' sign-in links.
- Email templates (Auth → Email Templates): paste `supabase/templates/confirmation.html`
  into **Confirm signup** and `supabase/templates/recovery.html` into **Reset password**.
  Their links carry a token hash that the app verifies itself, so they work when the email
  is opened on another device or in another browser (the default PKCE link does not).
- Minimum interval between confirmation/reset emails per user: **60 seconds**.
- Bot protection (Auth → Bot and Abuse Protection): enable **Cloudflare Turnstile** (free)
  for sign-up, password reset and resend. The hosted email cap is project-wide; without a
  captcha, anyone holding the public anon key can use it up and block every confirmation
  and reset email. Put the Turnstile **site key** in the web app's `VITE_TURNSTILE_SITE_KEY`
  (Cloudflare Pages → environment variables) and the **secret key** in the Supabase dashboard.
  Turn both on together: with captcha on and no site key, nobody can sign in.

### Email delivery (required before inviting anyone)
Supabase's built-in mailer only delivers to members of the project's team and is heavily
rate-limited, so real users would never receive their confirmation email. Configure a free
SMTP provider under Auth → SMTP Settings — without a domain of your own, Gmail with an app
password (about 500 a day); with one, Brevo's free plan (300 a day). Step by step in
`docs/LAUNCH_GUIDE.md` §2 and `docs/INFRASTRUCTURE_ZERO_COST.md` §7. The owner creates that account; PULSE
itself needs no paid service.

### Other dashboard notes
- Set Site URL to your exact `*.pages.dev` address.
- Leave Apple/Google providers **disabled** until their credentials exist
  (Apple requires a paid developer account → not available at €0).
- Set the "Secure email change" and "Leaked password protection" options if offered on Free.
- Realtime: if the dashboard offers "private channels only", leave it **off** for now: the
  chat list and chat screen use Postgres-changes channels whose data is protected by RLS;
  only the typing channel (`conv:<id>`) is private.

## Edge Functions (media) — free tier: 500,000 invocations a month
```sh
npx supabase functions deploy media-url storage-janitor owner-mfa-reset
npx supabase secrets set JANITOR_SECRET=<long random string>
# owner-mfa-reset: see docs/LAUNCH_GUIDE.md §5 for the PULSE_SMTP_* secrets
```
Then, once, in the SQL editor (Vault keeps both encrypted; the janitor job is a no-op until
they exist, and it only calls the function when something is waiting to be deleted):
```sql
select vault.create_secret('https://<project-ref>.supabase.co/functions/v1/storage-janitor', 'pulse_janitor_url');
select vault.create_secret('<the same long random string>', 'pulse_janitor_secret');
```
`media-url` needs nothing else: it uses the project's own URL and keys, which Supabase
injects into every function. It streams each photo/Snap itself (one authorised download
per call), so every media view is one function invocation. Locally, `npx supabase functions serve --env-file
supabase/functions/.env` serves all three. The `.env` is git-ignored and holds a throwaway
`JANITOR_SECRET` plus the local mail catcher as SMTP server:
```
PULSE_SMTP_HOST=inbucket
PULSE_SMTP_PORT=1025
PULSE_SMTP_TLS=none
PULSE_SMTP_FROM=no-reply@pulse.local
PULSE_SMTP_FROM_NAME=PULSE
```

## Local tests
| Variable | Default | Purpose |
|---|---|---|
| `PGBIN` | `/usr/lib/postgresql/16/bin` | Postgres binaries for `scripts/test-db.sh` |
| `PULSE_PG_PORT` | `54329` | Port of the throwaway test cluster |

## Local development (free)
`npm run sb:start` runs Supabase in Docker with the settings from `supabase/config.toml`.
`npx supabase status` prints the local URL and anon key (public demo values, local only).
Emails (confirmation, reset, security alerts) are captured at http://127.0.0.1:54324.
