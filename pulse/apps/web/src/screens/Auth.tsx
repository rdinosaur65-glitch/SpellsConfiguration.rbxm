import { useEffect, useState, type FormEvent, type ReactNode } from 'react';
import { Link, useLocation, useNavigate, useSearchParams } from 'react-router-dom';
import { validateUsername, LIMITS } from '@pulse/domain';
import { rpc, supabase } from '../lib/supabase';
import { errorMessage } from '../lib/errors';
import { Banner, Button, Field } from '../components/ui';
import { useAuth } from '../lib/auth';
import { Captcha, captchaEnabled } from '../components/Captcha';
import { EMAIL_PENDING } from '../lib/features';

const redirectTo = () => `${window.location.origin}${import.meta.env.BASE_URL}`;
const PASSWORD_HINT = 'At least 8 characters, with letters and numbers.';

function validPassword(p: string): boolean {
  return p.length >= 8 && /[a-z]/i.test(p) && /\d/.test(p);
}

function AuthLayout({ subtitle, children }: { subtitle: string; children: ReactNode }) {
  return (
    <main className="auth">
      <div className="auth-card">
        <div className="brand">
          <img src={`${import.meta.env.BASE_URL}icon.svg`} alt="" />
          <h1>PULSE</h1>
          <p>{subtitle}</p>
        </div>
        {children}
      </div>
    </main>
  );
}

export function SignIn() {
  const linkFailed = Boolean((useLocation().state as { linkFailed?: boolean } | null)?.linkFailed);
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [unconfirmed, setUnconfirmed] = useState(false);
  const [info, setInfo] = useState<string | null>(null);
  const [captcha, setCaptcha] = useState<string | null>(null);
  const [captchaKey, setCaptchaKey] = useState(0);
  const resetCaptcha = () => { setCaptcha(null); setCaptchaKey((k) => k + 1); };   // tokens are single-use

  async function submit(e: FormEvent) {
    e.preventDefault();
    setBusy(true); setError(null); setInfo(null); setUnconfirmed(false);
    const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password, options: { captchaToken: captcha ?? undefined } });
    setBusy(false);
    resetCaptcha();
    if (error) {
      setError(errorMessage(error));
      setUnconfirmed(error.message === 'Email not confirmed' || (error as { code?: string }).code === 'email_not_confirmed');
    }
  }

  async function resend() {
    const { error } = await supabase.auth.resend({ type: 'signup', email: email.trim(), options: { emailRedirectTo: redirectTo(), captchaToken: captcha ?? undefined } });
    resetCaptcha();
    if (error) setError(errorMessage(error)); else setInfo('Confirmation email sent again.');
  }

  return (
    <AuthLayout subtitle="Your people. Your moments.">
      <form className="stack" onSubmit={submit} noValidate>
        {linkFailed && !error && <Banner>That confirmation link is invalid or has expired. Sign in to get a new one.</Banner>}
        {error && <Banner>{error}{unconfirmed && <> <button type="button" className="link-btn" onClick={resend}>Resend email</button></>}</Banner>}
        {info && <Banner kind="success">{info}</Banner>}
        <Field label="Email" type="email" name="email" autoComplete="email" inputMode="email" required
               value={email} onChange={(e) => setEmail(e.target.value)} />
        <Field label="Password" type="password" name="password" autoComplete="current-password" required
               value={password} onChange={(e) => setPassword(e.target.value)} />
        <Captcha key={captchaKey} onToken={setCaptcha} />
        <Button type="submit" busy={busy} disabled={!email || !password || (captchaEnabled && !captcha)}>Sign in</Button>
        <div className="auth-alt"><Link to="/forgot">Forgot password?</Link></div>
      </form>
      <p className="auth-alt">New here? <Link to="/signup">Create an account</Link></p>
    </AuthLayout>
  );
}

