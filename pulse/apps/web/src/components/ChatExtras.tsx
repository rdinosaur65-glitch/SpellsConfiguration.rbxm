import { useCallback, useEffect, useMemo, useRef, useState } from 'react';
import { rpc, supabase } from '../lib/supabase';
import { errorMessage } from '../lib/errors';
import { clockTime, relativeTime } from '../lib/time';
import { Banner, Sheet, Spinner } from './ui';
import { ChatImage } from './Media';

/** Quick reactions (one per person per message; the server enforces it). */
export const QUICK_REACTIONS = ['❤️', '😂', '😮', '😢', '👍', '🔥'];

interface ReactionRow { message_id: string; user_id: string; emoji: string }

/**
 * Reactions in one chat, as RLS lets this person see them (never from or to someone they
 * blocked). New and changed reactions arrive live; removals show on the next reload, because
 * delete events are not published (they would bypass RLS).
 */
export function useReactions(convId: string) {
  const [rows, setRows] = useState<ReactionRow[]>([]);
  const pending = useRef(new Set<string>());     // messages with my toggle in flight
  const seq = useRef(0);
  const reload = useCallback(async () => {
    const n = ++seq.current;
    const { data } = await supabase.from('message_reactions').select('message_id,user_id,emoji')
      .eq('conversation_id', convId).order('created_at', { ascending: false }).limit(2000);
    if (n !== seq.current) return;               // a newer reload is on its way
    // Rows of a message I am toggling right now stay as I set them.
    setRows((cur) => [...((data ?? []) as ReactionRow[]).filter((r) => !pending.current.has(r.message_id)),
      ...cur.filter((r) => pending.current.has(r.message_id))]);
  }, [convId]);
  useEffect(() => { setRows([]); void reload(); }, [reload]);
  const apply = useCallback((r: Partial<ReactionRow>) => {
    if (!r.message_id || !r.user_id || !r.emoji || pending.current.has(r.message_id)) return;
    setRows((cur) => [...cur.filter((x) => !(x.message_id === r.message_id && x.user_id === r.user_id)), r as ReactionRow]);
  }, []);
  const byMessage = useMemo(() => {
    const m = new Map<string, ReactionRow[]>();
    for (const r of rows) m.set(r.message_id, [...(m.get(r.message_id) ?? []), r]);
    return m;
  }, [rows]);
  /** Toggle my reaction (same emoji again removes it), optimistically. */
  const toggle = useCallback(async (messageId: string, emoji: string, me: string) => {
    if (pending.current.has(messageId)) return;   // one change at a time per message (no add/undo race)
    pending.current.add(messageId);
    const mine = rows.find((r) => r.message_id === messageId && r.user_id === me);
    const set = (on: boolean) => setRows((cur) => {
      const rest = cur.filter((x) => !(x.message_id === messageId && x.user_id === me));
      return on ? [...rest, { message_id: messageId, user_id: me, emoji }] : rest;
    });
    set(mine?.emoji !== emoji);
    try { set(await rpc<boolean>('toggle_reaction', { p_msg: messageId, p_emoji: emoji })); }   // the server's answer is final
    catch (e) { pending.current.delete(messageId); await reload(); throw e; }
    pending.current.delete(messageId);
  }, [rows, reload]);
  return { byMessage, reload, apply, toggle };
}

export function ReactionChips({ list, me, nameOf, onToggle }:
  { list: ReactionRow[]; me: string; nameOf: (uid: string) => string; onToggle: (emoji: string) => void }) {
  const groups = new Map<string, ReactionRow[]>();
  for (const r of list) groups.set(r.emoji, [...(groups.get(r.emoji) ?? []), r]);
  return (
    <span className="reactions" data-testid="reactions">
      {[...groups.entries()].map(([emoji, rs]) => {
        const mineToo = rs.some((r) => r.user_id === me);
        const who = rs.map((r) => (r.user_id === me ? 'you' : nameOf(r.user_id))).join(', ');
        return (
          <button key={emoji} className="reaction-chip" aria-pressed={mineToo} onClick={() => onToggle(emoji)}
                  aria-label={`${emoji} from ${who}${mineToo ? ' — tap to remove yours' : ''}`}>
            {emoji}{rs.length > 1 ? ` ${rs.length}` : ''}
          </button>
        );
      })}
    </span>
  );
}

interface Hit { message_id: string; conversation_id: string; sender_id: string; kind: string; body: string | null; created_at: string; saved: boolean }

