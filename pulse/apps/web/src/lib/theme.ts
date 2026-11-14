import type { Appearance } from './types';

export const ACCENTS = ['#8B5CF6', '#EC4899', '#F97316', '#22C55E', '#06B6D4', '#3B82F6', '#EAB308'] as const;

const FONTS: Record<Appearance['font'], string> = {
  system: 'system-ui, -apple-system, "Segoe UI", Roboto, sans-serif',
  rounded: 'ui-rounded, "SF Pro Rounded", "Nunito", system-ui, sans-serif',
  serif: 'ui-serif, Georgia, "Times New Roman", serif',
  mono: 'ui-monospace, "SF Mono", Menlo, Consolas, monospace',
};

const media = typeof window !== 'undefined' ? window.matchMedia('(prefers-color-scheme: light)') : null;
let current: Appearance | undefined;

/** Applies synced appearance settings to CSS custom properties on <html>. */
export function applyAppearance(a: Appearance | undefined): void {
  current = a;
  const root = document.documentElement;
  const mode = a?.mode ?? 'dark';
  const light = mode === 'light' || (mode === 'system' && media?.matches === true);
  root.dataset.theme = light ? 'light' : 'dark';
  const accent = a?.accent && /^#[0-9a-f]{6}$/i.test(a.accent) ? a.accent : '#8B5CF6';
  root.style.setProperty('--accent', accent);
  root.style.setProperty('--font', FONTS[a?.font ?? 'system'] ?? FONTS.system);
  root.dataset.bubbles = a?.bubbles ?? 'rounded';
  root.dataset.reduceMotion = String(a?.reduce_motion ?? false);
  document.querySelector('meta[name="theme-color"]')?.setAttribute('content', light ? '#f7f7fb' : '#0b0b10');
}

media?.addEventListener('change', () => { if (current?.mode === 'system') applyAppearance(current); });
