#!/usr/bin/env node
// Generates a VAPID key pair for Web Push (free; runs locally, nothing is sent anywhere).
// Usage: node scripts/gen-vapid.mjs
// Put VAPID_PUBLIC_KEY in the web app as VITE_VAPID_PUBLIC_KEY, and set all three values
// as Edge Function secrets (see docs/LAUNCH_GUIDE.md §5). Keep the private key secret.
import { generateKeyPairSync } from 'node:crypto';

const { publicKey, privateKey } = generateKeyPairSync('ec', { namedCurve: 'prime256v1' });
const jwk = privateKey.export({ format: 'jwk' });
const pub = publicKey.export({ format: 'jwk' });
const b64 = (s) => Buffer.from(s, 'base64url');
const raw = Buffer.concat([Buffer.from([4]), b64(pub.x), b64(pub.y)]).toString('base64url');
console.log(`VAPID_PUBLIC_KEY=${raw}`);
console.log(`VAPID_PRIVATE_KEY=${jwk.d}`);
