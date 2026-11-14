#!/usr/bin/env node
// Creates the first PULSE owner account on a hosted project, without an invitation.
//
//   SUPABASE_ACCESS_TOKEN=<personal access token> node scripts/bootstrap-owner.mjs \
//     <project-ref> <owner-email> <username> <site-url>
//
// How it stays safe (migration 0031):
// - It only works while the project has no owner.
// - A random one-time token is generated here and only its SHA-256 goes into the database
//   (platform_config.owner_bootstrap_hash) together with the owner's address. The token is
//   sent once, in the account's sign-up metadata, and is never printed or stored; the
//   database removes it from the account and clears the hash when it is used.
// - The account is created unconfirmed and without a password. Supabase then emails the
//   owner a password link (the "Reset your password" email): opening it proves the inbox,
//   sets the password, and only then does the database make the account the owner.
// Requires database access (the Management API token), which is exactly who may do this.
import { createHash, randomBytes } from 'node:crypto';

const [ref, email, username, site] = process.argv.slice(2);
const token = process.env.SUPABASE_ACCESS_TOKEN;
const fail = (m) => { console.error(m); process.exit(1); };
if (!token || !/^[a-z0-9]{20}$/.test(ref ?? '') || !/^[^\s@'"<>]+@[^\s@'"<>]+\.[a-z]{2,}$/i.test(email ?? '')
    || !/^[a-z0-9][a-z0-9._]{1,18}[a-z0-9]$/.test(username ?? '') || !/^https:\/\/\S+$/.test(site ?? '')) {
  fail('usage: SUPABASE_ACCESS_TOKEN=… node scripts/bootstrap-owner.mjs <project-ref> <owner-email> <username> <https://site/>');
}
const api = `https://api.supabase.com/v1/projects/${ref}`;
const mgmt = async (path, init = {}) => {
  const res = await fetch(api + path, { ...init, headers: { Authorization: `Bearer ${token}`, 'Content-Type': 'application/json', ...(init.headers ?? {}) } });
  const text = await res.text();
  if (!res.ok) fail(`${path}: ${res.status} ${text.slice(0, 200)}`);
  return text ? JSON.parse(text) : null;
};
const query = (q) => mgmt('/database/query', { method: 'POST', body: JSON.stringify({ query: q }) });

const secret = randomBytes(32).toString('base64url');
const hash = createHash('sha256').update(secret).digest('hex');
const set = await query(`update private.platform_config
   set owner_bootstrap_email = '${email.replace(/'/g, "''")}', owner_bootstrap_hash = '${hash}', owner_bootstrap_user = null
 where id and owner_user_id is null returning true as ok`);
if (!set?.length) fail('This project already has an owner. Nothing changed.');

const keys = await mgmt('/api-keys?reveal=true');
const service = keys.find((k) => k.type === 'secret')?.api_key ?? keys.find((k) => k.name === 'service_role')?.api_key;
const publishable = keys.find((k) => k.type === 'publishable')?.api_key ?? keys.find((k) => k.name === 'anon')?.api_key;
if (!service || !publishable) fail('Could not read the project API keys.');
const auth = (key) => (key.split('.').length === 3 ? { apikey: key, Authorization: `Bearer ${key}` } : { apikey: key });
const url = `https://${ref}.supabase.co/auth/v1`;

const created = await fetch(`${url}/admin/users`, {
  method: 'POST', headers: { ...auth(service), 'Content-Type': 'application/json' },
  body: JSON.stringify({ email, email_confirm: false, user_metadata: { username, display_name: username, owner_bootstrap_token: secret } }),
});
if (!created.ok) {
  await query('update private.platform_config set owner_bootstrap_hash = null, owner_bootstrap_email = null where id and owner_user_id is null');
  fail(`Creating the owner account failed (${created.status}): ${(await created.text()).slice(0, 200)}`);
}
const sent = await fetch(`${url}/recover`, {
  method: 'POST', headers: { ...auth(publishable), 'Content-Type': 'application/json' },
  body: JSON.stringify({ email, redirect_to: new URL('reset-password', site.endsWith('/') ? site : site + '/').href }),
});
if (!sent.ok) fail(`Account created, but the password email failed (${sent.status}). Use "Forgot password?" on the site.`);
console.log(`Owner account created for ${email} (@${username}).`);
console.log('Open the "Reset your password" email from PULSE, choose a password: the account becomes the owner.');
console.log('Then turn on two-step verification in Settings → Security to open the Owner panel.');
