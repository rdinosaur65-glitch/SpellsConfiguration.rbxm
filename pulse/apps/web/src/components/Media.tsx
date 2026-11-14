import { useCallback, useEffect, useRef, useState } from 'react';
import { rpc } from '../lib/supabase';
import { errorMessage } from '../lib/errors';
import { chatMediaObjectUrl, snapObjectUrl } from '../lib/media';
import { Spinner } from './ui';

/** A photo in a chat. With Data saver on, it loads only when tapped. */
export function ChatImage({ assetId, dataSaver, alt }: { assetId: string; dataSaver: boolean; alt: string }) {
  const [want, setWant] = useState(!dataSaver);
  const [src, setSrc] = useState<string | null>(null);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => {
    if (!want) return;
    let alive = true;
    setError(null);
    chatMediaObjectUrl(assetId).then((u) => { if (alive) setSrc(u); })
      .catch((e) => { if (alive) setError(errorMessage(e)); });
    return () => { alive = false; };
  }, [assetId, want]);
  if (!want) return <button className="media-placeholder" onClick={() => setWant(true)}>📷 Tap to load photo</button>;
  if (error) return <button className="media-placeholder" onClick={() => { setWant(false); setTimeout(() => setWant(true)); }}>{error} · Retry</button>;
  if (!src) return <span className="media-placeholder"><Spinner small /></span>;
  return <img className="chat-photo" src={src} alt={alt} data-testid="chat-photo" />;
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
 * session (first view or the single replay), the media URL lives only as long as that
 * session, and close_snap_view() ends it. The countdown here is cosmetic.
 */
export function SnapViewer({ snapId, onClose }: { snapId: string; onClose: (status: string | null) => void }) {
  const [view, setView] = useState<OpenedSnap | null>(null);
  const [src, setSrc] = useState<string | null>(null);
  const [left, setLeft] = useState<number | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [saved, setSaved] = useState(false);
  const closing = useRef(false);
  const sessionRef = useRef<string | null>(null);
  const srcRef = useRef<string | null>(null);

  const close = useCallback(async () => {
    if (closing.current) return;
    closing.current = true;
    let status: string | null = null;
    if (sessionRef.current) {
      try { status = await rpc<string>('close_snap_view', { p_snap: snapId, p_session: sessionRef.current }); } catch { /* server expires it anyway */ }
    }
    if (srcRef.current) URL.revokeObjectURL(srcRef.current);
    onClose(status);
  }, [snapId, onClose]);

  useEffect(() => {
    let alive = true;
    (async () => {
      try {
        const v = await openOnce(snapId);
        if (!v || !alive) return;
        sessionRef.current = v.session_id;
        setView(v);
        const url = await snapObjectUrl(snapId, v.session_id);
        if (!alive) { URL.revokeObjectURL(url); return; }
        srcRef.current = url; setSrc(url);
        if (!v.unlimited && v.view_seconds) setLeft(v.view_seconds);
      } catch (e) { if (alive) setError(errorMessage(e)); }
    })();
    return () => { alive = false; };
  }, [snapId]);

  // Countdown starts once the image is on screen; also respect the server deadline.
  useEffect(() => {
    if (left === null || !src) return;
    if (left <= 0) { void close(); return; }
    const t = setTimeout(() => setLeft((s) => (s ?? 1) - 1), 1000);
    return () => clearTimeout(t);
  }, [left, src, close]);
  useEffect(() => {
    if (!view) return;
    const ms = new Date(view.deadline).getTime() - Date.now();
    const t = setTimeout(() => void close(), Math.max(0, ms));
    return () => clearTimeout(t);
  }, [view, close]);
  useEffect(() => {
    const onKey = (e: KeyboardEvent) => { if (e.key === 'Escape') void close(); };
    const onHide = () => { if (document.visibilityState === 'hidden') void close(); };
    document.addEventListener('keydown', onKey);
    document.addEventListener('visibilitychange', onHide);
    return () => { document.removeEventListener('keydown', onKey); document.removeEventListener('visibilitychange', onHide); };
  }, [close]);

  async function save() {
    if (!view || !src) return;
    try {
      await rpc('save_snap', { p_snap: snapId, p_session: view.session_id });
      const a = document.createElement('a');
      a.href = src; a.download = `pulse-snap-${snapId.slice(0, 8)}.jpg`; a.click();
      setSaved(true);
    } catch (e) { setError(errorMessage(e)); }
  }

  return (
    <div className="snap-viewer" role="dialog" aria-modal="true" aria-label="Snap" data-testid="snap-viewer" onClick={() => void close()}>
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
        <button className="btn btn-sm btn-ghost" onClick={() => void close()}>Close</button>
      </div>
    </div>
  );
}
