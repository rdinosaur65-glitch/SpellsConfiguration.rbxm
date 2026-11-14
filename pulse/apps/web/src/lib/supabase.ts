import { createClient, type SupabaseClient } from '@supabase/supabase-js';

const url = import.meta.env.VITE_SUPABASE_URL as string | undefined;
const anonKey = import.meta.env.VITE_SUPABASE_ANON_KEY as string | undefined;

/** True when the public Supabase settings are present (see docs/ENVIRONMENT.md). */
export const isConfigured = Boolean(url && anonKey);

// Only the public anon/publishable key ever reaches the browser; RLS protects data.
export const supabase: SupabaseClient = createClient(url ?? 'http://invalid.localhost', anonKey ?? 'missing', {
  auth: { persistSession: true, autoRefreshToken: true, detectSessionInUrl: true, flowType: 'pkce' },
  realtime: { params: { eventsPerSecond: 5 } },
});

/** Call a Postgres RPC and throw a readable error (PULSE error codes are mapped in errors.ts). */
export async function rpc<T = unknown>(fn: string, args?: Record<string, unknown>): Promise<T> {
  const { data, error } = await supabase.rpc(fn, args);
  if (error) {
    // 2FA was turned on (possibly from another device): ask the app to re-check.
    if (error.message === 'mfa_required') window.dispatchEvent(new Event('pulse:mfa-required'));
    throw error;
  }
  return data as T;
}
