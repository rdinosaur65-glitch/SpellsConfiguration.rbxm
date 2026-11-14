import { useEffect, useState } from 'react';
import { supabase } from '../lib/supabase';
import { errorMessage } from '../lib/errors';
import { setStepUp } from '../lib/stepup';
import { Banner, Button, Field, Sheet } from './ui';
import { Captcha, captchaEnabled } from './Captcha';

const PROJECT_URL = (import.meta.env.VITE_SUPABASE_URL as string | undefined) ?? '';
const ANON_KEY = (import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined) ?? '';

async function callResetFunction(body: Record<string, unknown>): Promise<{ status: number; data: Record<string, unknown> }> {
  const { data } = await supabase.auth.getSession();
  const res = await fetch(`${PROJECT_URL}/functions/v1/owner-mfa-reset`, {
    method: 'POST', cache: 'no-store',
    headers: { Authorization: `Bearer ${data.session?.access_token ?? ''}`, apikey: ANON_KEY, 'Content-Type': 'application/json' },
    body: JSON.stringify(body),
  });
  let json: Record<string, unknown> = {};
  try { json = await res.json(); } catch { /* empty */ }
  return { status: res.status, data: json };
}

const REQUEST_ERRORS: Record<string, string> = {
  email_failed: 'The confirmation email could not be sent, so nothing was changed. Check the email (SMTP) settings and try again.',
  owner_email_unverified: 'Your owner email address is not verified, so no code can be sent.',
  smtp_sender_is_owner: 'PULSE sends email from your own address, which would reveal it to the person being reset. Use a separate PULSE mailbox for PULSE_SMTP_FROM / PULSE_SMTP_USER. Nothing was changed.',
  rate_limited: 'Too many reset attempts. Wait a while before requesting another code.',
  reauthentication_required: 'Please confirm your password again.',
};

/**
 * Owner-only: reset another user's two-step verification. Requires a fresh sign-in
 * (password, then the owner's own 2FA code), then a 6-digit code that the server emails
 * to the owner's verified address. The address and the code never reach this page.
 */
