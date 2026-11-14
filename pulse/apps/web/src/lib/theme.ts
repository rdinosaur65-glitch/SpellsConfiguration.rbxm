import type { Appearance } from './types';

export const ACCENTS = ['#8B5CF6', '#EC4899', '#F97316', '#22C55E', '#06B6D4', '#3B82F6', '#EAB308'] as const;

const FONTS: Record<Appearance['font'], string> = {
  system: 'system-ui, -apple-system, "Segoe UI", Roboto, sans-serif',
  rounded: 'ui-rounded, "SF Pro Rounded", "Nunito", system-ui, sans-serif',
  serif: 'ui-serif, Georgia, "Times New Roman", serif',
  mono: 'ui-monospace, "SF Mono", Menlo, Consolas, monospace',
};

// WCAG contrast helpers: accents are darkened just enough for white text on top of them
// (buttons, own bubbles) and for accent-coloured text on the page background.
function channel(c: number): number { const s = c / 255; return s <= 0.03928 ? s / 12.92 : ((s + 0.055) / 1.055) ** 2.4; }
function luminance([r, g, b]: number[]): number { return 0.2126 * channel(r!) + 0.7152 * channel(g!) + 0.0722 * channel(b!); }
function contrast(a: number[], b: number[]): number {
  const [x, y] = [luminance(a), luminance(b)].sort((p, q) => q - p) as [number, number];
  return (x + 0.05) / (y + 0.05);
}
const rgb = (hex: string) => [1, 3, 5].map((i) => parseInt(hex.slice(i, i + 2), 16));
const toHex = (c: number[]) => '#' + c.map((v) => Math.round(v).toString(16).padStart(2, '0')).join('');
/** Darken (or, on dark backgrounds, lighten) `hex` until it reaches `ratio` against `against`. */
export function readable(hex: string, against: string, ratio = 4.5): string {
  let c = rgb(hex); const bg = rgb(against);
  const lighten = luminance(bg) < 0.2;
  for (let i = 0; i < 40 && contrast(c, bg) < ratio; i++) {
    c = c.map((v) => (lighten ? v + (255 - v) * 0.08 : v * 0.92));
  }
  return toHex(c);
}

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
  root.style.setProperty('--accent-solid', readable(accent, '#ffffff'));          // white text on it
  // Accent text sits on the page and on surfaces (cards, tab bar); meet 4.5:1 on the harder one.
  root.style.setProperty('--accent-text', readable(accent, light ? '#ffffff' : '#1e1e29'));
  root.style.setProperty('--font', FONTS[a?.font ?? 'system'] ?? FONTS.system);
  root.dataset.bubbles = a?.bubbles ?? 'rounded';
  root.dataset.reduceMotion = String(a?.reduce_motion ?? false);
  document.querySelector('meta[name="theme-color"]')?.setAttribute('content', light ? '#f7f7fb' : '#0b0b10');
}

media?.addEventListener('change', () => { if (current?.mode === 'system') applyAppearance(current); });
