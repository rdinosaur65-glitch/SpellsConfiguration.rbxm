import { useCallback, useEffect, useRef, useState } from 'react';
import { createPortal } from 'react-dom';
import { rpc } from '../lib/supabase';
import { errorMessage } from '../lib/errors';
import { chatMediaObjectUrl, snapObjectUrl } from '../lib/media';
import { Spinner } from './ui';

/**
 * A photo in a chat. It is downloaded only when it scrolls near the screen (each download
 * is one Edge Function call and counts against the daily media allowance), and with
 * Data saver on only when tapped.
 */
export function ChatImage({ assetId, dataSaver, alt }: { assetId: string; dataSaver: boolean; alt: string }) {
  const [want, setWant] = useState(false);
  const [src, setSrc] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [attempt, setAttempt] = useState(0);
  const holder = useRef<HTMLSpanElement>(null);

  useEffect(() => {
    if (dataSaver || want) return;
    const el = holder.current;
    if (!el || typeof IntersectionObserver === 'undefined') { setWant(true); return; }
    const io = new IntersectionObserver((entries) => {
      if (entries.some((e) => e.isIntersecting)) { setWant(true); io.disconnect(); }
    }, { rootMargin: '300px 0px' });
    io.observe(el);
    return () => io.disconnect();
  }, [dataSaver, want]);

  useEffect(() => {
    if (!want) return;
    let alive = true;
    setError(null);
    chatMediaObjectUrl(assetId).then((u) => { if (alive) setSrc(u); })
      .catch((e) => { if (alive) setError(errorMessage(e)); });
    return () => { alive = false; };
  }, [assetId, want, attempt]);

  if (src) return <img className="chat-photo" src={src} alt={alt} data-testid="chat-photo" />;
  if (error) return <button className="media-placeholder" onClick={() => setAttempt((n) => n + 1)}>{error} · Retry</button>;
  if (!want && dataSaver) return <button className="media-placeholder" onClick={() => setWant(true)}>📷 Tap to load photo</button>;
  return <span ref={holder} className="media-placeholder" aria-label="Loading photo">{want ? <Spinner small /> : '📷'}</span>;
}

interface OpenedSnap { session_id: string; view_number: number; deadline: string; view_seconds: number | null; unlimited: boolean; allow_saving: boolean }

// One open_snap() per viewer mount, even when React runs effects twice in development
// (a second call would burn the replay).
const opening = new Map<string, Promise<OpenedSnap | undefined>>();
function openOnce(snapId: string): Promise<OpenedSnap | undefined> {
  let p = opening.get(snapId);
  if (!p) {
    p = rpc<OpenedSnap[]>('open_snap', { p_snap: snapId }).then((r) => r[0]);
    opening.set(snapId, p);
    void p.finally(() => setTimeout(() => opening.delete(snapId), 0)).catch(() => {});
  }
  return p;
}

/**
 * Full-screen Snap viewer. The server decides everything: open_snap() starts a viewing
 * session (first view or the single replay), media-url streams the bytes only while that
 * session is live, and close_snap_view() ends it. The countdown here is cosmetic and runs
 * on the device's own monotonic clock (never compared with server timestamps).
 * The session is always closed: on the timer, on Close/tap, on Escape, when the app is
 * hidden, when the viewer is unmounted (e.g. the back gesture), and when it is dismissed
 * before open_snap() even answered.
 */
const UNLIMITED_LOCAL_CAP_S = 15 * 60;   // mirrors unlimited_view_max on the server

