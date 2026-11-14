# PULSE — Environment variables

Nothing here costs money. Every value comes from a free account the **owner** creates
(Claude cannot create accounts). If any signup asks for a payment card, stop.

## Web app (`apps/web/.env.local`) — public, shipped to browsers

| Variable | Required | Source | Notes |
|---|---|---|---|
| `VITE_SUPABASE_URL` | Yes | Supabase → Project Settings → API | e.g. `https://abcd.supabase.co` |
| `VITE_SUPABASE_ANON_KEY` | Yes | Same page, "anon / publishable" key | Safe to expose: RLS protects data |
| `VITE_VAPID_PUBLIC_KEY` | For push | Generated locally (`npx web-push generate-vapid-keys`) | Public half only |
| `VITE_TURN_CREDENTIALS_URL` | Optional | Open Relay dashboard (free, 20 GB/month) | Leave empty → STUN-only calls |
| `VITE_STUN_URLS` | No | Default `stun:stun.l.google.com:19302` | Comma-separated |

## Edge Functions (Supabase → Edge Functions → Secrets) — never in the browser

| Variable | Required | Notes |
|---|---|---|
| `SUPABASE_URL`, `SUPABASE_ANON_KEY`, `SUPABASE_SERVICE_ROLE_KEY` | Auto-provided by Supabase | Service role used only by `storage-janitor` and `media-url` signing |
| `VAPID_PRIVATE_KEY` | For push | Private half of the VAPID pair |
| `VAPID_SUBJECT` | For push | `mailto:` address of the owner |
| `TURN_API_KEY` | Optional | Open Relay API key; used to mint short-lived TURN credentials |

## Database configuration (one-time SQL, run by the owner in the SQL editor)

```sql
-- After the owner signs up in the app, record their immutable account id:
update private.platform_config set owner_user_id = '<owner-uuid>';
-- Optional tuning (defaults shown):
update private.platform_config set registration_cap = 50,
  memories_quota_bytes = 52428800, daily_egress_budget_bytes = 167772160;
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
  and reset email. (The web app does not render the Turnstile widget yet — see CHECKLIST.)

### Email delivery (required before inviting anyone)
Supabase's built-in mailer only delivers to members of the project's team and is heavily
rate-limited, so real users would never receive their confirmation email. Configure a free
SMTP provider under Auth → SMTP Settings (for example Brevo's free plan, about 300 emails a
day) — see `docs/INFRASTRUCTURE_ZERO_COST.md` §7. The owner creates that account; PULSE
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
npx supabase functions deploy media-url storage-janitor
npx supabase secrets set JANITOR_SECRET=<long random string>
```
Then, once, in the SQL editor (Vault keeps both encrypted; the janitor job is a no-op until
they exist, and it only calls the function when something is waiting to be deleted):
```sql
select vault.create_secret('https://<project-ref>.supabase.co/functions/v1/storage-janitor', 'pulse_janitor_url');
select vault.create_secret('<the same long random string>', 'pulse_janitor_secret');
```
`media-url` needs nothing else: it uses the project's own URL and keys, which Supabase
injects into every function. Locally, `npx supabase functions serve --env-file
supabase/functions/.env` serves both (the `.env` holds a throwaway `JANITOR_SECRET` and is
git-ignored).

## Local tests
| Variable | Default | Purpose |
|---|---|---|
| `PGBIN` | `/usr/lib/postgresql/16/bin` | Postgres binaries for `scripts/test-db.sh` |
| `PULSE_PG_PORT` | `54329` | Port of the throwaway test cluster |

## Local development (free)
`npm run sb:start` runs Supabase in Docker with the settings from `supabase/config.toml`.
`npx supabase status` prints the local URL and anon key (public demo values, local only).
Emails (confirmation, reset, security alerts) are captured at http://127.0.0.1:54324.
