import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type KeyboardEvent } from 'react';
import { Link, useParams } from 'react-router-dom';
import type { RealtimeChannel } from '@supabase/supabase-js';
import { canEditMessage, LIMITS } from '@pulse/domain';
import { rpc, supabase } from '../lib/supabase';
import { errorMessage } from '../lib/errors';
import { clockTime } from '../lib/time';
import type { Message, Participant } from '../lib/types';
import { Banner, Header, Icon, Sheet, Spinner, useToast } from '../components/ui';
import { ChatImage, SnapViewer } from '../components/Media';
import { compressImage } from '../lib/media';
import { deliver as deliverQueued, enqueue, onOutbox, pendingFor, retry as retryQueued } from '../lib/outbox';
import { useAuth } from '../lib/auth';

type Expiry = 'after_view' | 'after_view_24h' | 'after_view_7d' | 'never';
const EXPIRY_TEXT: Record<Expiry, string> = {
  after_view: 'Messages disappear after everyone has seen them',
  after_view_24h: 'Messages disappear 24 hours after viewing',
  after_view_7d: 'Messages disappear 7 days after viewing',
  never: 'Messages are kept',
};

/** A message in the UI: server rows plus local optimistic sends. */
interface UiMessage extends Message { local?: 'sending' | 'failed'; preview?: string }
interface SnapState { snap_id: string; recipient_id: string; status: 'delivered' | 'opened' | 'replayed' | 'expired'; views_used: number }

const COLS = 'id,conversation_id,sender_id,kind,body,media_asset_id,snap_id,reply_to_id,client_msg_id,created_at,edited_at,deleted_at,expires_at';
const PAGE = 200;

const isExpired = (m: Message) => Boolean(m.expires_at && new Date(m.expires_at).getTime() <= Date.now());

