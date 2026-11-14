// PULSE email design system: one layout for every transactional and security email.
//
// Used in two ways:
// - Edge Functions (owner 2FA reset) call renderEmail() at send time and send both parts
//   (multipart/alternative: plain text + HTML).
// - supabase/templates/build.ts renders the Supabase Auth templates from the same layout,
//   with Supabase's Go template variables ({{ .TokenHash }} …) left in place for Auth to fill.
//
// Email-client rules followed here: table layout, inline styles (a <style> block only adds
// mobile spacing and is optional), no images (often blocked by default), no web fonts,
// bulletproof button (a padded <td> with a background colour, so it stays a big tap target
// even in Outlook), MSO conditional width for Outlook desktop, color-scheme meta so Apple
// Mail does not re-colour the dark design. Colours meet WCAG AA on their backgrounds:
// body #D1D1D8 on #16161A ≈ 12:1, muted #9A9AA5 on #0B0B0D ≈ 7:1, button #0B0B0D on #FFFFFF ≈ 19:1.

export interface EmailContent {
  /** Short summary shown in the inbox list next to the subject (hidden in the body). */
  preheader: string;
  heading: string;
  /** Paragraphs of plain text (escaped for HTML). */
  paragraphs: string[];
  /** Label/value rows, e.g. which account this is about. */
  details?: Array<[string, string]>;
  /** One-time code shown large in a box. */
  code?: string;
  codeLabel?: string;
  /** Primary call to action. href is inserted as an attribute (escaped); it may contain
   *  Go template actions for Supabase Auth templates. */
  button?: { label: string; href: string };
  /** Small print under the button or code (expiry, one-time use). */
  note?: string;
  /** Highlighted security notice. */
  notice?: { title: string; text: string };
  /** Why the reader can ignore this email if it was not them. */
  footer: string;
}

const C = {
  page: '#0B0B0D', card: '#16161A', border: '#2A2A31', heading: '#FFFFFF', text: '#D1D1D8',
  muted: '#9A9AA5', codeBg: '#0B0B0D', codeBorder: '#3A3A44', button: '#FFFFFF', buttonText: '#0B0B0D',
  noticeBg: '#1E1E24',
};
const FONT = "-apple-system, BlinkMacSystemFont, 'Segoe UI', Roboto, Helvetica, Arial, sans-serif";
const MONO = "'SF Mono', SFMono-Regular, Menlo, Consolas, 'Liberation Mono', monospace";

/** Escape text for HTML. Go template actions ({{ … }}) contain none of these characters,
 *  so they pass through unchanged. */
