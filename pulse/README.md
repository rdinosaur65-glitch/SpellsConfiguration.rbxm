# PULSE

*Your people. Your moments.* A camera-first, private, friends-only social PWA, built to
run on a strict **€0** infrastructure budget.

**Status:** backend + first working web app (accounts, 2FA, friends, realtime chat,
settings, camera preview, offline shell), tested end-to-end against a real local Supabase
stack. Not deployed yet. See `docs/PHASE_REPORT_03.md` (independent review + hardening) and `docs/PHASE_REPORT_02.md`.

## Layout
```
apps/web/            Vite + React 19 PWA (static; Cloudflare Pages)
packages/domain/     Shared TypeScript rules (+ unit tests)
supabase/            config.toml, migrations (source of truth), SQL tests
scripts/             test runners
docs/                architecture, €0 plan, security, checklist, reports
```

## Run it locally (free, needs Docker and Node ≥ 22)
```bash
npm install
npm run sb:start                      # local Supabase: DB, Auth, Realtime, Storage, mail catcher
cp .env.example apps/web/.env.local   # fill in VITE_SUPABASE_ANON_KEY from `npx supabase status`
npm run dev -w @pulse/web             # http://127.0.0.1:5173 — confirmation emails at http://127.0.0.1:54324
```

## Tests
```bash
scripts/test-db.sh                    # SQL suites on plain Postgres 16 (shim)
scripts/test-supabase-local.sh        # same suites on the real local Supabase stack (resets local DB)
npm test -w @pulse/domain             # domain unit tests
cd apps/web && npx playwright test    # end-to-end (builds the app, needs the local stack)
```

## Docs
- `docs/INFRASTRUCTURE_ZERO_COST.md`: free tiers, capacity, safeguards, what €0 can't do
- `docs/ARCHITECTURE.md` · `docs/SECURITY_MODEL.md` · `docs/ENVIRONMENT.md`
- `docs/CHECKLIST.md`: every feature with an honest status

## Deploy (owner, when ready — all free)
1. Supabase project → apply `supabase/migrations/*.sql` in order (`npx supabase db push`).
   Never apply `supabase/tests/00_supabase_shim.sql` to a real project.
2. Copy the Auth settings in `docs/ENVIRONMENT.md`: confirmations, TOTP, security emails,
   the two email templates, the exact redirect URL, Turnstile, and a **free SMTP provider**
   (required: the built-in mailer only reaches the project's own team).
3. Cloudflare Pages → build `npm run build -w @pulse/web`, output `apps/web/dist`,
   with `VITE_SUPABASE_URL` / `VITE_SUPABASE_ANON_KEY` set.
4. Sign up, then record your UUID as owner (`docs/ENVIRONMENT.md`).
