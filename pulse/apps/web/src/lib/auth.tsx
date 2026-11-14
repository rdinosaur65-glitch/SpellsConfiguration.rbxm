import { createContext, useCallback, useContext, useEffect, useMemo, useState, type ReactNode } from 'react';
import type { Session } from '@supabase/supabase-js';
import { rpc, supabase } from './supabase';
import type { Profile, UserSettings } from './types';
import { applyAppearance } from './theme';

interface AuthState {
  loading: boolean;
  session: Session | null;
  profile: Profile | null;
  settings: UserSettings | null;
  isOwner: boolean;
  /** Set when the user arrived from a password-recovery email link. */
  recovering: boolean;
  refresh: () => Promise<void>;
  updateSettings: (patch: Partial<Omit<UserSettings, 'user_id'>>) => Promise<void>;
  clearRecovery: () => void;
}

const AuthContext = createContext<AuthState | null>(null);

export function AuthProvider({ children }: { children: ReactNode }) {
  const [loading, setLoading] = useState(true);
  const [session, setSession] = useState<Session | null>(null);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [settings, setSettings] = useState<UserSettings | null>(null);
  const [isOwner, setIsOwner] = useState(false);
  const [recovering, setRecovering] = useState(false);

  const load = useCallback(async (s: Session | null) => {
    if (!s) {
      setProfile(null); setSettings(null); setIsOwner(false);
      return;
    }
    const uid = s.user.id;
    const [p, st, owner] = await Promise.all([
      supabase.from('profiles').select('id,username,display_name,bio,status_text,account_state,username_changed_at,created_at').eq('id', uid).maybeSingle(),
      supabase.from('user_settings').select('*').eq('user_id', uid).maybeSingle(),
      rpc<boolean>('am_i_owner').catch(() => false),
    ]);
    setProfile((p.data as Profile | null) ?? null);
    setSettings((st.data as UserSettings | null) ?? null);
    setIsOwner(Boolean(owner));
  }, []);

  useEffect(() => {
    let alive = true;
    supabase.auth.getSession().then(async ({ data }) => {
      if (!alive) return;
      setSession(data.session);
      await load(data.session);
      if (alive) setLoading(false);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((event, s) => {
      if (event === 'PASSWORD_RECOVERY') setRecovering(true);
      setSession(s);
      // Defer DB calls out of the auth callback (supabase-js recommendation).
      if (event === 'SIGNED_IN' || event === 'SIGNED_OUT' || event === 'USER_UPDATED') {
        setTimeout(() => { void load(s); }, 0);
      }
    });
    return () => { alive = false; sub.subscription.unsubscribe(); };
  }, [load]);

  useEffect(() => { applyAppearance(settings?.appearance); }, [settings?.appearance]);

  // Presence heartbeat while the app is visible (server filters it by Ghost Mode).
  useEffect(() => {
    if (!profile || profile.account_state !== 'active') return;
    const beat = () => { if (document.visibilityState === 'visible') void rpc('touch_presence').catch(() => {}); };
    beat();
    const t = setInterval(beat, 60_000);
    document.addEventListener('visibilitychange', beat);
    return () => { clearInterval(t); document.removeEventListener('visibilitychange', beat); };
  }, [profile]);

  const updateSettings = useCallback(async (patch: Partial<Omit<UserSettings, 'user_id'>>) => {
    if (!settings) return;
    const prev = settings;
    setSettings({ ...settings, ...patch });          // optimistic
    const { error } = await supabase.from('user_settings')
      .update({ ...patch, updated_at: new Date().toISOString() }).eq('user_id', settings.user_id);
    if (error) { setSettings(prev); throw error; }
  }, [settings]);

  const value = useMemo<AuthState>(() => ({
    loading, session, profile, settings, isOwner, recovering,
    refresh: () => load(session),
    updateSettings,
    clearRecovery: () => setRecovering(false),
  }), [loading, session, profile, settings, isOwner, recovering, load, updateSettings]);

  return <AuthContext.Provider value={value}>{children}</AuthContext.Provider>;
}

export function useAuth(): AuthState {
  const ctx = useContext(AuthContext);
  if (!ctx) throw new Error('useAuth outside AuthProvider');
  return ctx;
}
