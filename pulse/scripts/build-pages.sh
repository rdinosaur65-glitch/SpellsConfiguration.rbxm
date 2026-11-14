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
STAGE="$(mktemp -d)"; trap 'rm -rf "$STAGE"' EXIT
export PULSE_BASE="${PULSE_BASE:-/SpellsConfiguration.rbxm/}" PULSE_HOST=github-pages
# Build into a temporary folder first: docs/ is only replaced once the bundle passed the check.
npm run build -w apps/web -- --outDir "$STAGE/site" --emptyOutDir

# Refuse to ship anything secret: every JWT in the bundle must be an anon key; no secret
# key, personal access token or VAPID private key may appear.
node - "$STAGE/site" <<'JS'
const fs = require('fs'), path = require('path');
const files = []; (function walk(d) { for (const f of fs.readdirSync(d)) { const p = path.join(d, f); fs.statSync(p).isDirectory() ? walk(p) : files.push(p); } })(process.argv[2]);
let bad = 0;
for (const f of files.filter((x) => /\.(js|html|json|webmanifest)$/.test(x))) {
  const s = fs.readFileSync(f, 'utf8');
  if (/sb_secret_[A-Za-z0-9_-]{16,}/.test(s)) { console.error(`secret key in ${f}`); bad++; }
  if (/sbp_[0-9a-f]{40}/.test(s)) { console.error(`access token in ${f}`); bad++; }
  const vp = process.env.VAPID_PRIVATE_KEY;
  if (vp && vp.length > 20 && s.includes(vp)) { console.error(`VAPID private key in ${f}`); bad++; }
  for (const m of s.matchAll(/eyJ[A-Za-z0-9_-]+\.(eyJ[A-Za-z0-9_-]+)\.[A-Za-z0-9_-]+/g)) {
    let role = '?'; try { role = JSON.parse(Buffer.from(m[1], 'base64url').toString()).role; } catch {}
    if (role !== 'anon') { console.error(`non-anon JWT (${role}) in ${f}`); bad++; }
  }
}
if (bad) process.exit(1);
console.log(`checked ${files.length} files: only public keys`);
JS
rm -rf "$OUT" && mv "$STAGE/site" "$OUT"
echo "Built into $OUT (base $PULSE_BASE). Not published until GitHub Pages is switched on."
