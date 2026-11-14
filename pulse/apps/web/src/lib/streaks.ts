import { useEffect, useState } from 'react';
import { rpc, supabase } from './supabase';

/**
 * Snap streaks as the server reports them (my_streaks). Nothing here computes a streak:
 * counts, days and expiry are decided by the database (migration 0032); this only keeps
 * one shared copy for the screens and refreshes it.
 */
export interface Streak {
  friend_id: string; count: number; completed_today: boolean; i_sent_today: boolean; they_sent_today: boolean;
  at_risk: boolean; expires_at: string; best: number; milestone: number; milestone_unseen: boolean; day_ends_at: string;
}

let cache = new Map<string, Streak>();
let owner: string | null = null;
let loadedAt = 0;
let inflight: Promise<void> | null = null;
const listeners = new Set<(m: Map<string, Streak>) => void>();

export async function refreshStreaks(): Promise<void> {
  if (inflight) return inflight;
  inflight = (async () => {
    try {
      const { data } = await supabase.auth.getSession();
      const uid = data.session?.user.id ?? null;
      if (uid !== owner) { owner = uid; cache = new Map(); }     // another account on this device
      if (!uid) return;
      const rows = await rpc<Streak[]>('my_streaks');
      if (owner !== uid) return;
      cache = new Map(rows.map((r) => [r.friend_id, r]));
      loadedAt = Date.now();
      listeners.forEach((l) => l(cache));
    } catch { /* keep the last known state; the next refresh tries again */ }
    finally { inflight = null; }
  })();
  return inflight;
}

/** All of my streaks, by friend id. Refreshes on use, when the app returns, and every minute. */
export function useStreaks(): Map<string, Streak> {
  const [map, setMap] = useState(cache);
  useEffect(() => {
    listeners.add(setMap);
    if (Date.now() - loadedAt > 15_000) void refreshStreaks(); else setMap(cache);
    const onVisible = () => { if (document.visibilityState === 'visible') void refreshStreaks(); };
    document.addEventListener('visibilitychange', onVisible);
    const t = setInterval(() => { if (document.visibilityState === 'visible') void refreshStreaks(); }, 60_000);
    return () => { listeners.delete(setMap); document.removeEventListener('visibilitychange', onVisible); clearInterval(t); };
  }, []);
  return map;
}

/** "I've seen this milestone" — the server records it so the celebration is shown once. */
export async function ackMilestone(friendId: string, milestone: number): Promise<void> {
  dismissedMilestones.add(`${friendId}:${milestone}`);
  try { await rpc('ack_streak_milestone', { p_friend: friendId }); void refreshStreaks(); } catch { /* shown again next time at worst */ }
}
/** Celebrations already shown in this session (until the server's answer arrives). */
export const dismissedMilestones = new Set<string>();
export const milestonePending = (s: Streak) => s.milestone_unseen && !dismissedMilestones.has(`${s.friend_id}:${s.milestone}`);

/** Local time of a server moment, e.g. "01:00" or "Sun 01:00". */
export function localTime(iso: string, now = new Date()): string {
  const d = new Date(iso);
  const t = d.toLocaleTimeString([], { hour: '2-digit', minute: '2-digit' });
  return d.toDateString() === now.toDateString() ? t : `${d.toLocaleDateString([], { weekday: 'short' })} ${t}`;
}
