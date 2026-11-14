// owner-mfa-reset — resetting another account's two-step verification needs a code that
// is emailed to the owner's verified address (migration 0021 describes the full flow).
//
//   POST { action: 'request', target_id, reason }   → { request_id, expires_in }
//   POST { action: 'confirm', request_id, code }    → { status, attempts_left?, notified? }
//
// The caller's JWT is checked by the database (owner, aal2, fresh password sign-in).
// The code and the owner's address never leave the server: the code is generated in the
// database, emailed here, and only its hash is kept. If the email cannot be delivered the
// request is marked failed and can never complete — there is no other path. Mail must be
// sent from a PULSE mailbox, not the owner's own, so the notice cannot reveal the owner.
import { CORS, SERVICE_KEY, UUID, json, rpc } from '../_shared/http.ts';
import { sendMail } from '../_shared/smtp.ts';

const STATUS: Record<string, number> = {
  not_authenticated: 401, mfa_required: 401, forbidden: 403, owner_mfa_required: 403, reauthentication_required: 401,
  rate_limited: 429, reason_required: 400, user_not_found: 404, cannot_moderate_owner: 400,
  owner_email_unverified: 409, request_not_found: 404,
};

function codeEmail(code: string, target: string): { subject: string; text: string } {
  return {
    subject: 'PULSE: confirm a two-step verification reset',
    text: [
      `A two-step verification reset was requested for @${target} from the PULSE owner panel.`,
      '',
      `Confirmation code: ${code}`,
      '',
      'The code works once and expires in 5 minutes. Enter it in the owner panel to continue.',
      'If you did not start this, do not enter the code: nothing changes without it.',
      'Consider changing your password and checking "Where you\'re signed in".',
    ].join('\n'),
  };
}

const NOTICE = {
  subject: 'PULSE: two-step verification was reset on your account',
  text: [
    'Two-step verification on your PULSE account was reset by the PULSE administrator,',
    'and you were signed out on all devices.',
    '',
    'Sign in again with your password, then turn two-step verification back on in',
    'Settings → Security.',
    '',
    'If you did not ask for this, change your password straight away and contact the',
    'person who invited you to PULSE.',
  ].join('\n'),
};

Deno.serve(async (req) => {
  if (req.method === 'OPTIONS') return new Response('ok', { headers: CORS });
  if (req.method !== 'POST') return json(405, { error: 'method_not_allowed' });
  const auth = req.headers.get('Authorization') ?? '';
  const token = auth.startsWith('Bearer ') ? auth.slice(7) : '';
  if (!token) return json(401, { error: 'not_authenticated' });
  let body: { action?: string; target_id?: string; reason?: string; request_id?: string; code?: string };
  try { body = await req.json(); } catch { return json(400, { error: 'invalid_body' }); }

  if (body.action === 'request') {
    if (!UUID.test(body.target_id ?? '') || typeof body.reason !== 'string') return json(400, { error: 'invalid_body' });
    const created = await rpc<string>('admin_mfa_reset_request', { p_user: body.target_id, p_reason: body.reason }, token);
    if (!created.ok) return json(STATUS[created.code] ?? 403, { error: created.code });
    const requestId = created.data;
    const issued = await rpc<Array<{ code: string; owner_email: string; target_username: string }>>(
      'mfa_reset_issue_code', { p_request: requestId }, SERVICE_KEY);
    if (!issued.ok || !issued.data[0]) return json(500, { error: 'issue_failed' });
    const { code, owner_email, target_username } = issued.data[0];
    // The notice to the affected user must never reveal the owner's address, so refuse to
    // run while mail would be sent from (or through) the owner's own mailbox.
    const owner = owner_email.trim().toLowerCase();
    const senders = [Deno.env.get('PULSE_SMTP_FROM'), Deno.env.get('PULSE_SMTP_USER')]
      .map((v) => (v ?? '').trim().toLowerCase()).filter(Boolean);
    if (senders.includes(owner)) {
      await rpc('mfa_reset_mark_sent', { p_request: requestId, p_delivered: false, p_error: 'smtp sender is the owner address' }, SERVICE_KEY);
      return json(409, { error: 'smtp_sender_is_owner' });
    }
    try {
      await sendMail({ to: owner_email, ...codeEmail(code, target_username) });
    } catch (e) {
      await rpc('mfa_reset_mark_sent', { p_request: requestId, p_delivered: false, p_error: String((e as Error).message ?? e) }, SERVICE_KEY);
      return json(502, { error: 'email_failed' });
    }
    const sent = await rpc('mfa_reset_mark_sent', { p_request: requestId, p_delivered: true }, SERVICE_KEY);
    if (!sent.ok) return json(500, { error: 'issue_failed' });
    return json(200, { request_id: requestId, expires_in: 300 });
  }

  if (body.action === 'confirm') {
    if (!UUID.test(body.request_id ?? '') || typeof body.code !== 'string') return json(400, { error: 'invalid_body' });
    const checked = await rpc<{ status: string; attempts_left?: number }>(
      'admin_mfa_reset_confirm', { p_request: body.request_id, p_code: body.code.trim() }, token);
    if (!checked.ok) return json(STATUS[checked.code] ?? 403, { error: checked.code });
    if (checked.data.status !== 'verified') return json(200, checked.data);
    const done = await rpc<Array<{ target_email: string | null }>>('mfa_reset_execute', { p_request: body.request_id }, SERVICE_KEY);
    if (!done.ok) return json(500, { error: done.code });
    let notified = false;
    const email = done.data[0]?.target_email;
    if (email) {
      try { await sendMail({ to: email, ...NOTICE }); notified = true; } catch { notified = false; }
    }
    await rpc('mfa_reset_notified', { p_request: body.request_id, p_delivered: notified }, SERVICE_KEY);
    return json(200, { status: 'completed', notified });
  }

  return json(400, { error: 'invalid_action' });
});
