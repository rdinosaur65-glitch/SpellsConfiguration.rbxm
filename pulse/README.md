# PULSE

*Your people. Your moments.* A camera-first, private, friends-only social PWA, built to
run on a strict **€0** infrastructure budget.

**Status:** backend foundation built and tested; no UI yet. See `docs/PHASE_REPORT_01.md`.

## Docs
- `docs/INFRASTRUCTURE_ZERO_COST.md`: verified free tiers, capacity, safeguards and what €0 can't do
- `docs/ARCHITECTURE.md`: stack, layout, database-enforced rules
- `docs/SECURITY_MODEL.md`: trust boundaries, media access, owner limits, Vault design
- `docs/CHECKLIST.md`: every feature with an honest status
- `docs/ENVIRONMENT.md`: configuration (all free)

## Run the tests
```bash
scripts/test-db.sh                                 # needs local Postgres 16 binaries
cd packages/domain && npm test                     # Node ≥ 22
```

## Apply to Supabase (owner, when ready)
Apply `supabase/migrations/*.sql` in order, using the Supabase CLI (`supabase db push`)
or the SQL editor. Never apply `supabase/tests/00_supabase_shim.sql` to a real project.
Then set the owner UUID as described in `docs/ENVIRONMENT.md`.
