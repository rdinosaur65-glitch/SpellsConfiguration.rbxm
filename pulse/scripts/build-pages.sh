#!/usr/bin/env bash
# Builds PULSE for GitHub Pages (free, no account beyond GitHub) into <repo>/docs, the folder
# GitHub Pages serves when "Deploy from a branch" → <branch> → /docs is chosen.
#
#   VITE_SUPABASE_URL=… VITE_SUPABASE_ANON_KEY=… VITE_VAPID_PUBLIC_KEY=… scripts/build-pages.sh
#
# Only public values go in (the anon key is public by design: RLS protects the data).
# Building does not publish anything; the site goes live only when GitHub Pages is switched
# on for the branch (docs/LAUNCH_GUIDE.md, "GitHub Pages").
set -euo pipefail
cd "$(dirname "$0")/.."
: "${VITE_SUPABASE_URL:?set VITE_SUPABASE_URL}" "${VITE_SUPABASE_ANON_KEY:?set VITE_SUPABASE_ANON_KEY}" "${VITE_VAPID_PUBLIC_KEY:?set VITE_VAPID_PUBLIC_KEY}"
OUT="$(cd .. && pwd)/docs"
export PULSE_BASE="${PULSE_BASE:-/SpellsConfiguration.rbxm/}" PULSE_HOST=github-pages
npm run build -w apps/web -- --outDir "$OUT" --emptyOutDir

# Refuse to ship anything secret: every JWT in the bundle must be an anon key, and no
# new-format secret key may appear.
node - "$OUT" <<'JS'
const fs = require('fs'), path = require('path');
const files = []; (function walk(d) { for (const f of fs.readdirSync(d)) { const p = path.join(d, f); fs.statSync(p).isDirectory() ? walk(p) : files.push(p); } })(process.argv[2]);
let bad = 0;
for (const f of files.filter((x) => /\.(js|html|json|webmanifest)$/.test(x))) {
  const s = fs.readFileSync(f, 'utf8');
  if (/sb_secret_[A-Za-z0-9_-]{16,}/.test(s)) { console.error(`secret key in ${f}`); bad++; }
  for (const m of s.matchAll(/eyJ[A-Za-z0-9_-]+\.(eyJ[A-Za-z0-9_-]+)\.[A-Za-z0-9_-]+/g)) {
    let role = '?'; try { role = JSON.parse(Buffer.from(m[1], 'base64url').toString()).role; } catch {}
    if (role !== 'anon') { console.error(`non-anon JWT (${role}) in ${f}`); bad++; }
  }
}
if (bad) process.exit(1);
console.log(`checked ${files.length} files: only public keys`);
JS
echo "Built into $OUT (base $PULSE_BASE). Not published until GitHub Pages is switched on."
