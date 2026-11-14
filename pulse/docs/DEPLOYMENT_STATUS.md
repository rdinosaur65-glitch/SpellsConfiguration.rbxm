# PULSE — deployment status (private beta)

Everything below runs on free plans with no payment card: Supabase Free, Gmail (free
account + app password), GitHub Pages (public repository). Nothing is public yet.

## Live and verified (Supabase project `pulse`, ref `ghagghntdarmaknkmwng`, eu-west-2, Free)
- Database: 30 migrations applied; every public table has RLS; no function callable
  without signing in; cron jobs for maintenance, unconfirmed-account purge, push sweep and
  storage clean-up; private `media` bucket (50 MB limit); registration cap 50; no owner yet;
  0 users.
- Sign-up is **closed** (`disable_signup`) until go-live. Email confirmation is required;
  passwords ≥ 8 with letters and digits; password change needs a recent sign-in.
- Edge Functions `media-url`, `storage-janitor`, `owner-mfa-reset`, `push-send` deployed;
  secrets set (values never stored in the repository).
- Email: custom SMTP `smtp.gmail.com:465` from `pulseconnectapp@gmail.com` (sender name
  PULSE); PULSE templates for confirmation, password reset and security alerts; links point
  to the GitHub Pages address.

Verified on the live project with throwaway accounts (all deleted afterwards):
| Check | Result |
|---|---|
| Confirmation email sent through Gmail | accepted (200) |
| Sign-in before confirming | refused (`email_not_confirmed`) |
| Confirmation token (as in the email link) → confirmed account + profile | ok |
| Password-reset email sent; unknown address gives the same answer | ok |
| Reset token → new password; old password refused | ok |
| "Password changed" / "2FA turned on" security alerts | sent |
| Owner 2FA-reset code email (Edge Function → Gmail) | sent, request `pending` |
| Push function with the project's service key | 200 |

Fixed while verifying: the functions sent the new-format service key next to the legacy
anon key, which the gateway rejects (`Expected 3 parts in JWT`). `serviceHeaders()` now
sends a secret key on its own; redeployed and re-verified.

## Email design (live)
One layout for every email (`supabase/functions/_shared/email.ts`): dark charcoal card on
black, centred PULSE wordmark, white headings, white call-to-action button, large code box
for one-time codes, highlighted security notice, consistent footer. Table layout with inline
styles, no images or web fonts, Outlook fallbacks, `color-scheme` meta, preheader text.
Applied to all 10 Supabase Auth templates and to both owner-2FA-reset emails (Edge Function,
sent as HTML + plain text).

Sent for real through Gmail to test addresses on the live project (all accepted):
verification, password reset, password changed, re-authentication code, 2FA on, 2FA off,
email change (to both addresses), email changed, sign-in link, invitation, owner
"Security Verification" code (owner address), "2FA was reset" notice.

Behaviour checked on the live project:
| Rule stated in the emails | Check | Result |
|---|---|---|
| Links can only be used once | same verification link twice | 2nd: `otp_expired` |
| Links expire after 60 minutes | lifetime set to 60 s for the test, link used after 75 s, then restored to 3600 s | `otp_expired` |
| Email change needs both addresses | confirmed current, then new | changed only after both |
| Owner code: 5 minutes | correct code entered after 5 min 5 s | `expired`, nothing reset |
| Owner code: one use | correct code entered twice | 2nd: `used` |
| Owner code: locked after 5 wrong entries | `supabase/tests/functions.test.mjs` (local stack, CI) | locked |

Not verifiable from here: how the delivered messages look inside Gmail (web, iPhone app),
Apple Mail and Outlook. Supabase Auth sends HTML only (no plain-text part is supported for
its templates); the Edge Function emails include a plain-text part.

## Prepared, not live
- Web app built for GitHub Pages (`scripts/build-pages.sh`): sub-folder routing, service
  worker and manifest scoped to `/SpellsConfiguration.rbxm/`, CSP pinned to this project,
  clickjacking guard, `noindex`. Checked in Chromium: routes, deep links, icons, service
  worker scope, no CSP errors, hidden when framed.

## Go-live steps (only after the owner's explicit approval)
1. Commit the Pages build to `docs/` and push.
2. Owner: GitHub → Settings → Pages → Deploy from a branch → this branch, `/docs` → Save.
3. Open sign-ups, set the registration cap to the head count.
4. Owner signs up with their own address, confirms the email; set `owner_user_id`; owner
   turns on 2FA.
5. Smoke test on iPhone (Safari → Share → Add to Home Screen; notifications need iOS 16.4+
   and the home-screen app). Then friends sign up; close sign-ups when everyone is in.
