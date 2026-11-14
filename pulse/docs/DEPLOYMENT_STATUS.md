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
