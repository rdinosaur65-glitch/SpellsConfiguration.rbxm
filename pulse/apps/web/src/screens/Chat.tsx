import { useCallback, useEffect, useLayoutEffect, useMemo, useRef, useState, type KeyboardEvent } from 'react';
import { Link, useParams } from 'react-router-dom';
import type { RealtimeChannel } from '@supabase/supabase-js';
import { canEditMessage, LIMITS } from '@pulse/domain';
import { rpc, supabase } from '../lib/supabase';
import { errorMessage } from '../lib/errors';
import { clockTime } from '../lib/time';
import type { Message, Participant } from '../lib/types';
import { Banner, Header, Icon, Spinner, useToast } from '../components/ui';
import { useAuth } from '../lib/auth';

type Expiry = 'after_view' | 'after_view_24h' | 'after_view_7d' | 'never';
const EXPIRY_TEXT: Record<Expiry, string> = {
  after_view: 'Messages disappear after everyone has seen them',
  after_view_24h: 'Messages disappear 24 hours after viewing',
  after_view_7d: 'Messages disappear 7 days after viewing',
  never: 'Messages are kept',
};

/** A message in the UI: server rows plus local optimistic sends. */
interface UiMessage extends Message { local?: 'sending' | 'failed' }

const COLS = 'id,conversation_id,sender_id,kind,body,reply_to_id,client_msg_id,created_at,edited_at,deleted_at,expires_at';

