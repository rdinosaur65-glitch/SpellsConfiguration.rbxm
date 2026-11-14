import { useState, type FormEvent } from 'react';
import { supabase } from '../lib/supabase';
import { Banner, Button, Field } from '../components/ui';

/** Second sign-in step for accounts with a verified TOTP factor (raises the session to aal2). */
export function MfaChallenge({ onDone }: { onDone: () => void }) {
  const [code, setCode] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);

  async function submit(e: FormEvent) {
    e.preventDefault();
    setBusy(true); setError(null);
    const { data } = await supabase.auth.mfa.listFactors();
    const factor = data?.totp.find((f) => f.status === 'verified');
    if (!factor) { setBusy(false); onDone(); return; }
    const { error } = await supabase.auth.mfa.challengeAndVerify({ factorId: factor.id, code: code.trim() });
    setBusy(false);
    if (error) setError('That code didn’t work. Try the newest code from your app.'); else onDone();
  }
  return (
    <main className="auth">
      <form className="auth-card" onSubmit={submit}>
        <div className="brand"><img src={`${import.meta.env.BASE_URL}icon.svg`} alt="" /><h1>PULSE</h1><p>Two-step verification</p></div>
        {error && <Banner>{error}</Banner>}
        <Field label="Code from your authenticator app" inputMode="numeric" autoComplete="one-time-code" maxLength={6}
               autoFocus value={code} onChange={(e) => setCode(e.target.value.replace(/\D/g, ''))} />
        <Button type="submit" busy={busy} disabled={code.length !== 6}>Verify</Button>
        <Button type="button" variant="ghost" onClick={() => supabase.auth.signOut({ scope: 'local' })}>Use a different account</Button>
      </form>
    </main>
  );
}