type InviteState = 'pending' | 'redeemed' | 'expired' | 'revoked' | 'invalid' | null;
interface RegistrationStatus { mode: 'invite_only' | 'public'; invite: InviteState; public_full: boolean }
const INVITE_PROBLEM: Record<string, string> = {
  invalid: 'That invitation code doesn’t exist. Check it, or ask the PULSE owner for a new one.',
  redeemed: 'That invitation has already been used. Ask the PULSE owner for a new one.',
  expired: 'That invitation has expired. Ask the PULSE owner for a new one.',
  revoked: 'That invitation was cancelled. Ask the PULSE owner for a new one.',
};
/** "abcd efgh-jkmn" → "ABCD-EFGH-JKMN" (O typed for zero is accepted). */
export function formatInvite(raw: string): string {
  const c = raw.toUpperCase().replace(/[^A-Z0-9]/g, '').replace(/O/g, '0').slice(0, 12);
  return c.match(/.{1,4}/g)?.join('-') ?? '';
}

/** Invitation code check (signed out; never uses the code up — only creating the account does,
 *  and the database decides). */
function useRegistration(code: string) {
  const [status, setStatus] = useState<RegistrationStatus | null>(null);
  const [checking, setChecking] = useState(false);
  useEffect(() => {
    let alive = true;
    const complete = code.replace(/-/g, '').length === 12;
    setChecking(complete);
    const t = setTimeout(() => {
      rpc<RegistrationStatus>('registration_status', { p_code: complete ? code : null })
        .then((r) => { if (alive) setStatus(r); })
        .catch(() => { if (alive) setStatus((s) => s ?? { mode: 'invite_only', invite: null, public_full: false }); })
        .finally(() => { if (alive) setChecking(false); });
    }, complete ? 250 : 0);
    return () => { alive = false; clearTimeout(t); };
  }, [code]);
  return { status, checking };
}

