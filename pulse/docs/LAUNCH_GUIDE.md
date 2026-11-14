# PULSE friends beta — launch guide (all free)

This takes about an hour, once. Every service below has a free plan that PULSE stays
inside; none of them needs a payment card for what PULSE uses. You (the owner) create the
accounts; the app itself never asks you to pay for anything.

You need: a computer with **Node.js 22** installed, this repository on GitHub, and an
email address. Keep a notes file open: you will copy a few keys between websites.

---

## 1. Supabase (database, sign-in, files) — free plan
1. Create an account at supabase.com and a **New project** (Free plan). Pick the region
   closest to your friends and a strong database password (store it safely).
2. Project Settings → **API**: note the **Project URL**, the **anon / publishable key**
   and the **project ref** (the `xxxx` in `https://xxxx.supabase.co`).
3. In a terminal, from the `pulse/` folder:
   ```sh
   npm ci
   npx supabase login
   npx supabase link --project-ref <project-ref>
   npx supabase db push            # applies every migration in supabase/migrations
   ```
   Never run anything from `supabase/tests/` against this project.

## 2. Email that actually arrives — free SMTP (required)
Supabase's built-in mailer only emails the project's own team (and only a couple of
emails an hour), so your friends would never get their confirmation link. Custom SMTP is
also what unlocks editing the email templates in step 3.

**Recommended without a domain — Gmail with an app password (free, about 500 emails/day):**
1. Use (or create) a Google account for PULSE. Turn on 2-Step Verification for it.
2. Google Account → Security → **App passwords** → create one named "PULSE".
3. Supabase → Authentication → **SMTP Settings**: enable custom SMTP. Host
   `smtp.gmail.com`, port `465`, username = the Gmail address, password = the app password,
   sender email = the same Gmail address, sender name "PULSE".

**Alternative — Brevo free plan (300 emails/day, no card):** works well only with a sender
domain you own (DNS records). With a Gmail/Outlook address as the sender, messages often
fail the receiver's anti-spoofing checks and land in spam — and buying a domain is outside
PULSE's €0 rule, so prefer Gmail above unless you already own a domain. New Brevo accounts
may also need manual approval before they can send.

## 3. Sign-in settings (Supabase → Authentication)
(Template editing only becomes available after step 2.)
Follow the list in `docs/ENVIRONMENT.md` → "Supabase Auth settings". In short:
- Email confirmations **on**; minimum password length 8 with letters and digits.
- Multi-factor: **TOTP on** (free). Phone MFA off.
- Email templates: paste `supabase/templates/confirmation.html` into **Confirm signup** and
  `supabase/templates/recovery.html` into **Reset password**; the security-alert template
  (`security_alert.html`) for password, email and 2FA changes.
- Minimum time between emails to one person: 60 seconds.
- URL configuration: **Site URL** and **Redirect URL** = your exact app address from
  step 6 (e.g. `https://pulse-abc.pages.dev` and `https://pulse-abc.pages.dev/**`). Never a
  wildcard like `https://*.pages.dev/**`. (You can come back to this after step 6.)

## 4. Bot protection — Cloudflare Turnstile (free, recommended)
1. Create a free Cloudflare account → **Turnstile** → add a widget. Its hostname is your
   app's `*.pages.dev` address from step 6: pick the Pages project name first (or add the
   hostname to the widget after step 6).
2. Supabase → Authentication → **Bot and Abuse Protection**: enable captcha, provider
   Turnstile, paste the **secret key**.
3. Put the **site key** in Cloudflare Pages as `VITE_TURNSTILE_SITE_KEY` (step 6).
   Do 2 and 3 together: captcha on without the site key means nobody can sign in.

## 5. Edge Functions (photos, Snaps, owner 2FA resets)
```sh
npx supabase functions deploy media-url storage-janitor owner-mfa-reset
npx supabase secrets set JANITOR_SECRET=<a long random string>
```
The owner-mfa-reset function emails you a confirmation code whenever you reset someone's
two-step verification, and then tells that person it happened. It sends through the same
free Gmail account as step 2 (Supabase blocks outgoing ports 25 and 587, so use port 465):
```sh
npx supabase secrets set PULSE_SMTP_HOST=smtp.gmail.com PULSE_SMTP_PORT=465 PULSE_SMTP_TLS=implicit \
  PULSE_SMTP_USER=<the PULSE Gmail address> PULSE_SMTP_PASS=<its app password> \
  PULSE_SMTP_FROM=<the PULSE Gmail address> PULSE_SMTP_FROM_NAME=PULSE
```
Use a mailbox that is **not** the address of your own PULSE account: the notice goes to the
person being reset, so it must not come from you. The function refuses to run if the sender
is your own address. The code itself goes to the email address of your owner account, and
the reset does not happen unless that email is delivered and you type the code within
5 minutes.
Then in Supabase → **SQL Editor**, run once (same random string as above):
```sql
select vault.create_secret('https://<project-ref>.supabase.co/functions/v1/storage-janitor', 'pulse_janitor_url');
select vault.create_secret('<the same long random string>', 'pulse_janitor_secret');
```

