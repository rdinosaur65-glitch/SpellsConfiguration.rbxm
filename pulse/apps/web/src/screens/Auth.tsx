import { useState, type FormEvent, type ReactNode } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { validateUsername, LIMITS } from '@pulse/domain';
import { supabase } from '../lib/supabase';
import { errorMessage } from '../lib/errors';
import { Banner, Button, Field } from '../components/ui';
import { useAuth } from '../lib/auth';

const redirectTo = () => `${window.location.origin}/`;
const PASSWORD_HINT = 'At least 8 characters, with letters and numbers.';

function validPassword(p: string): boolean {
  return p.length >= 8 && /[a-z]/i.test(p) && /\d/.test(p);
}

function AuthLayout({ subtitle, children }: { subtitle: string; children: ReactNode }) {
  return (
    <main className="auth">
      <div className="auth-card">
        <div className="brand">
          <img src="/icon.svg" alt="" />
          <h1>PULSE</h1>
          <p>{subtitle}</p>
        </div>
        {children}
      </div>
    </main>
  );
}

export function SignIn() {
  const [email, setEmail] = useState('');
  const [password, setPassword] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [unconfirmed, setUnconfirmed] = useState(false);
  const [info, setInfo] = useState<string | null>(null);

  async function submit(e: FormEvent) {
    e.preventDefault();
    setBusy(true); setError(null); setInfo(null); setUnconfirmed(false);
    const { error } = await supabase.auth.signInWithPassword({ email: email.trim(), password });
    setBusy(false);
    if (error) {
      setError(errorMessage(error));
      setUnconfirmed(error.message === 'Email not confirmed' || (error as { code?: string }).code === 'email_not_confirmed');
    }
  }

  async function resend() {
    const { error } = await supabase.auth.resend({ type: 'signup', email: email.trim(), options: { emailRedirectTo: redirectTo() } });
    if (error) setError(errorMessage(error)); else setInfo('Confirmation email sent again.');
  }

  return (
    <AuthLayout subtitle="Your people. Your moments.">
      <form className="stack" onSubmit={submit} noValidate>
        {error && <Banner>{error}{unconfirmed && <> <button type="button" className="link-btn" onClick={resend}>Resend email</button></>}</Banner>}
        {info && <Banner kind="success">{info}</Banner>}
        <Field label="Email" type="email" name="email" autoComplete="email" inputMode="email" required
               value={email} onChange={(e) => setEmail(e.target.value)} />
        <Field label="Password" type="password" name="password" autoComplete="current-password" required
               value={password} onChange={(e) => setPassword(e.target.value)} />
        <Button type="submit" busy={busy} disabled={!email || !password}>Sign in</Button>
        <div className="auth-alt"><Link to="/forgot">Forgot password?</Link></div>
      </form>
      <p className="auth-alt">New here? <Link to="/signup">Create an account</Link></p>
    </AuthLayout>
  );
}

export function SignUp() {
  const [email, setEmail] = useState('');
  const [username, setUsername] = useState('');
  const [displayName, setDisplayName] = useState('');
  const [password, setPassword] = useState('');
  const [touched, setTouched] = useState(false);
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [sentTo, setSentTo] = useState<string | null>(null);

  const u = validateUsername(username);
  const usernameError = touched && username && !u.ok ? errorMessage({ message: u.error }) : null;
  const passwordError = touched && password && !validPassword(password) ? PASSWORD_HINT : null;
  const canSubmit = email.includes('@') && u.ok && validPassword(password);

  async function submit(e: FormEvent) {
    e.preventDefault();
    setTouched(true);
    if (!canSubmit || !u.ok) return;
    setBusy(true); setError(null);
    const { data, error } = await supabase.auth.signUp({
      email: email.trim(), password,
      options: {
        emailRedirectTo: redirectTo(),
        data: { username: u.value, display_name: displayName.trim() || u.value },
      },
    });
    setBusy(false);
    if (error) { setError(errorMessage(error)); return; }
    // With confirmations on, Supabase returns no session until the link is clicked.
    if (!data.session) setSentTo(email.trim());
  }

  if (sentTo) {
    return (
      <AuthLayout subtitle="Almost there">
        <Banner kind="info">We sent a confirmation link to <strong>{sentTo}</strong>. Open it on this device to finish signing up.</Banner>
        <p className="legal">Unconfirmed sign-ups are removed after 48 hours and the username is released.</p>
        <p className="auth-alt"><Link to="/signin">Back to sign in</Link></p>
      </AuthLayout>
    );
  }

  return (
    <AuthLayout subtitle="Create your account">
      <form className="stack" onSubmit={submit} noValidate>
        {error && <Banner>{error}</Banner>}
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
        <Button type="submit" busy={busy} disabled={!canSubmit}>Create account</Button>
        <p className="legal">PULSE is friends-only: nobody can see your profile unless you accept them.</p>
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

  async function submit(e: FormEvent) {
    e.preventDefault();
    setBusy(true); setError(null);
    const { error } = await supabase.auth.resetPasswordForEmail(email.trim(), { redirectTo: `${window.location.origin}/reset-password` });
    setBusy(false);
    // Same message whether or not the address exists (no account enumeration).
    if (error && (error as { code?: string }).code === 'over_email_send_rate_limit') setError(errorMessage(error));
    else setDone(true);
  }

  return (
    <AuthLayout subtitle="Reset your password">
      {done ? (
        <Banner kind="info">If an account exists for <strong>{email}</strong>, a reset link is on its way.</Banner>
      ) : (
        <form className="stack" onSubmit={submit} noValidate>
          {error && <Banner>{error}</Banner>}
          <Field label="Email" type="email" name="email" autoComplete="email" required value={email}
                 onChange={(e) => setEmail(e.target.value)} />
          <Button type="submit" busy={busy} disabled={!email.includes('@')}>Send reset link</Button>
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
