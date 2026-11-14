import { useEffect, useState } from 'react';
import { Navigate, Route, Routes, useLocation } from 'react-router-dom';
import { useAuth } from './lib/auth';
import { isConfigured, supabase } from './lib/supabase';
import { Spinner } from './components/ui';
import { Shell } from './components/Shell';
import { AccountBlocked, ForgotPassword, NotConfigured, ResetPassword, SignIn, SignUp } from './screens/Auth';
import { MfaChallenge } from './screens/MfaChallenge';
import { Chats } from './screens/Chats';
import { Chat } from './screens/Chat';
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
  return [needs, () => setTick((t) => t + 1)];
}

export function App() {
  const { loading, session, profile, recovering } = useAuth();
  const location = useLocation();
  const [needsMfa, recheckMfa] = useNeedsMfa(session?.access_token);

  if (!isConfigured) return <NotConfigured />;
  if (loading || (session && needsMfa === null)) return <div className="center" style={{ minHeight: '100%' }}><Spinner /></div>;

  if (!session) {
    return (
      <Routes>
        <Route path="/signup" element={<SignUp />} />
        <Route path="/forgot" element={<ForgotPassword />} />
        <Route path="/reset-password" element={<ResetPassword />} />
        <Route path="/signin" element={<SignIn />} />
        <Route path="*" element={<Navigate to="/signin" replace state={{ from: location.pathname }} />} />
      </Routes>
    );
  }
  if (needsMfa) return <MfaChallenge onDone={recheckMfa} />;
  if (recovering || location.pathname === '/reset-password') return <ResetPassword />;
  if (!profile) return <div className="center" style={{ minHeight: '100%' }}><Spinner /></div>;
  if (profile.account_state !== 'active') return <AccountBlocked state={profile.account_state} />;

  return (
    <Routes>
      <Route element={<Shell />}>
        <Route path="/camera" element={<Camera />} />
        <Route path="/chats" element={<Chats />} />
        <Route path="/chats/:id" element={<Chat />} />
        <Route path="/friends" element={<Friends />} />
        <Route path="/settings" element={<Settings />} />
        <Route path="*" element={<Navigate to="/chats" replace />} />
      </Route>
    </Routes>
  );
}