export function esc(s: string): string {
  return s.replace(/&/g, '&amp;').replace(/</g, '&lt;').replace(/>/g, '&gt;').replace(/"/g, '&quot;');
}

export function renderHtml(c: EmailContent, subject: string): string {
  const p = (text: string, extra = '') =>
    `<p style="margin:0 0 16px;font-family:${FONT};font-size:16px;line-height:24px;color:${C.text};${extra}">${esc(text)}</p>`;
  const details = c.details?.length ? `
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:4px 0 20px;border-collapse:separate;">
              ${c.details.map(([k, v]) => `<tr>
                <td style="padding:10px 14px;background-color:${C.noticeBg};border:1px solid ${C.border};border-radius:10px;font-family:${FONT};font-size:14px;line-height:20px;color:${C.muted};">
                  ${esc(k)}&nbsp; <span style="color:${C.heading};font-weight:600;word-break:break-all;">${esc(v)}</span>
                </td></tr>`).join('<tr><td style="height:8px;line-height:8px;font-size:8px;">&nbsp;</td></tr>')}
            </table>` : '';
  const code = c.code ? `
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:8px 0 16px;">
              <tr><td align="center" style="font-family:${FONT};font-size:13px;line-height:18px;color:${C.muted};padding-bottom:8px;letter-spacing:0.04em;text-transform:uppercase;">${esc(c.codeLabel ?? 'Verification code')}</td></tr>
              <tr><td align="center" bgcolor="${C.codeBg}" style="background-color:${C.codeBg};border:1px solid ${C.codeBorder};border-radius:14px;padding:22px 12px;">
                <span class="pulse-code" style="font-family:${MONO};font-size:36px;line-height:44px;font-weight:700;letter-spacing:10px;color:${C.heading};white-space:nowrap;">${esc(c.code)}</span>
              </td></tr>
            </table>` : '';
  const button = c.button ? `
            <table role="presentation" cellpadding="0" cellspacing="0" border="0" align="center" style="margin:8px auto 20px;">
              <tr><td align="center" bgcolor="${C.button}" style="background-color:${C.button};border-radius:12px;">
                <a href="${esc(c.button.href)}" target="_blank" style="display:inline-block;padding:15px 32px;font-family:${FONT};font-size:16px;line-height:20px;font-weight:700;color:${C.buttonText};text-decoration:none;border-radius:12px;">${esc(c.button.label)}</a>
              </td></tr>
            </table>` : '';
  const note = c.note ? p(c.note, `font-size:14px;line-height:21px;color:${C.muted};text-align:center;`) : '';
  const fallback = c.button ? `
            <p style="margin:0 0 4px;font-family:${FONT};font-size:13px;line-height:19px;color:${C.muted};">Button not working? Copy and paste this link into your browser:</p>
            <p style="margin:0 0 4px;font-family:${FONT};font-size:13px;line-height:19px;word-break:break-all;"><a href="${esc(c.button.href)}" target="_blank" style="color:${C.text};text-decoration:underline;">${esc(c.button.href)}</a></p>` : '';
  const notice = c.notice ? `
            <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="margin:8px 0 4px;">
              <tr><td bgcolor="${C.noticeBg}" style="background-color:${C.noticeBg};border:1px solid ${C.border};border-left:3px solid ${C.heading};border-radius:10px;padding:14px 16px;">
                <p style="margin:0 0 4px;font-family:${FONT};font-size:14px;line-height:20px;font-weight:700;color:${C.heading};">${esc(c.notice.title)}</p>
                <p style="margin:0;font-family:${FONT};font-size:14px;line-height:21px;color:${C.text};">${esc(c.notice.text)}</p>
              </td></tr>
            </table>` : '';
  return `<!DOCTYPE html>
<html lang="en" xmlns="http://www.w3.org/1999/xhtml">
<head>
<meta charset="utf-8">
<meta name="viewport" content="width=device-width, initial-scale=1">
<meta http-equiv="X-UA-Compatible" content="IE=edge">
<meta name="x-apple-disable-message-reformatting">
<meta name="color-scheme" content="dark light">
<meta name="supported-color-schemes" content="dark light">
<title>${esc(subject)}</title>
<style>
  :root { color-scheme: dark light; supported-color-schemes: dark light; }
  @media only screen and (max-width: 600px) {
    .pulse-card { padding: 28px 22px !important; }
    .pulse-outer { padding: 24px 12px !important; }
    .pulse-code { font-size: 30px !important; letter-spacing: 6px !important; }
  }
</style>
<!--[if mso]><style>table,td,p,a,span{font-family:Arial,sans-serif !important;}</style><![endif]-->
</head>
<body style="margin:0;padding:0;width:100%;background-color:${C.page};-webkit-text-size-adjust:100%;-ms-text-size-adjust:100%;">
<div style="display:none;max-height:0;overflow:hidden;mso-hide:all;font-size:1px;line-height:1px;color:${C.page};opacity:0;">${esc(c.preheader)}&#8199;&#65279;&#847;&#8199;&#65279;&#847;&#8199;&#65279;&#847;&#8199;&#65279;&#847;</div>
<table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" bgcolor="${C.page}" style="background-color:${C.page};">
  <tr>
    <td align="center" class="pulse-outer" style="padding:40px 16px;">
      <!--[if mso]><table role="presentation" width="560" cellpadding="0" cellspacing="0" border="0" align="center"><tr><td><![endif]-->
      <table role="presentation" width="100%" cellpadding="0" cellspacing="0" border="0" style="max-width:560px;width:100%;">
        <tr>
          <td align="center" style="padding:0 0 28px;font-family:${FONT};font-size:22px;line-height:28px;font-weight:800;letter-spacing:8px;color:${C.heading};">PULSE</td>
        </tr>
        <tr>
          <td class="pulse-card" bgcolor="${C.card}" style="background-color:${C.card};border:1px solid ${C.border};border-radius:20px;padding:40px 40px 32px;">
            <h1 style="margin:0 0 20px;font-family:${FONT};font-size:24px;line-height:32px;font-weight:700;color:${C.heading};">${esc(c.heading)}</h1>
            ${c.paragraphs.map((t) => p(t)).join('\n            ')}${details}${code}${button}${note}${fallback}${notice}
          </td>
        </tr>
        <tr>
          <td align="center" style="padding:24px 24px 0;font-family:${FONT};font-size:13px;line-height:20px;color:${C.muted};">
            <p style="margin:0 0 10px;font-family:${FONT};font-size:13px;line-height:20px;color:${C.muted};">${esc(c.footer)}</p>
            <p style="margin:0;font-family:${FONT};font-size:12px;line-height:18px;color:${C.muted};letter-spacing:0.02em;">PULSE &middot; Your people. Your moments.</p>
          </td>
        </tr>
      </table>
      <!--[if mso]></td></tr></table><![endif]-->
    </td>
  </tr>
</table>
</body>
</html>
`;
}

/** Plain-text alternative with the same content (and the link written out in full). */
export function renderText(c: EmailContent): string {
  const out: string[] = ['PULSE', '', c.heading, '', ...c.paragraphs.flatMap((t) => [t, ''])];
  for (const [k, v] of c.details ?? []) out.push(`${k}: ${v}`);
  if (c.details?.length) out.push('');
  if (c.code) out.push(`${c.codeLabel ?? 'Verification code'}: ${c.code}`, '');
  if (c.button) out.push(`${c.button.label}: ${c.button.href}`, '');
  if (c.note) out.push(c.note, '');
  if (c.notice) out.push(c.notice.title, c.notice.text, '');
  out.push(c.footer, '', 'PULSE · Your people. Your moments.');
  return out.join('\n');
}

export function renderEmail(c: EmailContent, subject: string): { subject: string; html: string; text: string } {
  return { subject, html: renderHtml(c, subject), text: renderText(c) };
}