export function ResetMfaSheet({ email, target, onClose, onDone }:
  { email: string; target: { id: string; username: string }; onClose: () => void; onDone: (msg: string) => void }) {
  const [step, setStep] = useState<'auth' | 'totp' | 'code'>('auth');
  const [password, setPassword] = useState('');
  const [totp, setTotp] = useState('');
  const [reason, setReason] = useState('');
  const [code, setCode] = useState('');
  const [requestId, setRequestId] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [info, setInfo] = useState<string | null>(null);
  const [captcha, setCaptcha] = useState<string | null>(null);
  const [captchaKey, setCaptchaKey] = useState(0);
  useEffect(() => () => setStepUp(false), []);

  async function requestCode() {
    setBusy(true); setError(null); setInfo(null);
    const r = await callResetFunction({ action: 'request', target_id: target.id, reason: reason.trim() });
    setBusy(false);
    if (r.status !== 200) {
      const code = String(r.data.error ?? '');
      setError(REQUEST_ERRORS[code] ?? errorMessage({ message: code }));
      if (code === 'reauthentication_required') setStep('auth');
      return;
    }
    setRequestId(String(r.data.request_id)); setCode(''); setStep('code');
    setInfo('We emailed a 6-digit code to your owner email address. It expires in 5 minutes.');
  }

  // Fresh owner authentication: password (the server requires one within 10 minutes)…
  async function confirmPassword() {
    if (busy) return;
    setBusy(true); setError(null);
    setStepUp(true);
    const { error: authErr } = await supabase.auth.signInWithPassword({ email, password, options: { captchaToken: captcha ?? undefined } });
    setCaptcha(null); setCaptchaKey((k) => k + 1);
    if (authErr) { setBusy(false); setError(errorMessage(authErr)); return; }
    const { data: aal } = await supabase.auth.mfa.getAuthenticatorAssuranceLevel();
    setBusy(false);
    if (aal?.nextLevel === 'aal2' && aal.currentLevel !== 'aal2') { setStep('totp'); return; }
    await requestCode();
  }
  // …then the owner's own second factor.
  async function confirmTotp() {
    if (busy) return;
    setBusy(true); setError(null);
    const { data } = await supabase.auth.mfa.listFactors();
    const factor = data?.totp.find((f) => f.status === 'verified');
    const res = factor ? await supabase.auth.mfa.challengeAndVerify({ factorId: factor.id, code: totp.trim() }) : null;
    setBusy(false);
    if (!factor || res?.error) { setError('That code didn’t work. Try the newest code from your app.'); return; }
    await requestCode();
  }

  async function confirmCode() {
    if (busy || !requestId) return;
    setBusy(true); setError(null); setInfo(null);
    const r = await callResetFunction({ action: 'confirm', request_id: requestId, code: code.trim() });
    setBusy(false);
    const status = String(r.data.status ?? r.data.error ?? '');
    if (status === 'completed') {
      onDone(r.data.notified ? `Two-step verification reset for @${target.username}. They were emailed.`
        : `Two-step verification reset for @${target.username}, but the notice email could not be sent — tell them yourself.`);
      return;
    }
    if (status === 'incorrect') { setError(`That code is not right. ${String(r.data.attempts_left)} attempt(s) left.`); setCode(''); return; }
    const ended: Record<string, string> = {
      locked: 'Too many wrong codes: this request is locked. Nothing was changed.',
      expired: 'The code expired. Nothing was changed.',
      used: 'This code was already used.',
      cancelled: 'A newer request replaced this one.',
      failed: 'This request could not be completed. Nothing was changed.',
    };
    setError(ended[status] ?? errorMessage({ message: status }));
  }

  return (
    <Sheet label={`Reset two-step verification for ${target.username}`} onClose={onClose}>
      <h2 style={{ fontSize: 18, margin: '4px 4px 8px' }}>Reset 2FA for @{target.username}</h2>
      <p className="small muted" style={{ margin: '0 4px' }}>
        Only do this after confirming it is really them (a call or in person). Their password stays the same and is still needed;
        they will be signed out everywhere and told by email.</p>
      {error && <Banner>{error}</Banner>}
      {info && <Banner kind="info">{info}</Banner>}
      {step === 'auth' && (
        <>
          <Field label="Reason (kept in the audit log)" value={reason} maxLength={500} onChange={(e) => setReason(e.target.value)} />
          <Field label="Your password" type="password" autoComplete="current-password" value={password}
                 onChange={(e) => setPassword(e.target.value)} />
          <Captcha key={captchaKey} onToken={setCaptcha} />
          <Button busy={busy} disabled={!password || !reason.trim() || (captchaEnabled && !captcha)} onClick={confirmPassword}>Continue</Button>
        </>
      )}
      {step === 'totp' && (
        <>
          <Field label="Code from your authenticator app" inputMode="numeric" autoComplete="one-time-code" maxLength={6}
                 autoFocus value={totp} onChange={(e) => setTotp(e.target.value.replace(/\D/g, ''))} />
          <Button busy={busy} disabled={totp.length !== 6} onClick={confirmTotp}>Continue</Button>
        </>
      )}
      {step === 'code' && (
        <>
          <Field label="Code from the email" inputMode="numeric" autoComplete="one-time-code" maxLength={6}
                 autoFocus value={code} onChange={(e) => setCode(e.target.value.replace(/\D/g, ''))} />
          <Button variant="danger" busy={busy} disabled={code.length !== 6} onClick={confirmCode}>Reset two-step verification</Button>
          <Button variant="ghost" disabled={busy} onClick={() => void requestCode()}>Send a new code</Button>
        </>
      )}
      <Button variant="ghost" onClick={onClose}>Cancel</Button>
    </Sheet>
  );
}
