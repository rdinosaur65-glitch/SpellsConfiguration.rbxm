import { useSyncExternalStore } from 'react';

/**
 * Set while a screen re-authenticates in place (password, then the 2FA code) — for
 * example before deleting the account. While set, the app does not swap the screen for
 * the global two-step prompt, which would unmount the dialog mid-flow.
 */
let active = false;
const listeners = new Set<() => void>();

export function setStepUp(v: boolean) {
  active = v;
  listeners.forEach((l) => l());
}

export function useStepUpActive(): boolean {
  return useSyncExternalStore((l) => { listeners.add(l); return () => listeners.delete(l); }, () => active);
}