export function SignUp() {
  const [params] = useSearchParams();
  const [invite, setInvite] = useState(() => formatInvite(params.get('invite') ?? ''));
  const { status: reg, checking } = useRegistration(invite);
  const [email, setEmail] = useState('');
  const [username, setUsername] = useState('');
  const [displayName, setDisplayName] = useState('');
  const [password, setPassword] = useState('');
  const [touched, setTouched] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [sentTo, setSentTo] = useState<string | null>(null);
  const [captcha, setCaptcha] = useState<string | null>(null);
  const [captchaKey, setCaptchaKey] = useState(0);

  const u = validateUsername(username);
  const usernameError = touched && username && !u.ok ? errorMessage({ message: u.error }) : null;
  const passwordError = touched && password && !validPassword(password) ? PASSWORD_HINT : null;
  const inviteOnly = reg?.mode !== 'public';
  const inviteComplete = invite.replace(/-/g, '').length === 12;
  const inviteOk = reg?.invite === 'pending';
  const fromLink = Boolean(params.get('invite'));
  const inviteError = inviteComplete && !checking && reg?.invite && reg.invite !== 'pending' ? INVITE_PROBLEM[reg.invite]
    : fromLink && invite && !inviteComplete ? 'This invitation link looks incomplete: a code has 12 letters and numbers (XXXX-XXXX-XXXX). Check the link, or type the code.'
    : null;
  const closed = reg?.mode === 'public' && reg.public_full && !inviteOk;
  const canSubmit = email.includes('@') && u.ok && validPassword(password) && (inviteOnly ? inviteOk : !closed) && !checking;

  async function submit(e: FormEvent) {
    e.preventDefault();
    setTouched(true);
    if (!canSubmit || !u.ok) return;
    setBusy(true); setError(null);
    const { data, error } = await supabase.auth.signUp({
      email: email.trim(), password,
      options: {
        emailRedirectTo: redirectTo(),
        data: { username: u.value, display_name: displayName.trim() || u.value, ...(inviteComplete ? { invite_code: invite } : {}) },
        captchaToken: captcha ?? undefined,
      },
    });
    setBusy(false);
    setCaptcha(null); setCaptchaKey((k) => k + 1);
    if (error) {
      // The database refuses the account if the invitation was used up meanwhile; say which.
      let msg = errorMessage(error);
      if (inviteComplete) {
        const now = await rpc<RegistrationStatus>('registration_status', { p_code: invite }).catch(() => null);
        if (now?.invite && now.invite !== 'pending') msg = INVITE_PROBLEM[now.invite] ?? msg;
        else if (/Database error/i.test(error.message)) msg = 'We couldn’t create that account. That username may be taken — try another.';
      }
      setError(msg);
      return;
    }
    // With confirmations on, Supabase returns no session until the link is clicked.
    if (!data.session) setSentTo(email.trim());
  }

  if (sentTo) {
    return (
      <AuthLayout subtitle="Almost there">
        <Banner kind="info">We sent a confirmation link to <strong>{sentTo}</strong>. Open it to finish signing up (any device works).</Banner>
        <p className="legal">The link expires in an hour. Unconfirmed sign-ups are removed after 6 hours and the username is released.</p>
        <p className="auth-alt"><Link to="/signin">Back to sign in</Link></p>
      </AuthLayout>
    );
  }

  return (
    <AuthLayout subtitle="Create your account">
      <form className="stack" onSubmit={submit} noValidate>
        {reg && inviteOnly && !inviteComplete && (
          <Banner kind="info" testId="invite-only">PULSE is invite-only. Open the invitation link you were sent, or enter its code below.</Banner>
        )}
        {closed && <Banner>{errorMessage({ message: 'registration_closed' })}</Banner>}
        {EMAIL_PENDING && <Banner kind="info" testId="email-pending">PULSE email is still being set up, so confirmation
          emails may not arrive yet. The owner will tell you when sign-ups are open.</Banner>}
        {error && <Banner>{error}</Banner>}
        {(inviteOnly || invite) && (
          <Field label={inviteOnly ? 'Invitation code' : 'Invitation code (optional)'} name="invite" autoComplete="off" autoCapitalize="characters"
                 spellCheck={false} maxLength={14} placeholder="XXXX-XXXX-XXXX" value={invite}
                 onChange={(e) => setInvite(formatInvite(e.target.value))}
                 hint={inviteOk ? 'Invitation accepted ✓' : checking ? 'Checking…' : 'From your invitation link.'} error={inviteError} />
        )}
        <Field label="Email" type="email" name="email" autoComplete="email" inputMode="email" required
               value={email} onChange={(e) => setEmail(e.target.value)} />
        <Field label="Username" name="username" autoComplete="username" autoCapitalize="none" spellCheck={false} required
               maxLength={LIMITS.username.max} value={username}
               onChange={(e) => setUsername(e.target.value.toLowerCase())} onBlur={() => setTouched(true)}
               hint="3–20 characters: a–z, 0–9, dots and underscores." error={usernameError} />
        <Field label="Display name (optional)" name="display_name" autoComplete="nickname" maxLength={LIMITS.displayNameMax}
               value={displayName} onChange={(e) => setDisplayName(e.target.value)} />
        <Field label="Password" type="password" name="new-password" autoComplete="new-password" required
               value={password} onChange={(e) => setPassword(e.target.value)} onBlur={() => setTouched(true)}
               hint={PASSWORD_HINT} error={passwordError} />
        <Captcha key={captchaKey} onToken={setCaptcha} />
        <Button type="submit" busy={busy} disabled={!canSubmit || (captchaEnabled && !captcha)}>Create account</Button>
        <p className="legal">PULSE is friends-only: nobody can see your profile unless you accept them.
          By creating an account you agree to the <Link to="/privacy">privacy notice and rules</Link>.</p>
      </form>
      <p className="auth-alt">Already have an account? <Link to="/signin">Sign in</Link></p>
    </AuthLayout>
  );
}

