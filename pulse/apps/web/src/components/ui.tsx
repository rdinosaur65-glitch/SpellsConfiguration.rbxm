import { useEffect, useRef, useState, type ButtonHTMLAttributes, type CSSProperties, type InputHTMLAttributes, type ReactNode } from 'react';
import { createPortal } from 'react-dom';

export function Button({ variant = 'primary', busy, disabled, children, ...rest }:
  ButtonHTMLAttributes<HTMLButtonElement> & { variant?: 'primary' | 'ghost' | 'danger' | 'subtle'; busy?: boolean }) {
  return (
    <button className={`btn btn-${variant}`} {...rest} disabled={Boolean(busy || disabled)} aria-busy={busy || undefined}>
      {busy ? <Spinner small /> : children}
    </button>
  );
}

export function Field({ label, hint, error, ...rest }:
  InputHTMLAttributes<HTMLInputElement> & { label: string; hint?: ReactNode; error?: string | null }) {
  const id = rest.id ?? `f-${rest.name ?? label.replace(/\W+/g, '-').toLowerCase()}`;
  return (
    <label className="field" htmlFor={id}>
      <span className="field-label">{label}</span>
      <input id={id} aria-invalid={error ? true : undefined} aria-describedby={hint || error ? `${id}-d` : undefined} {...rest} />
      {(error || hint) && <span id={`${id}-d`} className={error ? 'field-error' : 'field-hint'}>{error ?? hint}</span>}
    </label>
  );
}

export function Toggle({ label, description, checked, onChange, disabled }:
  { label: string; description?: string; checked: boolean; onChange: (v: boolean) => void; disabled?: boolean }) {
  return (
    <label className="toggle-row">
      <span>
        <span className="toggle-label">{label}</span>
        {description && <span className="toggle-desc">{description}</span>}
      </span>
      <input type="checkbox" role="switch" checked={checked} disabled={disabled}
             onChange={(e) => onChange(e.target.checked)} />
    </label>
  );
}

export function Spinner({ small }: { small?: boolean }) {
  return <span className={`spinner${small ? ' spinner-sm' : ''}`} role="status" aria-label="Loading" />;
}

export function Avatar({ name, color, size = 44, online }: { name: string; color?: string | null; size?: number; online?: boolean | null }) {
  const initials = name.trim().split(/\s+/).map((w) => w[0]).slice(0, 2).join('').toUpperCase() || '?';
  let h = 0; for (const ch of name) h = (h * 31 + ch.charCodeAt(0)) % 360;
  return (
    <span className="avatar" style={{ width: size, height: size, fontSize: size * 0.38,
      background: color ?? `hsl(${h} 40% 30%)` }} aria-hidden="true">
      {initials}
      {online && <span className="avatar-online" />}
    </span>
  );
}

export function Empty({ title, children }: { title: string; children?: ReactNode }) {
  return (
    <div className="empty">
      <h3>{title}</h3>
      {children && <p>{children}</p>}
    </div>
  );
}

export function Banner({ kind = 'error', testId, children }: { kind?: 'error' | 'info' | 'success'; testId?: string; children: ReactNode }) {
  return <div className={`banner banner-${kind}`} role={kind === 'error' ? 'alert' : 'status'} data-testid={testId}>{children}</div>;
}

export function Header({ title, left, right }: { title: ReactNode; left?: ReactNode; right?: ReactNode }) {
  return (
    <header className="topbar">
      <div className="topbar-side">{left}</div>
      <h1 className="topbar-title">{title}</h1>
      <div className="topbar-side topbar-right">{right}</div>
    </header>
  );
}

/** Small transient notice. */
export function useToast(): [ReactNode, (msg: string) => void] {
  const [msg, setMsg] = useState<string | null>(null);
  useEffect(() => {
    if (!msg) return;
    const t = setTimeout(() => setMsg(null), 3200);
    return () => clearTimeout(t);
  }, [msg]);
  return [msg ? <div className="toast" role="status">{msg}</div> : null, setMsg];
}

type IconName = 'camera' | 'chat' | 'friends' | 'settings' | 'back' | 'send' | 'search' | 'plus' | 'image' |
  'check' | 'close' | 'flip' | 'more' | 'lock' | 'mic';
