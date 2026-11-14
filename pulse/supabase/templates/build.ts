// Renders the Supabase Auth email templates from the shared PULSE email layout.
//
//   node --experimental-strip-types supabase/templates/build.ts
//
// Writes <name>.html next to this file and manifest.json (template key → subject + file),
// which config.toml (local stack) and scripts/apply-email-templates.mjs (hosted project) use.
// Links keep Supabase's own variables; nothing here is a real URL, token or secret.
//
// Only rules the backend enforces are stated: email links expire after mailer_otp_exp
// (3600 s = 60 minutes, config.toml otp_expiry) and Supabase consumes a token when it is
// used; email changes need confirming from both addresses (double_confirm_changes).
import { writeFileSync } from 'node:fs';
import { dirname, join } from 'node:path';
import { fileURLToPath } from 'node:url';
import { renderHtml, type EmailContent } from '../functions/_shared/email.ts';

const here = dirname(fileURLToPath(import.meta.url));
const LINK_60 = 'This link expires in 60 minutes and can only be used once.';
const SECURITY_HELP = 'If you didn’t make this change, reset your password right away with “Forgot password?” on the PULSE sign-in screen, then use “Sign out everywhere else” in Settings → Where you’re signed in.';

interface Template { key: string; file: string; subject: string; content: EmailContent }

