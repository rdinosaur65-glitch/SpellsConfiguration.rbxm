import { useEffect, useState } from 'react';
import { Navigate, Route, Routes, useLocation, useNavigate } from 'react-router-dom';
import { useAuth } from './lib/auth';
import { useStepUpActive } from './lib/stepup';
import { isConfigured, supabase } from './lib/supabase';
import { Spinner } from './components/ui';
import { Shell } from './components/Shell';
import { AccountBlocked, ForgotPassword, NotConfigured, ResetPassword, SignIn, SignUp } from './screens/Auth';
import { MfaChallenge } from './screens/MfaChallenge';
import { Chats } from './screens/Chats';
import { Chat } from './screens/Chat';
import { GroupInfo } from './screens/GroupInfo';
import { Admin } from './screens/Admin';
import { Privacy } from './screens/Privacy';
import { Friends } from './screens/Friends';
import { Settings } from './screens/Settings';
import { Camera } from './screens/Camera';

function useNeedsMfa(sessionKey: string | undefined): [boolean | null, () => void] {
  const [needs, setNeeds] = useState<boolean | null>(null);
  const [tick, setTick] = useState(0);
  useEffect(() => {
    if (!sessionKey) { setNeeds(false); return; }
    let alive = true;
    supabase.auth.mfa.getAuthenticatorAssuranceLevel().then(({ data }) => {
      if (alive) setNeeds(data?.nextLevel === 'aal2' && data.currentLevel !== 'aal2');
    });
    return () => { alive = false; };
  }, [sessionKey, tick]);

  // 2FA may be turned on from another device while this one is signed in at aal1. The
  // server then answers "mfa_required"; refresh the session (it carries the factor list)
  // and check again. Also re-check when the app comes back to the foreground.
  useEffect(() => {
    if (!sessionKey) return;
    let last = 0;
    const recheck = (force: boolean) => {
      if (!force && Date.now() - last < 60_000) return;
      last = Date.now();
      void supabase.auth.refreshSession().finally(() => setTick((t) => t + 1));
    };
    const onRequired = () => recheck(true);
    const onVisible = () => { if (document.visibilityState === 'visible') recheck(false); };
    window.addEventListener('pulse:mfa-required', onRequired);
    document.addEventListener('visibilitychange', onVisible);
    return () => { window.removeEventListener('pulse:mfa-required', onRequired); document.removeEventListener('visibilitychange', onVisible); };
  }, [sessionKey]);
  return [needs, () => setTick((t) => t + 1)];
}

/**
 * Email links (confirmation, password reset) carry a one-time token hash. Verifying it
 * here needs no state from the browser that requested the email, so links work when
 * opened on another device or in another browser.
 */
function useEmailLink(): 'idle' | 'verifying' | 'failed' {
  const [state, setState] = useState<'idle' | 'verifying' | 'failed'>(() =>
    new URLSearchParams(window.location.search).has('token_hash') ? 'verifying' : 'idle');
  const nav = useNavigate();
  useEffect(() => {
    const params = new URLSearchParams(window.location.search);
    const tokenHash = params.get('token_hash');
    const type = params.get('type');
    if (!tokenHash || (type !== 'email' && type !== 'recovery' && type !== 'signup')) return;
    let alive = true;
    void supabase.auth.verifyOtp({ token_hash: tokenHash, type: type === 'signup' ? 'email' : type }).then(({ error }) => {
      if (!alive) return;
      const path = type === 'recovery' ? '/reset-password' : '/';
      window.history.replaceState(null, '', path);
      if (error) { setState('failed'); nav(type === 'recovery' ? '/reset-password' : '/signin', { replace: true, state: { linkFailed: true } }); }
      else { setState('idle'); nav(path, { replace: true }); }
    });
    return () => { alive = false; };
  }, [nav]);
  return state;
}

export function App() {
  const { loading, session, profile, recovering } = useAuth();
  const location = useLocation();
  const [needsMfa, recheckMfa] = useNeedsMfa(session?.access_token);
  const emailLink = useEmailLink();
  const stepUp = useStepUpActive();

  if (!isConfigured) return <NotConfigured />;
  if (loading || emailLink === 'verifying' || (session && needsMfa === null)) {
    return <div className="center" style={{ minHeight: '100%' }}><Spinner /></div>;
  }

  if (!session) {
    return (
      <Routes>
        <Route path="/signup" element={<SignUp />} />
        <Route path="/forgot" element={<ForgotPassword />} />
        <Route path="/reset-password" element={<ResetPassword />} />
        <Route path="/signin" element={<SignIn />} />
        <Route path="/privacy" element={<Privacy />} />
        <Route path="*" element={<Navigate to="/signin" replace state={{ from: location.pathname }} />} />
      </Routes>
    );
  }
  if (needsMfa && !stepUp) return <MfaChallenge onDone={recheckMfa} />;
  if (recovering || location.pathname === '/reset-password') return <ResetPassword />;
  if (!profile) return <div className="center" style={{ minHeight: '100%' }}><Spinner /></div>;
  if (profile.account_state !== 'active') return <AccountBlocked state={profile.account_state} />;

  return (
    <Routes>
      <Route element={<Shell />}>
        <Route path="/camera" element={<Camera />} />
        <Route path="/chats" element={<Chats />} />
        <Route path="/chats/:id" element={<Chat />} />
        <Route path="/chats/:id/info" element={<GroupInfo />} />
        <Route path="/friends" element={<Friends />} />
        <Route path="/settings" element={<Settings />} />
        <Route path="/admin" element={<Admin />} />
        <Route path="/privacy" element={<Privacy />} />
        <Route path="*" element={<Navigate to="/chats" replace />} />
      </Route>
    </Routes>
  );
}