export function Chat() {
  const { id: convId = '' } = useParams();
  const { profile, settings } = useAuth();
  const me = profile?.id ?? '';
  const [conv, setConv] = useState<{ kind: 'direct' | 'group'; name: string | null; expiry_mode: Expiry } | null>(null);
  const [people, setPeople] = useState<Participant[]>([]);
  const [messages, setMessages] = useState<UiMessage[] | null>(null);
  const [hasOlder, setHasOlder] = useState(false);
  const [error, setError] = useState<string | null>(null);
  const [text, setText] = useState('');
  const [replyTo, setReplyTo] = useState<UiMessage | null>(null);
  const [editing, setEditing] = useState<UiMessage | null>(null);
  const [menuFor, setMenuFor] = useState<UiMessage | null>(null);
  const [showExpiry, setShowExpiry] = useState(false);
  const [typing, setTyping] = useState<Record<string, number>>({});
  const [snapStates, setSnapStates] = useState<SnapState[]>([]);
  const [viewing, setViewing] = useState<string | null>(null);
  const fileRef = useRef<HTMLInputElement>(null);
  const [toast, showToast] = useToast();
  const listRef = useRef<HTMLDivElement>(null);
  const stick = useRef(true);
  const bcast = useRef<RealtimeChannel | null>(null);
  const lastTypingSent = useRef(0);
  const messagesRef = useRef<UiMessage[] | null>(null);
  /** When each row last arrived over Realtime (to tell "arrived while refreshing" from "gone"). */
  const liveAt = useRef(new Map<string, number>());
  /** The message that was first on screen before older ones were prepended, and where. */
  const restoreAnchor = useRef<{ id: string; offset: number } | null>(null);
  messagesRef.current = messages;
  const hasOlderRef = useRef(false);
  hasOlderRef.current = hasOlder;
  const peopleRef = useRef<Participant[]>([]);
  peopleRef.current = people;

  const nameOf = useCallback((uid: string) => {
    if (uid === me) return 'You';
    const p = people.find((x) => x.user_id === uid);
    return p ? (p.nickname ?? p.display_name) : 'Someone';
  }, [people, me]);

  /** Merge a server row (or a partial Realtime UPDATE, which omits unchanged long text). */
  const upsert = useCallback((row: Partial<Message> & { id: string }, fromServer = true) => {
    setMessages((prev) => {
      const list = prev ?? [];
      const i = list.findIndex((m) => m.id === row.id
        || (row.client_msg_id !== undefined && m.sender_id === row.sender_id && m.client_msg_id === row.client_msg_id));
      if (i === -1) {
        if (!row.created_at || !row.sender_id) return list;   // partial update for a row we don't have
        return [...list, row as UiMessage].sort((a, b) => a.created_at.localeCompare(b.created_at));
      }
      const next = list.slice();
      next[i] = { ...list[i]!, ...row, ...(fromServer ? { local: undefined } : {}) };
      return next;
    });
  }, []);

  /**
   * Mark as read exactly what is rendered: up to the newest message from someone else
   * on screen (and, when older history was not loaded, from the oldest loaded one).
   * Only while the chat is visible and scrolled to the bottom, debounced and coalesced.
   */
  const readTimer = useRef<ReturnType<typeof setTimeout> | null>(null);
  const doRead = useCallback(() => {
    readTimer.current = null;
    const list = messagesRef.current;
    if (!list || document.visibilityState !== 'visible' || !stick.current) return;
    const server = list.filter((m) => !m.local);
    const theirs = server.filter((m) => m.sender_id !== me && m.kind !== 'snap');
    if (theirs.length === 0) return;
    // Exactly the messages on screen (not a time range that could include unseen ones).
    void rpc('mark_conversation_read', { p_conv: convId, p_ids: theirs.map((m) => m.id) }).catch(() => {});
  }, [convId, me]);
  const markRead = useCallback(() => {
    if (readTimer.current) clearTimeout(readTimer.current);
    readTimer.current = setTimeout(doRead, 500);
  }, [doRead]);

  /** Snap view state for this chat: my own row as a recipient, every row as the sender. */
  const loadSnaps = useCallback(async () => {
    const { data } = await supabase.from('snap_recipients').select('snap_id,recipient_id,status,views_used')
      .eq('conversation_id', convId).limit(500);
    setSnapStates((data ?? []) as SnapState[]);
  }, [convId]);

  /** Load (or reload after a gap) the newest page and reconcile it with what is shown. */
  const refreshSeq = useRef(0);
  const refresh = useCallback(async (initial: boolean) => {
    const started = Date.now();
    const seq = ++refreshSeq.current;
    const [c, ppl, msgs] = await Promise.all([
      supabase.from('conversations').select('kind,name,expiry_mode').eq('id', convId).maybeSingle(),
      rpc<Participant[]>('conversation_participants', { p_conv: convId }),
      supabase.from('messages').select(COLS).eq('conversation_id', convId).order('created_at', { ascending: false }).limit(PAGE),
    ]);
    if (c.error) throw c.error;
    if (msgs.error) throw msgs.error;
    if (!c.data) { setError('This chat is not available.'); setMessages([]); return; }
    // A newer catch-up refresh is on its way: this one is stale (the first load always applies).
    if (!initial && seq !== refreshSeq.current) return;
    const rows = ((msgs.data ?? []) as Message[]).reverse();
    setConv(c.data as typeof conv);
    setPeople(ppl);
    if (initial) setHasOlder(rows.length === PAGE);
    void loadSnaps();
    setMessages((prev) => {
      const oldest = rows[0]?.created_at ?? '';
      const full = rows.length === PAGE;
      const byId = new Map(rows.map((r) => [r.id, r]));
      // A full page that does not reach back to anything already on screen may leave a gap
      // (many messages arrived while away): then start again from this page.
      const prevServer = (prev ?? []).filter((m) => !m.local);
      const gap = !initial && full && prevServer.length > 0 && !prevServer.some((m) => m.created_at >= oldest);
      if (gap) setHasOlder(true);
      // A row the server did not return is kept only if it is older than a full page (loaded
      // earlier with "Load earlier messages") or arrived live after this refresh began.
      // Anything else has disappeared (expired, deleted for me, or hidden by a block).
      const kept = (prev ?? []).filter((m) => m.local
        || (!initial && !byId.has(m.id)
            && ((full && !gap && m.created_at < oldest) || (liveAt.current.get(m.id) ?? 0) >= started)));
      const pending = pendingFor(convId).filter((o) => !rows.some((r) => r.client_msg_id === o.client_msg_id && r.sender_id === o.sender_id));
      // Server rows first, so they win over local copies of the same message.
      const merged = [...rows, ...kept, ...pending];
      const seen = new Set<string>();
      return merged.filter((m) => { const k = `${m.sender_id}:${m.client_msg_id}`; if (seen.has(k)) return false; seen.add(k); return true; })
        .sort((a, b) => a.created_at.localeCompare(b.created_at));
    });
    markRead();
  }, [convId, markRead, loadSnaps]);

  /** Older history, one page at a time, keeping the reader's place in the list. */
  const [loadingOlder, setLoadingOlder] = useState(false);
  const loadOlder = useCallback(async () => {
    const list = messagesRef.current;
    const oldest = list?.find((m) => !m.local)?.created_at;
    if (!oldest || loadingOlder) return;
    setLoadingOlder(true);
    const el = listRef.current;
    const first = el?.querySelector<HTMLElement>('[data-mid]');
    restoreAnchor.current = el && first
      ? { id: first.dataset.mid!, offset: first.getBoundingClientRect().top - el.getBoundingClientRect().top } : null;
    try {
      const { data, error: err } = await supabase.from('messages').select(COLS).eq('conversation_id', convId)
        .lt('created_at', oldest).order('created_at', { ascending: false }).limit(PAGE);
      if (err) throw err;
      const older = ((data ?? []) as Message[]).reverse();
      setHasOlder(older.length === PAGE);
      setMessages((prev) => {
        const have = new Set((prev ?? []).map((m) => m.id));
        return [...older.filter((m) => !have.has(m.id)), ...(prev ?? [])];
      });
    } catch (e) { showToast(errorMessage(e)); }
    finally { setLoadingOlder(false); }
  }, [convId, loadingOlder, showToast]);

  // Results of queued sends (also when the Shell flushes the queue after reconnecting).
  useEffect(() => onOutbox((e) => {
    if (e.type === 'sent') {
      liveAt.current.set(e.id, Date.now());   // confirmed now: a refresh that began earlier must keep it
      setMessages((prev) => prev && prev.map((x) => x.client_msg_id === e.clientId && x.sender_id === me
        ? { ...x, id: x.local ? e.id : x.id, local: undefined } : x));
    } else {
      setMessages((prev) => prev && prev.map((x) => x.client_msg_id === e.clientId ? { ...x, local: 'failed' } : x));
      showToast(e.offline ? 'Offline — it will send when you reconnect.' : errorMessage(e.error));
    }
  }), [me, showToast]);

  const deliver = useCallback((m: UiMessage, blob?: Blob) => {
    enqueue(m, blob);
    return deliverQueued(m.client_msg_id);
  }, []);

  const retryOutbox = useCallback(() => {
    for (const m of pendingFor(convId)) {
      setMessages((p) => p && p.map((x) => x.client_msg_id === m.client_msg_id ? { ...x, local: 'sending' } : x));
      void deliverQueued(m.client_msg_id);
    }
  }, [convId]);

  // Initial load.
  useEffect(() => {
    let alive = true;
    setMessages(null); setError(null); setConv(null); setPeople([]); stick.current = true;
    refresh(true).then(() => { if (alive) retryOutbox(); })
      .catch((e) => { if (alive) { setError(errorMessage(e)); setMessages([]); } });
    return () => { alive = false; };
  }, [convId, refresh, retryOutbox]);

  // Realtime: row changes (RLS-filtered) + private broadcast channel for typing.
  useEffect(() => {
    if (!me) return;
    const rows = supabase.channel(`msgs:${convId}:${crypto.randomUUID()}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'messages', filter: `conversation_id=eq.${convId}` }, (p) => {
        if (p.eventType === 'DELETE') return;
        const row = p.new as Message;
        // Older than the loaded window while there is unloaded history: "Load earlier
        // messages" will fetch it in order; adding it now would leave a gap.
        const oldest = messagesRef.current?.find((m) => !m.local)?.created_at;
        if (hasOlderRef.current && oldest && row.created_at < oldest) return;
        liveAt.current.set(row.id, Date.now());
        upsert(row);
        if (p.eventType === 'INSERT' && row.kind === 'snap') void loadSnaps();
        if (p.eventType === 'INSERT' && row.sender_id !== me) {
          markRead();
          setTyping((t) => { const n = { ...t }; delete n[row.sender_id]; return n; });
        }
      })
      .on('postgres_changes', { event: '*', schema: 'public', table: 'snap_recipients', filter: `conversation_id=eq.${convId}` },
          () => { void loadSnaps(); })
      .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'conversations', filter: `id=eq.${convId}` }, (p) => {
        setConv((c) => c ? { ...c, expiry_mode: (p.new as { expiry_mode: Expiry }).expiry_mode, name: (p.new as { name: string | null }).name } : c);
      })
      .subscribe((status) => {
        if (status !== 'SUBSCRIBED') return;
        // After a reconnect, fetch whatever arrived while the socket was down.
        // Catch up on every (re)join, including the first: a message sent between the
        // initial fetch and the subscription becoming active would otherwise be missed.
        void refresh(false).catch(() => {});
      });
    // Topic "conv:<id>" is authorised by realtime.messages RLS (members only, blocks respected).
    const b = supabase.channel(`conv:${convId}`, { config: { private: true, broadcast: { self: false } } })
      .on('broadcast', { event: 'typing' }, ({ payload }) => {
        const uid = (payload as { user_id?: string }).user_id;
        // Only current participants (the payload is client-supplied).
        if (uid && uid !== me && peopleRef.current.some((p) => p.user_id === uid)) setTyping((t) => ({ ...t, [uid]: Date.now() }));
      })
      .subscribe();
    bcast.current = b;
    const onVis = () => { if (document.visibilityState === 'visible') void refresh(false).catch(() => {}); };
    const onOnline = () => { void refresh(false).catch(() => {}); };   // the Shell flushes the queue
    document.addEventListener('visibilitychange', onVis);
    window.addEventListener('online', onOnline);
    return () => {
      void supabase.removeChannel(rows); void supabase.removeChannel(b); bcast.current = null;
      document.removeEventListener('visibilitychange', onVis); window.removeEventListener('online', onOnline);
      // Leaving the chat right after a message arrived: send the pending read now.
      if (readTimer.current) { clearTimeout(readTimer.current); doRead(); }
    };
  }, [convId, me, upsert, markRead, doRead, refresh, retryOutbox, loadSnaps]);

  // Expire typing indicators after 5 s of silence.
  useEffect(() => {
    if (Object.keys(typing).length === 0) return;
    const t = setInterval(() => setTyping((cur) => Object.fromEntries(Object.entries(cur).filter(([, at]) => Date.now() - at < 5000))), 1000);
    return () => clearInterval(t);
  }, [typing]);

  // Keep scrolled to bottom when new messages arrive, unless the user scrolled up. After
  // "Load earlier messages", keep the reader's place (without relying on scroll anchoring).
  useLayoutEffect(() => {
    const el = listRef.current;
    if (!el) return;
    const anchor = restoreAnchor.current;
    if (anchor) {
      // Put the previously first message back where it was (the button and a day separator
      // above it may have gone, so measure the message itself).
      const node = el.querySelector<HTMLElement>(`[data-mid="${anchor.id}"]`);
      if (node) el.scrollTop += node.getBoundingClientRect().top - el.getBoundingClientRect().top - anchor.offset;
      if (!loadingOlder) restoreAnchor.current = null;
      return;
    }
    if (stick.current) el.scrollTop = el.scrollHeight;
  }, [messages, typing, hasOlder, loadingOlder]);

  // The list gets shorter when the keyboard opens (or the composer grows): stay at the bottom.
  useEffect(() => {
    const el = listRef.current;
    if (!el || typeof ResizeObserver === 'undefined') return;
    const ro = new ResizeObserver(() => { if (stick.current) el.scrollTop = el.scrollHeight; });
    ro.observe(el);
    return () => ro.disconnect();
  }, []);

  function onScroll() {
    const el = listRef.current;
    if (!el) return;
    const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 80;
    if (atBottom && !stick.current) { stick.current = true; markRead(); }
    stick.current = atBottom;
  }

  const composerRef = useRef<HTMLTextAreaElement>(null);
  // Grow the message box with its content (up to the CSS max-height), shrink when sent.
  useLayoutEffect(() => {
    const el = composerRef.current;
    if (!el) return;
    el.style.height = 'auto';
    el.style.height = `${Math.min(el.scrollHeight, 140)}px`;
  }, [text]);

  function onType(v: string) {
    setText(v);
    if (settings?.show_typing !== false && v && Date.now() - lastTypingSent.current > 2500 && bcast.current) {
      lastTypingSent.current = Date.now();
      void bcast.current.send({ type: 'broadcast', event: 'typing', payload: { user_id: me } });
    }
  }

  async function submit() {
    const body = text.trim();
    if (!body || !conv) return;   // still loading: keep the text, the user can send in a moment
    if (editing) {
      const target = editing;
      setEditing(null); setText('');
      try { await rpc('edit_message', { p_msg: target.id, p_body: body }); upsert({ ...target, body, edited_at: new Date().toISOString() }, false); }
      catch (e) { showToast(errorMessage(e)); }
      return;
    }
    const clientId = crypto.randomUUID();
    const m: UiMessage = {
      id: `local-${clientId}`, conversation_id: convId, sender_id: me, kind: 'text', body, reply_to_id: replyTo?.id ?? null,
      client_msg_id: clientId, created_at: new Date().toISOString(), edited_at: null, deleted_at: null, expires_at: null, local: 'sending',
    };
    stick.current = true;
    setMessages((prev) => [...(prev ?? []), m]);
    setText(''); setReplyTo(null);
    await deliver(m);
  }

  const closeViewer = useCallback(() => { setViewing(null); void loadSnaps(); markRead(); }, [loadSnaps, markRead]);

  async function sendPhoto(file: File) {
    let blob: Blob;
    try { blob = await compressImage(file); } catch (e) { showToast(errorMessage(e)); return; }
    const clientId = crypto.randomUUID();

    const m: UiMessage = {
      id: `local-${clientId}`, conversation_id: convId, sender_id: me, kind: 'photo', body: null, media_asset_id: null,
      reply_to_id: replyTo?.id ?? null, client_msg_id: clientId, created_at: new Date().toISOString(),
      edited_at: null, deleted_at: null, expires_at: null, local: 'sending', preview: URL.createObjectURL(blob),
    };
    stick.current = true;
    setMessages((prev) => [...(prev ?? []), m]);
    setReplyTo(null);
    await deliver(m, blob);
  }

  function onKey(e: KeyboardEvent<HTMLTextAreaElement>) {
    if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) { e.preventDefault(); void submit(); }
    if (e.key === 'Escape') { setEditing(null); setReplyTo(null); }
  }

  const other = people.find((p) => p.user_id !== me);
  const title = !conv ? '' : conv.kind === 'group' ? (conv.name ?? 'Group') : other ? nameOf(other.user_id) : 'Chat';
  const typers = Object.keys(typing).map(nameOf);
  const byId = useMemo(() => new Map((messages ?? []).map((m) => [m.id, m])), [messages]);
  const handleOf = (uid: string) => people.find((p) => p.user_id === uid)?.username;
  const menuExpired = menuFor ? isExpired(menuFor) : false;

  function snapBubble(m: UiMessage) {
    const rows = snapStates.filter((s) => s.snap_id === m.snap_id);
    if (m.sender_id === me) {
      const opened = rows.length > 0 && rows.every((r) => r.status !== 'delivered');
      return <button className="snap-bubble" disabled data-testid="snap-sent">📸 Snap · {opened ? 'Opened' : 'Delivered'}</button>;
    }
    const mine = rows.find((r) => r.recipient_id === me);
    const canView = mine && (mine.status === 'delivered' || (mine.status === 'opened' && mine.views_used < 2));
    const label = !mine ? 'Snap' : mine.status === 'delivered' ? 'Tap to view Snap' : canView ? 'Tap to replay' : 'Snap opened';
    return (
      <button className="snap-bubble" disabled={!canView} data-testid="snap-received"
              onClick={() => { if (canView && m.snap_id) setViewing(m.snap_id); }}>📸 {label}</button>
    );
  }

  return (
    <div className="screen screen-full">
      <div style={{ padding: '0 16px' }}>
        <Header title={<span data-testid="chat-title">{title}</span>}
          left={<Link to="/chats" className="icon-btn" aria-label="Back to chats"><Icon name="back" /></Link>}
          right={<button className="icon-btn" aria-label="Chat settings" onClick={() => setShowExpiry(true)}><Icon name="more" /></button>} />
      </div>
      {conv && <div className="chat-notice"><Icon name="lock" size={14} />{EXPIRY_TEXT[conv.expiry_mode]}</div>}
      {error && <div style={{ padding: '0 16px' }}><Banner>{error}</Banner></div>}
      <div className="messages" ref={listRef} onScroll={onScroll} aria-live="polite" data-testid="messages">
        {hasOlder && messages && messages.length > 0 && (
          <button className="link-btn small" style={{ alignSelf: 'center', margin: '8px 0' }} disabled={loadingOlder}
                  onClick={() => { stick.current = false; void loadOlder(); }}>
            {loadingOlder ? 'Loading…' : 'Load earlier messages'}
          </button>
        )}
        {messages === null ? <div className="center"><Spinner /></div> : messages.length === 0 && !error ? (
          <p className="muted small" style={{ textAlign: 'center', marginTop: 40 }}>Say hi 👋</p>
        ) : messages.map((m, i) => {
          const prev = messages[i - 1];
          const newDay = !prev || new Date(prev.created_at).toDateString() !== new Date(m.created_at).toDateString();
          const daySep = newDay && <div className="day-sep">{new Date(m.created_at).toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' })}</div>;
          if (m.kind === 'system') {
            const mode = (m.body ?? '').replace('expiry_mode:', '') as Expiry;
            return (
              <div key={m.client_msg_id + m.sender_id} style={{ display: 'contents' }}>
                {daySep}
                <div className="day-sep" data-testid="system-message">{nameOf(m.sender_id)} changed this chat: {EXPIRY_TEXT[mode] ?? 'settings updated'}</div>
              </div>
            );
          }
          const mine = m.sender_id === me;
          const showAuthor = !mine && conv?.kind === 'group' && (!prev || prev.sender_id !== m.sender_id || newDay || prev.kind === 'system');
          const quoted = m.reply_to_id ? byId.get(m.reply_to_id) : undefined;
          return (
            <div key={m.client_msg_id + m.sender_id} style={{ display: 'contents' }}>
              {daySep}
              <div className={`msg ${mine ? 'msg-me' : 'msg-them'}${m.local === 'sending' ? ' msg-pending' : ''}${m.local === 'failed' ? ' msg-failed' : ''}`}
                   data-testid="message" data-mid={m.id}>
                {showAuthor && <span className="msg-author">{nameOf(m.sender_id)}{handleOf(m.sender_id) ? <span className="muted"> @{handleOf(m.sender_id)}</span> : null}</span>}
                {quoted && <span className="msg-meta">↪ {quoted.deleted_at ? 'deleted message' : (quoted.body ?? '').slice(0, 60)}</span>}
                {m.kind === 'snap' && !m.deleted_at ? snapBubble(m)
                  : m.kind === 'photo' && !m.deleted_at ? (
                  // A photo may contain its own "Tap to load" button, so the bubble itself is not one.
                  <div className="bubble bubble-media">
                    {m.preview ? <img className="chat-photo" src={m.preview} alt="Photo you sent" />
                      : m.media_asset_id ? <ChatImage assetId={m.media_asset_id} dataSaver={settings?.data_saver === true}
                          alt={mine ? 'Photo you sent' : `Photo from ${nameOf(m.sender_id)}`} /> : 'Photo'}
                  </div>
                ) : (
                <button className={`bubble${m.deleted_at ? ' bubble-deleted' : ''}`}
                        style={{ border: 0, font: 'inherit', textAlign: 'left', cursor: 'pointer' }}
                        onClick={() => !m.deleted_at && !m.local && setMenuFor(m)}>
                  {m.deleted_at ? 'Message deleted' : m.kind === 'text' ? m.body : `[${m.kind}]`}
                </button>)}
                <span className="msg-meta">
                  {clockTime(m.created_at)}{m.edited_at && !m.deleted_at ? ' · edited' : ''}
                  {m.kind === 'photo' && !m.deleted_at && !m.local && <> · <button className="link-btn small" aria-label="Photo options"
                    onClick={() => setMenuFor(m)}>Options</button></>}
                  {m.local === 'sending' && ' · sending…'}
                  {m.local === 'failed' && <> · not sent <button className="link-btn small" onClick={() => {
                    setMessages((p) => (p ?? []).map((x) => x.client_msg_id === m.client_msg_id ? { ...x, local: 'sending' } : x));
                    retryQueued(m);
                  }}>Retry</button></>}
                </span>
              </div>
            </div>
          );
        })}
        {typers.length > 0 && <div className="msg msg-them"><span className="msg-meta" data-testid="typing">{typers.join(', ')} {typers.length > 1 ? 'are' : 'is'} typing…</span></div>}
      </div>
      {(replyTo || editing) && (
        <div className="chat-notice" style={{ justifyContent: 'space-between' }}>
          <span className="truncate">{editing ? 'Editing message' : `Replying to: ${(replyTo?.body ?? '').slice(0, 60)}`}</span>
          <button className="link-btn" onClick={() => { setReplyTo(null); if (editing) { setEditing(null); setText(''); } }}>Cancel</button>
        </div>
      )}
      <div className="composer">
        <button className="attach-btn" aria-label="Send a photo" disabled={!conv || Boolean(editing)} onClick={() => fileRef.current?.click()}>
          <Icon name="image" size={20} />
        </button>
        <input ref={fileRef} type="file" accept="image/*" hidden data-testid="photo-input"
               onChange={(e) => { const f = e.target.files?.[0]; e.target.value = ''; if (f) void sendPhoto(f); }} />
        <textarea ref={composerRef} rows={1} aria-label="Message" placeholder="Message" value={text} maxLength={LIMITS.messageMaxChars}
                  enterKeyHint="send" autoComplete="off"
                  onChange={(e) => onType(e.target.value)} onKeyDown={onKey} />
        <button className="send-btn" aria-label={editing ? 'Save edit' : 'Send'} disabled={!text.trim() || !conv} onClick={() => void submit()}>
          <Icon name={editing ? 'check' : 'send'} size={20} />
        </button>
      </div>

      {menuFor && (
        <Sheet label="Message options" onClose={() => setMenuFor(null)}>
          {menuExpired && <p className="muted small" style={{ margin: '4px 4px 8px' }}>This message has disappeared. You can still report it for a short while.</p>}
          {!menuExpired && <button className="sheet-item" onClick={() => { setReplyTo(menuFor); setMenuFor(null); }}>Reply</button>}
          {menuFor.kind === 'text' && <button className="sheet-item" onClick={() => {
            void navigator.clipboard?.writeText(menuFor.body ?? ''); setMenuFor(null); showToast('Copied'); }}>Copy</button>}
          {!menuExpired && <button className="sheet-item" onClick={async () => {
            const m = menuFor; setMenuFor(null);
            try { await rpc('set_message_saved', { p_msg: m.id, p_saved: true }); showToast('Saved — it won’t disappear'); }
            catch (e) { showToast(errorMessage(e)); }
          }}>Save in chat</button>}
          {!menuExpired && menuFor.sender_id === me && canEditMessage(new Date(menuFor.created_at), new Date(), menuFor.kind === 'text') &&
            <button className="sheet-item" onClick={() => { setEditing(menuFor); setText(menuFor.body ?? ''); setMenuFor(null); }}>Edit</button>}
          {menuFor.sender_id === me && <button className="sheet-item danger" onClick={async () => {
            const m = menuFor; setMenuFor(null);
            try { await rpc('delete_message', { p_msg: m.id }); upsert({ ...m, body: null, deleted_at: new Date().toISOString() }, false); }
            catch (e) { showToast(errorMessage(e)); }
          }}>Delete for everyone</button>}
          {menuFor.sender_id !== me && <button className="sheet-item danger" onClick={async () => {
            const m = menuFor; setMenuFor(null);
            try { await rpc('report_message', { p_msg: m.id, p_reason: 'harassment', p_details: null }); showToast('Reported. Thank you.'); }
            catch (e) { showToast(errorMessage(e)); }
          }}>Report message</button>}
          <button className="sheet-item" onClick={() => setMenuFor(null)}>Cancel</button>
        </Sheet>
      )}

      {showExpiry && conv && (
        <Sheet label="Chat settings" onClose={() => setShowExpiry(false)}>
          {conv.kind === 'group' && <Link className="sheet-item" to={`/chats/${convId}/info`}>Group info and members</Link>}
          <p className="muted small" style={{ margin: '4px 4px 8px' }}>Disappearing messages{conv.kind === 'group' ? ' (group admins can change this)' : ''}. A change applies to new messages.</p>
          {(Object.keys(EXPIRY_TEXT) as Expiry[]).map((mode) => (
            <button key={mode} className="sheet-item" aria-pressed={conv.expiry_mode === mode} onClick={async () => {
              setShowExpiry(false);
              try { await rpc('set_chat_expiry', { p_conv: convId, p_mode: mode }); setConv({ ...conv, expiry_mode: mode }); showToast('Updated'); }
              catch (e) { showToast(errorMessage(e)); }
            }}>{conv.expiry_mode === mode ? '✓ ' : ''}{EXPIRY_TEXT[mode]}</button>
          ))}
          <button className="sheet-item" onClick={() => setShowExpiry(false)}>Close</button>
        </Sheet>
      )}
      {viewing && <SnapViewer snapId={viewing} onClose={closeViewer} />}
      {toast}
    </div>
  );
}
