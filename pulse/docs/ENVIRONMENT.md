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
- Redirect URLs: your `*.pages.dev` address (`/**`) and `/reset-password`.

### Other dashboard notes
- Enable email confirmations; set Site URL to the `*.pages.dev` address.
- Leave Apple/Google providers **disabled** until their credentials exist
  (Apple requires a paid developer account → not available at €0).
- Set the "Secure email change" and "Leaked password protection" options if offered on Free.
- Built-in email sending on Free is rate-limited; it is enough for a small community.

## Local tests
| Variable | Default | Purpose |
|---|---|---|
| `PGBIN` | `/usr/lib/postgresql/16/bin` | Postgres binaries for `scripts/test-db.sh` |
| `PULSE_PG_PORT` | `54329` | Port of the throwaway test cluster |

## Local development (free)
`npm run sb:start` runs Supabase in Docker with the settings from `supabase/config.toml`.
`npx supabase status` prints the local URL and anon key (public demo values, local only).
Emails (confirmation, reset, security alerts) are captured at http://127.0.0.1:54324.