export function Chat() {
  const { id: convId = '' } = useParams();
  const { profile, settings } = useAuth();
  const me = profile?.id ?? '';
  const [conv, setConv] = useState<{ kind: 'direct' | 'group'; name: string | null; expiry_mode: Expiry } | null>(null);
  const [people, setPeople] = useState<Participant[]>([]);
  const [messages, setMessages] = useState<UiMessage[] | null>(null);
  const [error, setError] = useState<string | null>(null);
  const [text, setText] = useState('');
  const [replyTo, setReplyTo] = useState<UiMessage | null>(null);
  const [editing, setEditing] = useState<UiMessage | null>(null);
  const [menuFor, setMenuFor] = useState<UiMessage | null>(null);
  const [showExpiry, setShowExpiry] = useState(false);
  const [typing, setTyping] = useState<Record<string, number>>({});
  const [toast, showToast] = useToast();
  const listRef = useRef<HTMLDivElement>(null);
  const stick = useRef(true);
  const bcast = useRef<RealtimeChannel | null>(null);
  const lastTypingSent = useRef(0);

  const nameOf = useCallback((uid: string) => {
    const p = people.find((x) => x.user_id === uid);
    return p ? (p.nickname ?? p.display_name) : 'Someone';
  }, [people]);

  const upsert = useCallback((row: Message) => {
    setMessages((prev) => {
      const list = prev ?? [];
      const i = list.findIndex((m) => m.id === row.id || (m.sender_id === row.sender_id && m.client_msg_id === row.client_msg_id));
      if (i === -1) return [...list, row].sort((a, b) => a.created_at.localeCompare(b.created_at));
      const next = list.slice(); next[i] = { ...row }; return next;
    });
  }, []);

  const markRead = useCallback(() => {
    if (document.visibilityState === 'visible') void rpc('mark_conversation_read', { p_conv: convId }).catch(() => {});
  }, [convId]);

  // Initial load.
  useEffect(() => {
    let alive = true;
    setMessages(null); setError(null);
    (async () => {
      try {
        const [c, ppl, msgs] = await Promise.all([
          supabase.from('conversations').select('kind,name,expiry_mode').eq('id', convId).maybeSingle(),
          rpc<Participant[]>('conversation_participants', { p_conv: convId }),
          supabase.from('messages').select(COLS).eq('conversation_id', convId).order('created_at', { ascending: false }).limit(200),
        ]);
        if (c.error) throw c.error;
        if (msgs.error) throw msgs.error;
        if (!alive) return;
        if (!c.data) { setError('This chat is not available.'); setMessages([]); return; }
        setConv(c.data as typeof conv);
        setPeople(ppl);
        setMessages(((msgs.data ?? []) as Message[]).reverse());
        markRead();
      } catch (e) { if (alive) { setError(errorMessage(e)); setMessages([]); } }
    })();
    return () => { alive = false; };
  }, [convId, markRead]);

  // Realtime: row changes (RLS-filtered) + private broadcast channel for typing.
  useEffect(() => {
    if (!me) return;
    const rows = supabase.channel(`msgs:${convId}:${crypto.randomUUID()}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'messages', filter: `conversation_id=eq.${convId}` }, (p) => {
        if (p.eventType === 'DELETE') return;  // purge job: keep what is already on screen until the chat closes
        const row = p.new as Message;
        upsert(row);
        if (row.sender_id !== me) { markRead(); setTyping((t) => { const n = { ...t }; delete n[row.sender_id]; return n; }); }
      })
      .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'conversations', filter: `id=eq.${convId}` }, (p) => {
        setConv((c) => c ? { ...c, expiry_mode: (p.new as { expiry_mode: Expiry }).expiry_mode, name: (p.new as { name: string | null }).name } : c);
      })
      .subscribe();
    // Topic "conv:<id>" is authorised by realtime.messages RLS (members only, blocks respected).
    const b = supabase.channel(`conv:${convId}`, { config: { private: true, broadcast: { self: false } } })
      .on('broadcast', { event: 'typing' }, ({ payload }) => {
        const uid = (payload as { user_id?: string }).user_id;
        if (uid && uid !== me) setTyping((t) => ({ ...t, [uid]: Date.now() }));
      })
      .subscribe();
    bcast.current = b;
    const onVis = () => markRead();
    document.addEventListener('visibilitychange', onVis);
    return () => { void supabase.removeChannel(rows); void supabase.removeChannel(b); bcast.current = null; document.removeEventListener('visibilitychange', onVis); };
  }, [convId, me, upsert, markRead]);

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
    if (el) stick.current = el.scrollHeight - el.scrollTop - el.clientHeight < 80;
  }

  function onType(v: string) {
    setText(v);
    if (settings?.show_typing !== false && v && Date.now() - lastTypingSent.current > 2500 && bcast.current) {
      lastTypingSent.current = Date.now();
      void bcast.current.send({ type: 'broadcast', event: 'typing', payload: { user_id: me } });
    }
  }

  async function deliver(m: UiMessage) {
    try {
      // Idempotent: retries reuse client_msg_id, so the server never stores a duplicate.
      const id = await rpc<string>('send_message', {
        p_conv: convId, p_kind: 'text', p_body: m.body, p_client_msg_id: m.client_msg_id,
        p_media_asset: null, p_reply_to: m.reply_to_id,
      });
      setMessages((prev) => (prev ?? []).map((x) => x.client_msg_id === m.client_msg_id && x.sender_id === me
        ? { ...x, id: x.local ? id : x.id, local: undefined } : x));
    } catch (e) {
      setMessages((prev) => (prev ?? []).map((x) => x.client_msg_id === m.client_msg_id ? { ...x, local: 'failed' } : x));
      showToast(errorMessage(e));
    }
  }

  async function submit() {
    const body = text.trim();
    if (!body) return;
    if (editing) {
      const target = editing;
      setEditing(null); setText('');
      try { await rpc('edit_message', { p_msg: target.id, p_body: body }); upsert({ ...target, body, edited_at: new Date().toISOString() }); }
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

  function onKey(e: KeyboardEvent<HTMLTextAreaElement>) {
    if (e.key === 'Enter' && !e.shiftKey && !e.nativeEvent.isComposing) { e.preventDefault(); void submit(); }
    if (e.key === 'Escape') { setEditing(null); setReplyTo(null); }
  }

  const other = people.find((p) => p.user_id !== me);
  const title = !conv ? '' : conv.kind === 'group' ? (conv.name ?? 'Group') : other ? nameOf(other.user_id) : 'Chat';
  const typers = Object.keys(typing).map(nameOf);
  const byId = useMemo(() => new Map((messages ?? []).map((m) => [m.id, m])), [messages]);

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
          const mine = m.sender_id === me;
          const prev = messages[i - 1];
          const newDay = !prev || new Date(prev.created_at).toDateString() !== new Date(m.created_at).toDateString();
          const showAuthor = !mine && conv?.kind === 'group' && (!prev || prev.sender_id !== m.sender_id || newDay);
          const quoted = m.reply_to_id ? byId.get(m.reply_to_id) : undefined;
          return (
            <div key={m.client_msg_id + m.sender_id} style={{ display: 'contents' }}>
              {newDay && <div className="day-sep">{new Date(m.created_at).toLocaleDateString(undefined, { weekday: 'short', month: 'short', day: 'numeric' })}</div>}
              <div className={`msg ${mine ? 'msg-me' : 'msg-them'}${m.local === 'sending' ? ' msg-pending' : ''}${m.local === 'failed' ? ' msg-failed' : ''}`}
                   data-testid="message">
                {showAuthor && <span className="msg-author">{nameOf(m.sender_id)}</span>}
                {quoted && <span className="msg-meta">↪ {quoted.deleted_at ? 'deleted message' : (quoted.body ?? '').slice(0, 60)}</span>}
                <button className={`bubble${m.deleted_at ? ' bubble-deleted' : ''}`} style={{ border: 0, font: 'inherit', textAlign: 'left', cursor: 'pointer' }}
                        onClick={() => !m.deleted_at && !m.local && setMenuFor(m)}>
                  {m.deleted_at ? 'Message deleted' : m.kind === 'text' ? m.body : `[${m.kind}]`}
                </button>
                <span className="msg-meta">
                  {clockTime(m.created_at)}{m.edited_at && !m.deleted_at ? ' · edited' : ''}
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
        <textarea rows={1} aria-label="Message" placeholder="Message" value={text} maxLength={LIMITS.messageMaxChars}
                  onChange={(e) => onType(e.target.value)} onKeyDown={onKey} disabled={!conv} />
        <button className="send-btn" aria-label={editing ? 'Save edit' : 'Send'} disabled={!text.trim() || !conv} onClick={() => void submit()}>
          <Icon name={editing ? 'check' : 'send'} size={20} />
        </button>
      </div>

      {menuFor && (
        <div className="sheet-backdrop" onClick={() => setMenuFor(null)}>
          <div className="sheet" role="dialog" aria-label="Message options" onClick={(e) => e.stopPropagation()}>
            <button className="sheet-item" onClick={() => { setReplyTo(menuFor); setMenuFor(null); }}>Reply</button>
            {menuFor.kind === 'text' && <button className="sheet-item" onClick={() => {
              void navigator.clipboard?.writeText(menuFor.body ?? ''); setMenuFor(null); showToast('Copied'); }}>Copy</button>}
            <button className="sheet-item" onClick={async () => {
              const m = menuFor; setMenuFor(null);
              try { await rpc('set_message_saved', { p_msg: m.id, p_saved: true }); showToast('Saved — it won’t disappear'); }
              catch (e) { showToast(errorMessage(e)); }
            }}>Save in chat</button>
            {menuFor.sender_id === me && canEditMessage(new Date(menuFor.created_at), new Date(), menuFor.kind === 'text') &&
              <button className="sheet-item" onClick={() => { setEditing(menuFor); setText(menuFor.body ?? ''); setMenuFor(null); }}>Edit</button>}
            {menuFor.sender_id === me && <button className="sheet-item danger" onClick={async () => {
              const m = menuFor; setMenuFor(null);
              try { await rpc('delete_message', { p_msg: m.id }); upsert({ ...m, body: null, deleted_at: new Date().toISOString() }); }
              catch (e) { showToast(errorMessage(e)); }
            }}>Delete for everyone</button>}
            {menuFor.sender_id !== me && <button className="sheet-item danger" onClick={async () => {
              const m = menuFor; setMenuFor(null);
              try { await rpc('report_message', { p_msg: m.id, p_reason: 'harassment', p_details: null }); showToast('Reported. Thank you.'); }
              catch (e) { showToast(errorMessage(e)); }
            }}>Report message</button>}
            <button className="sheet-item" onClick={() => setMenuFor(null)}>Cancel</button>
          </div>
        </div>
      )}

      {showExpiry && conv && (
        <div className="sheet-backdrop" onClick={() => setShowExpiry(false)}>
          <div className="sheet" role="dialog" aria-label="Disappearing messages" onClick={(e) => e.stopPropagation()}>
            <p className="muted small" style={{ margin: '4px 4px 8px' }}>Disappearing messages{conv.kind === 'group' ? ' (group admins can change this)' : ''}</p>
            {(Object.keys(EXPIRY_TEXT) as Expiry[]).map((mode) => (
              <button key={mode} className="sheet-item" aria-pressed={conv.expiry_mode === mode} onClick={async () => {
                setShowExpiry(false);
                try { await rpc('set_chat_expiry', { p_conv: convId, p_mode: mode }); setConv({ ...conv, expiry_mode: mode }); showToast('Updated'); }
                catch (e) { showToast(errorMessage(e)); }
              }}>{conv.expiry_mode === mode ? '✓ ' : ''}{EXPIRY_TEXT[mode]}</button>
            ))}
            <button className="sheet-item" onClick={() => setShowExpiry(false)}>Close</button>
          </div>
        </div>
      )}
      {toast}
    </div>
  );
}