## 6. The app itself — Cloudflare Pages (free)
1. Cloudflare → Workers & Pages → **Create** → Pages → connect to GitHub → choose this
   repository. Production branch: the branch that holds PULSE
   (`claude/pulse-project-continuation-ji3lu1`, or `main` if you merge it / move PULSE to
   its own repository).
2. Build settings: **Root directory** `pulse` · **Build command** `npm run build -w @pulse/web`
   · **Output directory** `apps/web/dist`.
3. Environment variables: `NODE_VERSION=22`, `VITE_SUPABASE_URL=<Project URL>`,
   `VITE_SUPABASE_ANON_KEY=<anon key>`, `VITE_TURNSTILE_SITE_KEY=<site key>` (if step 4),
   `VITE_OWNER_CONTACT=<how friends reach you, e.g. an email>`.
4. Deploy. Note the address (e.g. `https://pulse-abc.pages.dev`) and finish step 3's URL
   settings with it.

## 7. Become the owner
1. Open the app, sign up with your own account and confirm the email.
2. Supabase → Table editor → `profiles` → copy your `id`. In the SQL Editor:
   ```sql
   update private.platform_config set owner_user_id = '<your id>';
   ```
3. In the app: Settings → **turn on two-step verification**. This is required: the Owner
   panel (usage meters, reports, suspensions, 2FA resets, audit log) only works in a
   session confirmed with your own authenticator code.
4. Read Settings → Privacy and rules once; adjust the wording in
   `apps/web/src/screens/Privacy.tsx` if you want, and redeploy.

## 8. Smoke test (5 minutes) before inviting anyone
With a second email address (or a friend):
- [ ] Sign up → confirmation email arrives → link opens the app signed in.
- [ ] Search each other by username → request → accept.
- [ ] Send a message, a photo, and a Snap from the Camera tab; view and replay the Snap.
- [ ] "Forgot password?" email arrives and works.
- [ ] Owner panel shows usage; reporting the test account shows up there.

## 9. Invite friends — and keep it friends-only
Anyone who has the app's address can sign up; PULSE has no invite codes. Keep the beta
closed with two free settings:
1. Set the account cap to the number of people you are inviting (you included):
   `update private.platform_config set registration_cap = <n>;` (default 50).
2. Once everyone has joined, Supabase → Authentication → Sign In / Providers → turn off
   **Allow new users to sign up**. Existing accounts keep signing in normally. Turn it on
   briefly when you want to add someone.

Share the app address only with the people you invite. On phones, "Add to Home Screen"
installs it like an app.
- Watch the Owner panel meters. At 70% of anything, tidy up. On their own, the database
  refuses new text at 90% of its 500 MB, and each storage pool refuses uploads when full
  (the backup pool at 90%), so database and file storage stay inside the free plan.
  Downloads are capped too, but see the egress note below.

## Free-plan facts to keep in mind
- **Inactivity pause:** Supabase pauses a Free project after about 7 days without
  activity. A paused project does **not** wake up by itself: the app stops working until
  you open the Supabase dashboard, select the project and click **Resume** (takes a few
  minutes). Do it promptly — paused Free projects can only be restored for a limited time.
  Normal use by a friend group keeps it awake. Optional free keep-alive: a weekly
  scheduled GitHub Actions job that makes one request to the project (GitHub disables
  scheduled jobs after 60 days without repository activity).
- Two Free projects per Supabase account; PULSE needs one.
- Capacity limits (PULSE enforces its own lower ceilings, see the Owner panel): database
  500 MB, files 1 GB, 500,000 Edge Function calls a month (each photo or Snap view is
  one), 200 simultaneous live connections, 2 million realtime messages a month, 300–500
  emails a day depending on the SMTP choice.
- Downloads (egress) are the tightest limit: about 5 GB a month. Photos and Snaps pass
  through the media-url function, so each view counts about twice (Storage → function →
  phone), and ordinary app traffic counts too. PULSE therefore caps media views at 70 MB a
  day for everyone together (≈ 2.1 GB a month, ≈ 4.2 GB counted twice) and 25 MB per
  person after their first download of the day; when the day's budget is used up, photos
  wait until the next day while text keeps working. This is a target, not a guarantee:
  check Supabase → **Usage → Egress** weekly during the beta.
- None of the services above asks for a payment card on the free plan. If any of them ever
  shows an upgrade or billing screen, do not enter card details: PULSE is designed to stop
  (refuse new writes or uploads) before it would need a paid tier.

## What is not in this beta
Video Snaps, voice notes, Stories, streaks, Memories backup, calls, push notifications,
the map, and Google/Apple sign-in (see `docs/CHECKLIST.md`). Push notifications in
particular: friends only see new messages when they open the app.
