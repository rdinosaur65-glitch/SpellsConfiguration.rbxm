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
import { compressImage, uploadMedia } from '../lib/media';
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

// Unsent messages survive navigating between chats (in memory only: message text is
// never written to device storage). They are retried on reconnect and when the chat opens.
const outbox = new Map<string, UiMessage[]>();
const outboxBlobs = new Map<string, Blob>();   // photos waiting to be (re)sent, keyed by client_msg_id
function outboxPut(m: UiMessage) { outbox.set(m.conversation_id, [...(outbox.get(m.conversation_id) ?? []).filter((x) => x.client_msg_id !== m.client_msg_id), m]); }
function outboxDrop(conv: string, clientId: string) {
  const left = (outbox.get(conv) ?? []).filter((x) => x.client_msg_id !== clientId);
  if (left.length) outbox.set(conv, left); else outbox.delete(conv);
}

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
    const newest = theirs[theirs.length - 1];
    if (!newest) return;
    void rpc('mark_conversation_read', {
      p_conv: convId, p_up_to: newest.created_at,
      p_from: hasOlderRef.current ? (server[0]?.created_at ?? null) : null,
    }).catch(() => {});
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
  const refresh = useCallback(async (initial: boolean) => {
    const [c, ppl, msgs] = await Promise.all([
      supabase.from('conversations').select('kind,name,expiry_mode').eq('id', convId).maybeSingle(),
      rpc<Participant[]>('conversation_participants', { p_conv: convId }),
      supabase.from('messages').select(COLS).eq('conversation_id', convId).order('created_at', { ascending: false }).limit(PAGE),
    ]);
    if (c.error) throw c.error;
    if (msgs.error) throw msgs.error;
    if (!c.data) { setError('This chat is not available.'); setMessages([]); return; }
    const rows = ((msgs.data ?? []) as Message[]).reverse();
    setConv(c.data as typeof conv);
    setPeople(ppl);
    setHasOlder(rows.length === PAGE);
    void loadSnaps();
    setMessages((prev) => {
      const oldest = rows[0]?.created_at ?? '';
      const byId = new Map(rows.map((r) => [r.id, r]));
      const kept = (prev ?? []).filter((m) => m.local
        // Older than this page: keep (still on screen). Inside it but missing: expired or gone.
        || (!initial && m.created_at < oldest && !byId.has(m.id)));
      const pending = (outbox.get(convId) ?? []).filter((o) => !rows.some((r) => r.client_msg_id === o.client_msg_id && r.sender_id === o.sender_id));
      // Server rows first, so they win over local copies of the same message.
      const merged = [...rows, ...kept, ...pending];
      const seen = new Set<string>();
      return merged.filter((m) => { const k = `${m.sender_id}:${m.client_msg_id}`; if (seen.has(k)) return false; seen.add(k); return true; })
        .sort((a, b) => a.created_at.localeCompare(b.created_at));
    });
    markRead();
  }, [convId, markRead, loadSnaps]);

  const deliver = useCallback(async (m: UiMessage) => {
    const blob = m.kind === 'photo' ? outboxBlobs.get(m.client_msg_id) : undefined;
    if (m.kind === 'photo' && !blob) { outboxDrop(m.conversation_id, m.client_msg_id); return; }
    outboxPut({ ...m, local: 'sending' });
    try {
      // Photos: upload first (idempotent: same bytes → same asset), then the message.
      const asset = blob ? await uploadMedia(blob, 'chat') : null;
      // Idempotent: retries reuse client_msg_id, so the server never stores a duplicate.
      const id = await rpc<string>('send_message', {
        p_conv: m.conversation_id, p_kind: m.kind, p_body: m.body, p_client_msg_id: m.client_msg_id,
        p_media_asset: asset, p_reply_to: m.reply_to_id,
      });
      outboxBlobs.delete(m.client_msg_id);
      outboxDrop(m.conversation_id, m.client_msg_id);
      setMessages((prev) => prev && (prev ?? []).map((x) => x.client_msg_id === m.client_msg_id && x.sender_id === m.sender_id
        ? { ...x, id: x.local ? id : x.id, local: undefined } : x));
    } catch (e) {
      const offline = navigator.onLine === false || /fetch|network/i.test((e as Error)?.message ?? '');
      // Offline: keep it queued (in memory) and send it on reconnect. Other errors: keep the
      // message on screen with Retry; a photo keeps its bytes for that retry.
      if (offline) outboxPut({ ...m, local: 'failed' }); else outboxDrop(m.conversation_id, m.client_msg_id);
      setMessages((prev) => prev && prev.map((x) => x.client_msg_id === m.client_msg_id ? { ...x, local: 'failed' } : x));
      showToast(offline ? 'Offline — it will send when you reconnect.' : errorMessage(e));
    }
  }, [showToast]);

  const retryOutbox = useCallback(() => {
    for (const m of outbox.get(convId) ?? []) {
      setMessages((p) => p && p.map((x) => x.client_msg_id === m.client_msg_id ? { ...x, local: 'sending' } : x));
      void deliver(m);
    }
  }, [convId, deliver]);

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
    let first = true;
    const rows = supabase.channel(`msgs:${convId}:${crypto.randomUUID()}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'messages', filter: `conversation_id=eq.${convId}` }, (p) => {
        if (p.eventType === 'DELETE') return;
        const row = p.new as Message;
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
        if (!first) void refresh(false).catch(() => {});
        first = false;
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
    const onOnline = () => { void refresh(false).catch(() => {}); retryOutbox(); };
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

  // Keep scrolled to bottom when new messages arrive, unless the user scrolled up.
  useLayoutEffect(() => {
    const el = listRef.current;
    if (el && stick.current) el.scrollTop = el.scrollHeight;
  }, [messages, typing]);

  function onScroll() {
    const el = listRef.current;
    if (!el) return;
    const atBottom = el.scrollHeight - el.scrollTop - el.clientHeight < 80;
    if (atBottom && !stick.current) { stick.current = true; markRead(); }
    stick.current = atBottom;
  }

  function onType(v: string) {
    setText(v);
    if (settings?.show_typing !== false && v && Date.now() - lastTypingSent.current > 2500 && bcast.current) {
      lastTypingSent.current = Date.now();
      void bcast.current.send({ type: 'broadcast', event: 'typing', payload: { user_id: me } });
    }
  }

  async function submit() {
    const body = text.trim();
    if (!body) return;
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
    outboxBlobs.set(clientId, blob);
    const m: UiMessage = {
      id: `local-${clientId}`, conversation_id: convId, sender_id: me, kind: 'photo', body: null, media_asset_id: null,
      reply_to_id: replyTo?.id ?? null, client_msg_id: clientId, created_at: new Date().toISOString(),
      edited_at: null, deleted_at: null, expires_at: null, local: 'sending', preview: URL.createObjectURL(blob),
    };
    stick.current = true;
    setMessages((prev) => [...(prev ?? []), m]);
    setReplyTo(null);
    await deliver(m);
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
                   data-testid="message">
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
                    void deliver(m);
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
        <textarea rows={1} aria-label="Message" placeholder="Message" value={text} maxLength={LIMITS.messageMaxChars}
                  onChange={(e) => onType(e.target.value)} onKeyDown={onKey} disabled={!conv} />
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
