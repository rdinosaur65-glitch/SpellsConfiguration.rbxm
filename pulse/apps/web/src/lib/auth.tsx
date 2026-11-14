import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import type { Session } from '@supabase/supabase-js';
import { rpc, supabase } from './supabase';
import type { Profile, UserSettings } from './types';
import { applyAppearance } from './theme';
import { releaseAllMedia } from './media';
import { resyncPush } from './push';

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

// Non-sensitive copy of the user's own profile + settings for the offline shell only.
// Never chats, friends or media. Cleared on sign-out.
const CACHE_KEY = 'pulse.me.v1';
let lastSettingsReload = Date.now();   // module-level: survives session/token changes
interface Cached { uid: string; profile: Profile; settings: UserSettings }
function readCache(uid: string): Cached | null {
  try { const c = JSON.parse(localStorage.getItem(CACHE_KEY) ?? 'null') as Cached | null; return c?.uid === uid ? c : null; }
  catch { return null; }
}
function writeCache(uid: string, v: Omit<Cached, 'uid'>) {
  try { localStorage.setItem(CACHE_KEY, JSON.stringify({ uid, ...v })); } catch { /* storage unavailable */ }
}
/** The session supabase-js keeps in this browser (even when its access token has expired). */
function readStoredSession(): Session | null {
  try {
    for (let i = 0; i < localStorage.length; i++) {
      const k = localStorage.key(i);
      if (!k || !/^sb-.+-auth-token$/.test(k)) continue;
      const v = JSON.parse(localStorage.getItem(k) ?? 'null') as Session | null;
      if (v?.user?.id && v.refresh_token) return v;
    }
  } catch { /* storage unavailable */ }
  return null;
}
function clearCache() { try { localStorage.removeItem(CACHE_KEY); } catch { /* ignore */ } }

export function AuthProvider({ children }: { children: ReactNode }) {
  const [loading, setLoading] = useState(true);
  const [session, setSession] = useState<Session | null>(null);
  const [profile, setProfile] = useState<Profile | null>(null);
  const [settings, setSettings] = useState<UserSettings | null>(null);
  const [isOwner, setIsOwner] = useState(false);
  const [recovering, setRecovering] = useState(false);
  // Each load gets a number; a slower, older load can never overwrite a newer one
  // (or re-write the cache after sign-out / an account switch).
  const loadSeq = useRef(0);
  const provisional = useRef(false);   // showing the cached copy before the token could be refreshed
  const settingsRef = useRef<UserSettings | null>(null);
  settingsRef.current = settings;

  const load = useCallback(async (s: Session | null) => {
    const seq = ++loadSeq.current;
    if (!s) {
      setProfile(null); setSettings(null); setIsOwner(false);
      clearCache();
      releaseAllMedia();   // in-memory photo copies of the previous account
      return;
    }
    const uid = s.user.id;
    const [p, st, owner] = await Promise.all([
      supabase.rpc('my_profile'),
      supabase.from('user_settings').select('*').eq('user_id', uid).maybeSingle(),
      rpc<boolean>('am_i_owner').catch(() => false),
    ]);
    if (seq !== loadSeq.current) return;
    const row = Array.isArray(p.data) ? (p.data[0] as Profile | undefined) : undefined;
    if (p.error || st.error || (row?.account_state === 'active' && !st.data)) {
      // Offline (or transient failure): fall back to the last copy so the shell still opens.
      const cached = readCache(uid);
      if (cached) { setProfile(cached.profile); setSettings(cached.settings); }
      else if (row) setProfile(row);
      return;
    }
    const nextProfile = row ?? null;
    const nextSettings = (st.data as UserSettings | null) ?? null;
    setProfile(nextProfile); setSettings(nextSettings); setIsOwner(Boolean(owner));
    if (nextProfile && nextSettings && nextProfile.account_state === 'active') {
      writeCache(uid, { profile: nextProfile, settings: nextSettings });
    }
  }, []);

  useEffect(() => {
    let alive = true;
    // Open at once from the last copy: offline, supabase-js first retries the token refresh
    // for a long time, and an expired token must not look like being signed out.
    const stored = readStoredSession();
    const early = stored ? readCache(stored.user.id) : null;
    if (stored && early) {
      provisional.current = true;
      setSession(stored); setProfile(early.profile); setSettings(early.settings); setLoading(false);
    }
    supabase.auth.getSession().then(async ({ data }) => {
      if (!alive) return;
      if (!data.session && early && readStoredSession()) {
        // The token could not be refreshed (offline) but the sign-in is still stored: keep
        // the cached copy; TOKEN_REFRESHED loads everything once the network is back.
        return;
      }
      provisional.current = false;
      setSession(data.session);
      await load(data.session);
      if (alive) setLoading(false);
    });
    const { data: sub } = supabase.auth.onAuthStateChange((event, s) => {
      if (event === 'PASSWORD_RECOVERY') setRecovering(true);
      if (event === 'SIGNED_OUT') setRecovering(false);
      setSession(s);
      // Defer DB calls out of the auth callback (supabase-js recommendation).
      if (event === 'SIGNED_IN' || event === 'SIGNED_OUT' || event === 'USER_UPDATED'
          || event === 'MFA_CHALLENGE_VERIFIED' || event === 'PASSWORD_RECOVERY'
          || (event === 'TOKEN_REFRESHED' && provisional.current)) {
        provisional.current = false;
        setTimeout(() => { void load(s); }, 0);
      }
      // Signed in again on this device: keep its notifications attached to the new session.
      if (event === 'SIGNED_IN' || event === 'MFA_CHALLENGE_VERIFIED') setTimeout(() => { void resyncPush(); }, 0);
    });
    return () => { alive = false; sub.subscription.unsubscribe(); };
  }, [load]);

  useEffect(() => { applyAppearance(settings?.appearance); }, [settings?.appearance]);

  // Settings changed in another tab (same browser): adopt them at once. Other devices:
  // re-read when this window regains focus (at most once a minute).
  useEffect(() => {
    if (!session) return;
    const uid = session.user.id;
    const onStorage = (e: StorageEvent) => {
      if (e.key !== CACHE_KEY) return;
      const c = readCache(uid);
      if (c) setSettings(c.settings);
    };
    const onFocus = () => {
      if (document.visibilityState !== 'visible' || Date.now() - lastSettingsReload < 60_000) return;
      lastSettingsReload = Date.now();
      void load(session);
    };
    window.addEventListener('storage', onStorage);
    document.addEventListener('visibilitychange', onFocus);
    return () => { window.removeEventListener('storage', onStorage); document.removeEventListener('visibilitychange', onFocus); };
  }, [session, load]);

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
    const current = settingsRef.current;
    if (!current) return;
    const keys = Object.keys(patch) as Array<keyof typeof patch>;
    const before = Object.fromEntries(keys.map((k) => [k, current[k]])) as Partial<UserSettings>;
    setSettings((s) => (s ? { ...s, ...patch } : s));          // optimistic
    const { error } = await supabase.from('user_settings')
      .update({ ...patch, updated_at: new Date().toISOString() }).eq('user_id', current.user_id);
    if (error) {
      // Roll back only the keys this call changed, so concurrent toggles are not undone.
      setSettings((s) => (s ? { ...s, ...before } : s));
      throw error;
    }
    setSettings((s) => {
      if (s && profile) writeCache(s.user_id, { profile, settings: s });
      return s;
    });
  }, [profile]);

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
