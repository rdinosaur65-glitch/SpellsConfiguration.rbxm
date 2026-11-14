import { useEffect, useState } from 'react';

/**
 * "Add to Home Screen" support. Android/desktop Chromium fires beforeinstallprompt (kept
 * here so the Settings button can show the browser's own dialog later); iOS Safari has no
 * API, so the app shows the Share → Add to Home Screen steps instead.
 */
interface InstallPromptEvent extends Event { prompt: () => Promise<void>; userChoice: Promise<{ outcome: string }> }
let deferred: InstallPromptEvent | null = null;
const listeners = new Set<() => void>();
export function captureInstallPrompt(): void {
  window.addEventListener('beforeinstallprompt', (e) => {
    e.preventDefault();
    deferred = e as InstallPromptEvent;
    listeners.forEach((l) => l());
  });
  window.addEventListener('appinstalled', () => { deferred = null; listeners.forEach((l) => l()); });
}

export function isStandalone(): boolean {
  return window.matchMedia?.('(display-mode: standalone)').matches === true
    || (navigator as Navigator & { standalone?: boolean }).standalone === true;
}
export function isIos(): boolean {
  return /iphone|ipad|ipod/i.test(navigator.userAgent) || (navigator.platform === 'MacIntel' && navigator.maxTouchPoints > 1);
}

export function useInstall(): { canPrompt: boolean; prompt: () => Promise<boolean> } {
  const [, force] = useState(0);
  useEffect(() => { const l = () => force((n) => n + 1); listeners.add(l); return () => { listeners.delete(l); }; }, []);
  return {
    canPrompt: deferred !== null,
    prompt: async () => {
      const ev = deferred;
      if (!ev) return false;
      deferred = null;
      await ev.prompt();
      const choice = await ev.userChoice;
      listeners.forEach((l) => l());
      return choice.outcome === 'accepted';
    },
  };
}