export function ForgotPassword() {
  const [email, setEmail] = useState('');
  const [busy, setBusy] = useState(false);
  const [done, setDone] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [captcha, setCaptcha] = useState<string | null>(null);
  const [captchaKey, setCaptchaKey] = useState(0);

  async function submit(e: FormEvent) {
    e.preventDefault();
    setBusy(true); setError(null);
    const { error } = await supabase.auth.resetPasswordForEmail(email.trim(),
      { redirectTo: `${window.location.origin}${import.meta.env.BASE_URL}reset-password`, captchaToken: captcha ?? undefined });
    setBusy(false);
    setCaptcha(null); setCaptchaKey((k) => k + 1);
    // Same message whether or not the address exists (no account enumeration), but never
    // claim an email is on its way when the request did not reach the server.
    const code = (error as { code?: string; status?: number } | null);
    if (error && (code?.code === 'over_email_send_rate_limit' || code?.code === 'over_request_rate_limit'
        || error.name === 'AuthRetryableFetchError' || code?.status === 0 || navigator.onLine === false)) {
      setError(errorMessage(error));
    } else setDone(true);
  }

  return (
    <AuthLayout subtitle="Reset your password">
      {EMAIL_PENDING ? (
        <Banner kind="info" testId="email-pending">Password reset by email isn’t available yet: PULSE email is still being
          set up. If you can’t sign in, ask the PULSE owner for help.</Banner>
      ) : done ? (
        <Banner kind="info">If an account exists for <strong>{email}</strong>, a reset link is on its way.</Banner>
      ) : (
        <form className="stack" onSubmit={submit} noValidate>
          {error && <Banner>{error}</Banner>}
          <Field label="Email" type="email" name="email" autoComplete="email" required value={email}
                 onChange={(e) => setEmail(e.target.value)} />
          <Captcha key={captchaKey} onToken={setCaptcha} />
          <Button type="submit" busy={busy} disabled={!email.includes('@') || (captchaEnabled && !captcha)}>Send reset link</Button>
        </form>
      )}
      <p className="auth-alt"><Link to="/signin">Back to sign in</Link></p>
    </AuthLayout>
  );
}

/** Reached from the recovery email: the link signs the user in, then they set a new password. */
export function ResetPassword() {
  const { session, clearRecovery } = useAuth();
  const nav = useNavigate();
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit(e: FormEvent) {
    e.preventDefault();
    if (!validPassword(password)) { setError(PASSWORD_HINT); return; }
    setBusy(true); setError(null);
    const { error } = await supabase.auth.updateUser({ password });
    setBusy(false);
    if (error) { setError(errorMessage(error)); return; }
    clearRecovery();
    nav('/', { replace: true });
  }

  if (!session) {
    return (
      <AuthLayout subtitle="Reset your password">
        <Banner>This reset link is invalid or has expired.</Banner>
        <p className="auth-alt"><Link to="/forgot">Request a new link</Link></p>
      </AuthLayout>
    );
  }
  return (
    <AuthLayout subtitle="Choose a new password">
      <form className="stack" onSubmit={submit} noValidate>
        {error && <Banner>{error}</Banner>}
        <Field label="New password" type="password" name="new-password" autoComplete="new-password" required
               value={password} onChange={(e) => setPassword(e.target.value)} hint={PASSWORD_HINT} />
        <Button type="submit" busy={busy}>Save password</Button>
      </form>
    </AuthLayout>
  );
}

export function NotConfigured() {
  return (
    <AuthLayout subtitle="Setup needed">
      <Banner kind="info">
        Set <code>VITE_SUPABASE_URL</code> and <code>VITE_SUPABASE_ANON_KEY</code> in <code>apps/web/.env.local</code>.
        See <code>docs/ENVIRONMENT.md</code>.
      </Banner>
    </AuthLayout>
  );
}

export function AccountBlocked({ state }: { state: string }) {
  return (
    <AuthLayout subtitle="Account unavailable">
      <Banner>This account is {state}. If you think this is a mistake, contact the PULSE owner.</Banner>
      <Button variant="ghost" onClick={() => supabase.auth.signOut()}>Sign out</Button>
    </AuthLayout>
  );
}
