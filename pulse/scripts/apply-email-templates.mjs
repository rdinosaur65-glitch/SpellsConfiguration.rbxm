#!/usr/bin/env node
// Applies the generated PULSE email templates (supabase/templates, see build.ts) to a hosted
// Supabase project through the Management API.
//
//   SUPABASE_ACCESS_TOKEN=<personal access token> node scripts/apply-email-templates.mjs <project-ref>
//
// Needs custom SMTP to be configured first (Supabase refuses template changes on the
// built-in mailer). Only subjects and HTML are sent; no secrets are read or written.
import { readFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';

const ref = process.argv[2];
const token = process.env.SUPABASE_ACCESS_TOKEN;
if (!ref || !/^[a-z0-9]{20}$/.test(ref) || !token) {
  console.error('usage: SUPABASE_ACCESS_TOKEN=… node scripts/apply-email-templates.mjs <project-ref>');
  process.exit(2);
}
const dir = join(dirname(fileURLToPath(import.meta.url)), '..', 'supabase', 'templates');
const manifest = JSON.parse(readFileSync(join(dir, 'manifest.json'), 'utf8'));
const body = {};
for (const [key, { subject, file }] of Object.entries(manifest)) {
  body[`mailer_subjects_${key}`] = subject;
  body[`mailer_templates_${key}_content`] = readFileSync(join(dir, file), 'utf8');
}
const res = await fetch(`https://api.supabase.com/v1/projects/${ref}/config/auth`, {
  method: 'PATCH',
  headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json' },
  body: JSON.stringify(body),
});
if (!res.ok) { console.error(`failed: ${res.status} ${(await res.text()).slice(0, 300)}`); process.exit(1); }
console.log(`applied ${Object.keys(manifest).length} templates to ${ref}`);