export function SnapViewer({ snapId, onClose }: { snapId: string; onClose: (status: string | null) => void }) {
  const [view, setView] = useState<OpenedSnap | null>(null);
  const [src, setSrc] = useState<string | null>(null);
  const [left, setLeft] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  const onCloseRef = useRef(onClose);
  onCloseRef.current = onClose;
  const st = useRef({ closed: false, mounted: false, session: null as string | null, src: null as string | null });

  const finish = useCallback(async (notify: boolean) => {
    const s = st.current;
    if (s.closed) return;
    s.closed = true;
    if (s.src) { URL.revokeObjectURL(s.src); s.src = null; }
    // Hide at once; end the server session in the background, then refresh the chat state.
    const closing = s.session
      ? rpc<string>('close_snap_view', { p_snap: snapId, p_session: s.session }).catch(() => null)   // server expires it anyway
      : Promise.resolve(null);
    if (notify) onCloseRef.current(null);
    const status = await closing;
    if (notify && status) onCloseRef.current(status);
  }, [snapId]);

  // Close the session if the viewer goes away without an explicit close. (Deferred one
  // tick so React's development double-mount does not count as leaving.)
  useEffect(() => {
    st.current.mounted = true;
    return () => {
      st.current.mounted = false;
      setTimeout(() => { if (!st.current.mounted) void finish(false); }, 0);
    };
  }, [finish]);

  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        const v = await openOnce(snapId);
        if (!v) return;
        st.current.session = v.session_id;
        if (st.current.closed) {          // dismissed while open_snap was in flight
          void rpc('close_snap_view', { p_snap: snapId, p_session: v.session_id }).catch(() => {});
          return;
        }
        if (!alive) return;
        setView(v);
        const url = await snapObjectUrl(snapId, v.session_id);
        if (!alive || st.current.closed) { URL.revokeObjectURL(url); return; }
        st.current.src = url; setSrc(url);
      } catch (e) { if (alive) setError(errorMessage(e)); }
    })();
    return () => { alive = false; };
  }, [snapId]);

  // Countdown from the moment the image is on screen, on a fixed local end time.
  useEffect(() => {
    if (!view || !src) return;
    const seconds = view.unlimited || !view.view_seconds ? UNLIMITED_LOCAL_CAP_S : view.view_seconds;
    const end = performance.now() + seconds * 1000;
    const tick = () => {
      const remaining = Math.ceil((end - performance.now()) / 1000);
      if (remaining <= 0) { void finish(true); return; }
      if (!view.unlimited) setLeft(remaining);
    };
    tick();
    const t = setInterval(tick, 200);
    return () => clearInterval(t);
  }, [view, src, finish]);

  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') void finish(true); };
    const onHide = () => { if (document.visibilityState === 'hidden') void finish(true); };
    document.addEventListener('keydown', onKey);
    document.addEventListener('visibilitychange', onHide);
    return () => { document.removeEventListener('keydown', onKey); document.removeEventListener('visibilitychange', onHide); };
  }, [finish]);

  async function save() {
    if (!view || !src) return;
    try {
      await rpc('save_snap', { p_snap: snapId, p_session: view.session_id });
      const a = document.createElement('a');
      a.href = src; a.download = `pulse-snap-${snapId.slice(0, 8)}.jpg`; a.click();
      setSaved(true);
    } catch (e) { setError(errorMessage(e)); }
  }

  // Taps close it once something is on screen (a stray tap while loading does not).
  const tapClose = () => { if (src || error) void finish(true); };
  return createPortal(
    <div className="snap-viewer" role="dialog" aria-modal="true" aria-label="Snap" data-testid="snap-viewer" onClick={tapClose}>
      {error ? <p className="snap-msg">{error}</p> : !src ? <Spinner /> : (
        <img src={src} alt="Snap" className="snap-image" data-testid="snap-image" draggable={false}
             onContextMenu={(e) => e.preventDefault()} />
      )}
      <div className="snap-hud" onClick={(e) => e.stopPropagation()}>
        <span className="pill" data-testid="snap-timer">
          {view ? (view.unlimited ? 'Tap anywhere to close' : left !== null ? `${left}s` : '') : ''}
          {view?.view_number === 2 ? ' · replay' : ''}
        </span>
        {view?.allow_saving && src && <button className="btn btn-sm btn-subtle" onClick={() => void save()} disabled={saved}>{saved ? 'Saved' : 'Save'}</button>}
        <button className="btn btn-sm btn-ghost" onClick={() => void finish(true)}>Close</button>
      </div>
    </div>,
    document.body,
  );
}
