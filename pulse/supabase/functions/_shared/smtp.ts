// Minimal SMTP sender for Edge Functions (no third-party code). Supabase blocks outbound
// ports 25 and 587, so production uses implicit TLS on port 465 (Gmail and Brevo both
// offer it). Locally it talks plain SMTP to Mailpit. Configuration comes only from
// function secrets — never from the browser:
//   PULSE_SMTP_HOST, PULSE_SMTP_PORT, PULSE_SMTP_TLS (implicit | none),
//   PULSE_SMTP_USER, PULSE_SMTP_PASS, PULSE_SMTP_FROM, PULSE_SMTP_FROM_NAME

/** text is always sent; html, when given, is sent alongside it (multipart/alternative). */
export interface Mail { to: string; subject: string; text: string; html?: string }

function config() {
  const host = Deno.env.get('PULSE_SMTP_HOST') ?? '';
  const from = Deno.env.get('PULSE_SMTP_FROM') ?? '';
  if (!host || !from) throw new Error('smtp_not_configured');
  const tls = (Deno.env.get('PULSE_SMTP_TLS') ?? 'implicit') === 'none' ? 'none' : 'implicit';
  return {
    host, from, tls,
    port: Number(Deno.env.get('PULSE_SMTP_PORT') ?? (tls === 'none' ? 25 : 465)),
    user: Deno.env.get('PULSE_SMTP_USER') ?? '',
    pass: Deno.env.get('PULSE_SMTP_PASS') ?? '',
    fromName: Deno.env.get('PULSE_SMTP_FROM_NAME') ?? 'PULSE',
  };
}

const enc = new TextEncoder();
const dec = new TextDecoder();
const clean = (s: string) => s.replace(/[\r\n]+/g, ' ').trim();   // no header injection
const b64 = (s: string) => { let out = ''; for (const b of enc.encode(s)) out += String.fromCharCode(b); return btoa(out); };
/** Base64 body wrapped at 76 characters (keeps every line far below SMTP's 998 limit). */
const b64Body = (s: string) => b64(s.replace(/\r?\n/g, '\r\n')).replace(/.{1,76}/g, '$&\r\n');
/** RFC 2047 encoded-word for headers that are not plain ASCII (e.g. curly quotes). */
const header = (s: string) => (/^[\x20-\x7e]*$/.test(s) ? s : `=?UTF-8?B?${b64(s)}?=`);

/** Sends one email (plain text, plus HTML when given). Throws on any SMTP error; the caller treats that as failed delivery. */
export async function sendMail(mail: Mail): Promise<void> {
  const c = config();
  if (!/^[^\s@<>]+@[^\s@<>]+$/.test(mail.to)) throw new Error('bad_recipient');
  const conn = c.tls === 'implicit'
    ? await Deno.connectTls({ hostname: c.host, port: c.port })
    : await Deno.connect({ hostname: c.host, port: c.port });
  const timer = setTimeout(() => { try { conn.close(); } catch { /* closed */ } }, 20_000);
  let buf = '';
  const readReply = async (): Promise<[number, string]> => {
    const chunk = new Uint8Array(4096);
    for (;;) {
      const lines = buf.split('\r\n');
      // A reply ends with a line "NNN text" (a space after the code, not a dash).
      for (let i = 0; i < lines.length - 1; i++) {
        if (/^\d{3} /.test(lines[i]!) || /^\d{3}$/.test(lines[i]!)) {
          const reply = lines.slice(0, i + 1).join('\n');
          buf = lines.slice(i + 1).join('\r\n');
          return [Number(lines[i]!.slice(0, 3)), reply];
        }
      }
      const n = await conn.read(chunk);
      if (n === null) throw new Error('smtp_connection_closed');
      buf += dec.decode(chunk.subarray(0, n));
    }
  };
  const send = async (line: string) => { await conn.write(enc.encode(line + '\r\n')); };
  const expect = async (ok: number[], what: string) => {
    const [code, text] = await readReply();
    if (!ok.includes(code)) throw new Error(`smtp_${what}_${code}: ${text.slice(0, 120)}`);
  };
  try {
    await expect([220], 'greeting');
    await send('EHLO pulse.app'); await expect([250], 'ehlo');
    if (c.user) {
      await send('AUTH PLAIN ' + b64(`\0${c.user}\0${c.pass}`)); await expect([235], 'auth');
    }
    await send(`MAIL FROM:<${clean(c.from)}>`); await expect([250], 'mail_from');
    await send(`RCPT TO:<${clean(mail.to)}>`); await expect([250, 251], 'rcpt_to');
    await send('DATA'); await expect([354], 'data');
    // Base64 bodies never start a line with "." (no dot-stuffing needed) and stay 7-bit.
    const boundary = `pulse-${crypto.randomUUID()}`;
    const textPart = ['Content-Type: text/plain; charset=utf-8', 'Content-Transfer-Encoding: base64', '', b64Body(mail.text)].join('\r\n');
    const body = mail.html
      ? [`--${boundary}`, textPart,
         `--${boundary}`, ['Content-Type: text/html; charset=utf-8', 'Content-Transfer-Encoding: base64', '', b64Body(mail.html)].join('\r\n'),
         `--${boundary}--`, ''].join('\r\n')
      : b64Body(mail.text);
    const headers = [
      `From: ${header(clean(c.fromName))} <${clean(c.from)}>`,
      `To: <${clean(mail.to)}>`,
      `Subject: ${header(clean(mail.subject))}`,
      `Date: ${new Date().toUTCString()}`,
      `Message-ID: <${crypto.randomUUID()}@pulse.app>`,
      'MIME-Version: 1.0',
      ...(mail.html
        ? [`Content-Type: multipart/alternative; boundary="${boundary}"`]
        : ['Content-Type: text/plain; charset=utf-8', 'Content-Transfer-Encoding: base64']),
      'Auto-Submitted: auto-generated',
    ].join('\r\n');
    await conn.write(enc.encode(`${headers}\r\n\r\n${body}\r\n.\r\n`));
    await expect([250], 'message');
    await send('QUIT');
  } finally {
    clearTimeout(timer);
    try { conn.close(); } catch { /* already closed */ }
  }
}