const templates: Template[] = [
  {
    key: 'confirmation', file: 'confirmation.html', subject: 'Verify your email address | PULSE',
    content: {
      preheader: 'Confirm your email address to finish setting up your PULSE account.',
      heading: 'Verify your email address',
      paragraphs: ['Welcome to PULSE.',
        'You’re almost ready to connect with your friends. Confirm your email address to finish setting up your account.'],
      button: { label: 'Verify Email Address',
        href: '{{ if .RedirectTo }}{{ .RedirectTo }}{{ else }}{{ .SiteURL }}/{{ end }}?token_hash={{ .TokenHash }}&type=email' },
      note: 'This verification link expires in 60 minutes and can only be used once.',
      footer: 'If you didn’t create a PULSE account, you can safely ignore this email.',
    },
  },
  {
    key: 'recovery', file: 'recovery.html', subject: 'Reset your password | PULSE',
    content: {
      preheader: 'Use this link to choose a new password for your PULSE account.',
      heading: 'Reset your password',
      paragraphs: ['We received a request to reset the password for your PULSE account. Use the button below to choose a new one.'],
      details: [['Account', '{{ .Email }}']],
      button: { label: 'Reset Password',
        href: '{{ if .RedirectTo }}{{ .RedirectTo }}{{ else }}{{ .SiteURL }}/reset-password{{ end }}?token_hash={{ .TokenHash }}&type=recovery' },
      note: LINK_60,
      footer: 'If you didn’t request a password reset, you can safely ignore this email. Your password won’t change.',
    },
  },
  {
    key: 'email_change', file: 'email_change.html', subject: 'Confirm your new email address | PULSE',
    content: {
      preheader: 'Confirm the change of email address on your PULSE account.',
      heading: 'Confirm your email change',
      paragraphs: ['A request was made to change the email address on your PULSE account.',
        'For your security, the change has to be confirmed from both your current and your new address.'],
      details: [['From', '{{ .Email }}'], ['To', '{{ .NewEmail }}']],
      button: { label: 'Confirm Email Change', href: '{{ .ConfirmationURL }}' },
      note: LINK_60,
      notice: { title: 'Didn’t request this?', text: 'Don’t confirm it: your email address stays the same. Consider changing your password.' },
      footer: 'You’re receiving this email because a change was requested on a PULSE account linked to this address.',
    },
  },
  {
    key: 'magic_link', file: 'magic_link.html', subject: 'Your sign-in link | PULSE',
    content: {
      preheader: 'Your one-time link to sign in to PULSE.',
      heading: 'Sign in to PULSE',
      paragraphs: ['Use the button below to sign in to your PULSE account.'],
      details: [['Account', '{{ .Email }}']],
      button: { label: 'Sign In', href: '{{ .ConfirmationURL }}' },
      note: LINK_60,
      footer: 'If you didn’t try to sign in, you can safely ignore this email.',
    },
  },
  {
    key: 'invite', file: 'invite.html', subject: 'You’re invited to PULSE',
    content: {
      preheader: 'You’ve been invited to join PULSE.',
      heading: 'You’re invited to PULSE',
      paragraphs: ['You’ve been invited to join PULSE, a private, friends-only space for sharing moments with the people you know.'],
      button: { label: 'Accept Invitation', href: '{{ .ConfirmationURL }}' },
      footer: 'If you weren’t expecting this invitation, you can safely ignore this email.',
    },
  },
  {
    key: 'reauthentication', file: 'reauthentication.html', subject: 'Your verification code | PULSE',
    content: {
      preheader: 'Use this code to confirm it’s you.',
      heading: 'Confirm it’s you',
      paragraphs: ['Enter this code in PULSE to confirm a sensitive change to your account.'],
      code: '{{ .Token }}',
      note: 'This code can only be used once.',
      notice: { title: 'Didn’t request this code?', text: 'Don’t share it with anyone. Nothing changes without it. Consider changing your password.' },
      footer: 'You’re receiving this email because a verification code was requested for your PULSE account.',
    },
  },
  {
    key: 'password_changed_notification', file: 'password_changed.html', subject: 'Your password was changed | PULSE',
    content: {
      preheader: 'The password on your PULSE account was just changed.',
      heading: 'Your password was changed',
      paragraphs: ['The password for your PULSE account was just changed. If this was you, there’s nothing else to do.'],
      details: [['Account', '{{ .Email }}']],
      notice: { title: 'Wasn’t you?', text: SECURITY_HELP },
      footer: 'This security notice is sent whenever the password on your PULSE account changes.',
    },
  },
  {
    key: 'email_changed_notification', file: 'email_changed.html', subject: 'Your email address was changed | PULSE',
    content: {
      preheader: 'The email address on your PULSE account was changed.',
      heading: 'Your email address was changed',
      paragraphs: ['The email address for your PULSE account was changed. If this was you, there’s nothing else to do.'],
      details: [['From', '{{ .OldEmail }}'], ['To', '{{ .Email }}']],
      notice: { title: 'Wasn’t you?', text: 'Contact the PULSE owner straight away so the account can be secured.' },
      footer: 'This security notice is sent whenever the email address on a PULSE account changes.',
    },
  },
  {
    key: 'mfa_factor_enrolled_notification', file: 'mfa_enrolled.html', subject: 'Two-step verification was turned on | PULSE',
    content: {
      preheader: 'Two-step verification is now on for your PULSE account.',
      heading: 'Two-step verification is on',
      paragraphs: ['Two-step verification was turned on for your PULSE account. From now on, signing in needs a code from your authenticator app as well as your password.'],
      details: [['Account', '{{ .Email }}']],
      notice: { title: 'Wasn’t you?', text: SECURITY_HELP },
      footer: 'This security notice is sent whenever two-step verification changes on your PULSE account.',
    },
  },
  {
    key: 'mfa_factor_unenrolled_notification', file: 'mfa_unenrolled.html', subject: 'Two-step verification was turned off | PULSE',
    content: {
      preheader: 'Two-step verification was turned off for your PULSE account.',
      heading: 'Two-step verification is off',
      paragraphs: ['Two-step verification was turned off for your PULSE account. Signing in now needs only your password.',
        'You can turn it back on at any time in Settings → Security.'],
      details: [['Account', '{{ .Email }}']],
      notice: { title: 'Wasn’t you?', text: SECURITY_HELP },
      footer: 'This security notice is sent whenever two-step verification changes on your PULSE account.',
    },
  },
];

const manifest: Record<string, { subject: string; file: string }> = {};
for (const t of templates) {
  writeFileSync(join(here, t.file), renderHtml(t.content, t.subject));
  manifest[t.key] = { subject: t.subject, file: t.file };
}
writeFileSync(join(here, 'manifest.json'), JSON.stringify(manifest, null, 2) + '\n');
console.log(`wrote ${templates.length} templates + manifest.json`);