/** Search messages (this chat when convId is given, otherwise every chat). */
export function SearchSheet({ convId, title, nameOf, onPick, onClose }: {
  convId?: string; title: string; nameOf: (uid: string, conv: string) => string;
  onPick: (hit: Hit) => void; onClose: () => void;
}) {
  const [q, setQ] = useState('');
  const [savedOnly, setSavedOnly] = useState(false);
  const [hits, setHits] = useState<Hit[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const seq = useRef(0);
  useEffect(() => {
    const query = q.trim();
    if (query.length < 2 && !savedOnly) { setHits(null); setError(null); return; }
    const n = ++seq.current;
    const t = setTimeout(async () => {
      try {
        const r = await rpc<Hit[]>('search_messages', {
          p_query: query.length >= 2 ? query : null, p_saved_only: savedOnly, p_conv: convId ?? null, p_limit: 50 });
        if (n === seq.current) { setHits(r); setError(null); }
      } catch (e) { if (n === seq.current) setError(errorMessage(e)); }
    }, 300);
    return () => clearTimeout(t);
  }, [q, savedOnly, convId]);
  return (
    <Sheet label={title} onClose={onClose}>
      <h2 style={{ fontSize: 18, margin: '4px 4px 8px' }}>{title}</h2>
      <label className="field"><span className="field-label">Search messages</span>
        <input type="search" value={q} autoFocus placeholder="At least 2 letters" enterKeyHint="search"
               onChange={(e) => setQ(e.target.value)} /></label>
      <div className="chips" role="toolbar" aria-label="Search filters">
        <button className="chip" aria-pressed={savedOnly} onClick={() => setSavedOnly((v) => !v)}>Saved only</button>
      </div>
      {error && <Banner>{error}</Banner>}
      {hits === null ? <p className="muted small" style={{ margin: 4 }}>Disappeared messages can't be found, by design.</p>
        : hits.length === 0 ? <p className="muted small" style={{ margin: 4 }}>No messages found.</p>
        : (
          <div className="list" data-testid="search-results">
            {hits.map((h) => (
              <button key={h.message_id} className="list-item" style={{ border: 0, background: 'none', textAlign: 'left', width: '100%' }}
                      onClick={() => onPick(h)}>
                <span className="grow">
                  <span className="list-title truncate" style={{ display: 'block' }}>{h.kind === 'photo' ? '📷 Photo' : h.kind === 'voice' ? '🎤 Voice note' : h.body}</span>
                  <span className="list-sub">{nameOf(h.sender_id, h.conversation_id)} · {relativeTime(h.created_at)}{h.saved ? ' · saved' : ''}</span>
                </span>
              </button>
            ))}
          </div>
        )}
    </Sheet>
  );
}

interface Item { message_id: string; kind: string; media_asset_id: string | null; body: string | null; created_at: string; saved: boolean }
const FILTERS: Array<[string, string]> = [['photos', 'Photos'], ['links', 'Links'], ['saved', 'Saved']];

/** Photos, links and saved messages of one chat. Photos load as they scroll into view (each
 *  view counts against the daily download budget; Data saver loads them only on tap). */
export function GallerySheet({ convId, dataSaver, onPick, onClose }: {
  convId: string; dataSaver: boolean; onPick: (messageId: string) => void; onClose: () => void;
}) {
  const [filter, setFilter] = useState('photos');
  const [items, setItems] = useState<Item[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [shown, setShown] = useState(12);
  useEffect(() => {
    let alive = true;
    setItems(null); setShown(12);
    rpc<Item[]>('conversation_gallery', { p_conv: convId, p_filter: filter })
      .then((r) => { if (alive) { setItems(r); setError(null); } })
      .catch((e) => { if (alive) { setError(errorMessage(e)); setItems([]); } });
    return () => { alive = false; };
  }, [convId, filter]);
  const links = (body: string | null) => (body ?? '').match(/https?:\/\/[^\s<>"']+/g) ?? [];
  return (
    <Sheet label="Photos, links and saved" onClose={onClose}>
      <h2 style={{ fontSize: 18, margin: '4px 4px 8px' }}>Photos, links and saved</h2>
      <div className="chips" role="toolbar" aria-label="Show">
        {FILTERS.map(([f, label]) => <button key={f} className="chip" aria-pressed={filter === f} onClick={() => setFilter(f)}>{label}</button>)}
      </div>
      {error && <Banner>{error}</Banner>}
      {items === null ? <Spinner small /> : items.length === 0 ? <p className="muted small" style={{ margin: 4 }}>Nothing here yet.</p>
        : filter === 'photos' ? (
          <>
            <div className="gallery-grid" data-testid="gallery">
              {items.slice(0, shown).map((it) => it.media_asset_id && (
                <button key={it.message_id} className="gallery-cell" onClick={() => onPick(it.message_id)} aria-label={`Photo from ${relativeTime(it.created_at)}`}>
                  <ChatImage assetId={it.media_asset_id} dataSaver={dataSaver} alt="" />
                </button>
              ))}
            </div>
            {items.length > shown && <button className="btn btn-ghost" onClick={() => setShown((n) => n + 12)}>Show more</button>}
          </>
        ) : (
          <div className="list" data-testid="gallery">
            {items.map((it) => (
              <div key={it.message_id} className="list-item">
                <span className="grow" style={{ minWidth: 0 }}>
                  {filter === 'links'
                    ? links(it.body).map((u) => <a key={u} href={u} target="_blank" rel="noopener noreferrer nofollow" className="truncate" style={{ display: 'block' }}>{u}</a>)
                    : <button className="link-btn" style={{ color: 'inherit', fontWeight: 400 }} onClick={() => onPick(it.message_id)}>
                        {it.kind === 'photo' ? '📷 Photo' : (it.body ?? '').slice(0, 120)}</button>}
                  <span className="list-sub">{clockTime(it.created_at)} · {relativeTime(it.created_at)}</span>
                </span>
              </div>
            ))}
          </div>
        )}
    </Sheet>
  );
}