const PATHS: Record<IconName, string> = {
  camera: 'M4 8h3l2-3h6l2 3h3v11H4z M12 17a4 4 0 1 0 0-8 4 4 0 0 0 0 8z',
  chat: 'M4 5h16v11H9l-5 4z',
  friends: 'M9 11a3.5 3.5 0 1 0 0-7 3.5 3.5 0 0 0 0 7z M2.5 20c.8-3.6 3.4-5.5 6.5-5.5s5.7 1.9 6.5 5.5 M16 4.5a3 3 0 0 1 0 6 M18 14.5c2 .7 3.2 2.5 3.5 5.5',
  settings: 'M12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6z M19 12l2-1.5-2-3.5-2.4.7-1.6-1L14.5 4h-5L9 6.7l-1.6 1L5 7 3 10.5 5 12l-2 1.5L5 17l2.4-.7 1.6 1 .5 2.7h5l.5-2.7 1.6-1 2.4.7 2-3.5z',
  back: 'M15 5l-7 7 7 7',
  send: 'M4 12l16-8-6 16-3-7z',
  search: 'M11 18a7 7 0 1 0 0-14 7 7 0 0 0 0 14z M20 20l-4-4',
  plus: 'M12 5v14 M5 12h14',
  check: 'M5 12l5 5 9-10',
  close: 'M6 6l12 12 M18 6L6 18',
  mic: 'M12 3a3 3 0 0 0-3 3v6a3 3 0 0 0 6 0V6a3 3 0 0 0-3-3z M5 11a7 7 0 0 0 14 0 M12 18v3',
  flip: 'M4 9a8 8 0 0 1 14-3l2 2 M20 4v4h-4 M20 15a8 8 0 0 1-14 3l-2-2 M4 20v-4h4',
  more: 'M5 12h.01 M12 12h.01 M19 12h.01',
  lock: 'M6 11h12v9H6z M8 11V8a4 4 0 0 1 8 0v3',
  image: 'M4 5h16v14H4z M8.5 10a1.5 1.5 0 1 0 0-3 1.5 1.5 0 0 0 0 3z M20 15l-5-5-9 9',
};
export function Icon({ name, size = 22, label }: { name: IconName; size?: number; label?: string }) {
  return (
    <svg width={size} height={size} viewBox="0 0 24 24" fill="none" stroke="currentColor" strokeWidth={name === 'more' ? 3 : 1.8}
         strokeLinecap="round" strokeLinejoin="round" role={label ? 'img' : undefined}
         aria-label={label} aria-hidden={label ? undefined : true}>
      <path d={PATHS[name]} />
    </svg>
  );
}

/**
 * Bottom sheet that behaves as a modal dialog: focus moves into it and back to the
 * opener on close, Tab stays inside, Escape and the backdrop close it.
 */
export function Sheet({ label, onClose, children, style }:
  { label: string; onClose: () => void; children: ReactNode; style?: CSSProperties }) {
  const ref = useRef<HTMLDivElement>(null);
  const closeRef = useRef(onClose);
  closeRef.current = onClose;
  useEffect(() => {
    const opener = document.activeElement as HTMLElement | null;
    const el = ref.current;
    const focusables = () => Array.from(el?.querySelectorAll<HTMLElement>(
      'button:not([disabled]), [href], input:not([disabled]), select, textarea, [tabindex]:not([tabindex="-1"])') ?? []);
    (el?.querySelector<HTMLElement>('[autofocus]') ?? focusables()[0] ?? el)?.focus();
    const onKey = (e: KeyboardEvent) => {
      if (e.key === 'Escape') { e.preventDefault(); closeRef.current(); return; }
      if (e.key !== 'Tab') return;
      const list = focusables();
      if (list.length === 0) return;
      const first = list[0]!, last = list[list.length - 1]!;
      if (e.shiftKey && document.activeElement === first) { e.preventDefault(); last.focus(); }
      else if (!e.shiftKey && document.activeElement === last) { e.preventDefault(); first.focus(); }
    };
    document.addEventListener('keydown', onKey);
    return () => { document.removeEventListener('keydown', onKey); opener?.focus?.(); };
  }, []);
  // Rendered at the top of the page so no screen's own layer (e.g. the camera) can put
  // the tab bar above it.
  return createPortal(
    <div className="sheet-backdrop" onClick={onClose}>
      <div ref={ref} className="sheet" role="dialog" aria-modal="true" aria-label={label} tabIndex={-1}
           style={style} onClick={(e) => e.stopPropagation()}>
        {children}
      </div>
    </div>,
    document.body,
  );
}
