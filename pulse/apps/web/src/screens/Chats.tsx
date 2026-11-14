import { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { rpc } from '../lib/supabase';
import { errorMessage } from '../lib/errors';
import { relativeTime } from '../lib/time';
import type { ChatListItem } from '../lib/types';
import { Avatar, Banner, Button, Empty, Header, Icon, Sheet, Spinner, useToast } from '../components/ui';
import { useChatList } from '../lib/live';

type Folder = 'all' | 'private' | 'groups' | 'unread';
const FOLDERS: Array<[Folder, string]> = [['all', 'All'], ['private', 'Private'], ['groups', 'Groups'], ['unread', 'Unread']];

function labelClass(item: ChatListItem): string {
  const isNew = item.label === 'New Chat' || item.label === 'New Snap';
  const snap = item.label === 'New Snap';
  return `list-sub ${isNew ? 'label-new' : 'label-quiet'}${snap ? ' label-snap' : ''}`;
}

export function Chats() {
  const { items, error, reload } = useChatList();
  const [folder, setFolder] = useState<Folder>('all');
  // Re-read on every visit: some changes (a block, an unfriend) have no realtime event.
  useEffect(() => { void reload(); }, [reload]);
  const [menuFor, setMenuFor] = useState<ChatListItem | null>(null);
  const [creating, setCreating] = useState(false);
  const [toast, showToast] = useToast();
  const [erasing, setErasing] = useState<string | null>(null);

  async function erase(c: ChatListItem, title: string) {
    if (erasing) return;
    if (!window.confirm(`Delete your chat with ${title} for good? Every message, photo and Snap in it is erased for both of you. This cannot be undone.`)) return;
    setErasing(c.conversation_id);
    try { await rpc('delete_blocked_chat', { p_conv: c.conversation_id }); showToast('Chat deleted'); await reload(); }
    catch (e) { showToast(errorMessage(e)); }
    finally { setErasing(null); }
  }

  const visible = useMemo(() => (items ?? []).filter((c) =>
    folder === 'all' ? true : folder === 'private' ? c.kind === 'direct' : folder === 'groups' ? c.kind === 'group' : c.unread), [items, folder]);

  return (
    <div className="screen">
      <Header title="Chats" right={<button className="icon-btn" aria-label="New group" onClick={() => setCreating(true)}><Icon name="plus" /></button>} />
      <div className="chips" role="toolbar" aria-label="Chat folders">
        {FOLDERS.map(([f, label]) => (
          <button key={f} className="chip" aria-pressed={folder === f} onClick={() => setFolder(f)}>
            {label}{f === 'unread' && items ? ` ${items.filter((c) => c.unread).length || ''}` : ''}
          </button>
        ))}
      </div>
      {error && <Banner>{error}</Banner>}
      {items === null ? <div className="center"><Spinner /></div> :
        visible.length === 0 ? (
          <Empty title={folder === 'all' ? 'No chats yet' : 'Nothing here'}>
            {folder === 'all' ? <>Add friends on the <Link to="/friends">Friends</Link> tab, then tap a friend to start chatting.</> : null}
          </Empty>
        ) : (
          <div className="list">
            {visible.map((c) => {
              const title = c.title ?? 'Chat';
              if (c.blocked) {
                return (
                  <div key={c.conversation_id} className="row list-item" data-testid="chat-row">
                    <Avatar name={title} />
                    <span className="grow">
                      <span className="list-title truncate" style={{ display: 'block' }}>{title}</span>
                      <span className="list-sub label-quiet"><span className="label-dot" />Blocked</span>
                    </span>
                    <Button variant="ghost" className="icon-btn" aria-label={`Delete chat with ${title}`}
                      busy={erasing === c.conversation_id} onClick={() => void erase(c, title)}>
                      <Icon name="close" size={20} />
                    </Button>
                  </div>
                );
              }
              return (
                <div key={c.conversation_id} className="row" data-testid="chat-row">
                  <Link to={`/chats/${c.conversation_id}`} className="list-item grow" aria-label={`${title}: ${c.label}`}>
                    <Avatar name={title} />
                    <span className="grow">
                      <span className="list-title truncate" style={{ display: 'block', color: c.title_color ?? undefined }}>
                        {c.pinned_rank ? '📌 ' : ''}{title}{c.muted ? ' 🔕' : ''}
                      </span>
                      <span className={labelClass(c)}>
                        <span className="label-dot" />{c.label} · {relativeTime(c.last_activity)}
                      </span>
                    </span>
                  </Link>
                  <button className="icon-btn" aria-label={`Options for ${title}`} onClick={() => setMenuFor(c)}><Icon name="more" size={18} /></button>
                </div>
              );
            })}
          </div>
        )}
      <p className="muted small" style={{ textAlign: 'center', marginTop: 20 }}>Message previews are never shown here, by design.</p>
      {menuFor && <ChatMenu item={menuFor} items={items ?? []} onClose={() => setMenuFor(null)}
        onDone={async (m) => { setMenuFor(null); showToast(m); await reload(); }} onError={showToast} />}
      {creating && <NewGroup onClose={() => setCreating(false)} />}
      {toast}
    </div>
  );
}

function ChatMenu({ item, items, onClose, onDone, onError }:
  { item: ChatListItem; items: ChatListItem[]; onClose: () => void; onDone: (m: string) => void; onError: (m: string) => void }) {
  async function run(fn: () => Promise<unknown>, msg: string) {
    try { await fn(); onDone(msg); } catch (e) { onError(errorMessage(e)); onClose(); }
  }
  const usedRanks = new Set(items.map((i) => i.pinned_rank).filter(Boolean));
  const freeRank = [1, 2, 3].find((r) => !usedRanks.has(r));
  return (
    <Sheet label="Chat options" onClose={onClose}>
        {item.pinned_rank
          ? <button className="sheet-item" onClick={() => run(() => rpc('set_pin', { p_conv: item.conversation_id, p_rank: null }), 'Unpinned')}>Unpin</button>
          : <button className="sheet-item" disabled={!freeRank}
              onClick={() => run(() => rpc('set_pin', { p_conv: item.conversation_id, p_rank: freeRank }), 'Pinned')}>
              {freeRank ? 'Pin to top' : 'Pin (max 3 pinned)'}</button>}
        {item.muted
          ? <button className="sheet-item" onClick={() => run(() => rpc('set_mute', { p_conv: item.conversation_id, p_until: null }), 'Unmuted')}>Unmute</button>
          : <>
              <button className="sheet-item" onClick={() => run(() => rpc('set_mute', { p_conv: item.conversation_id, p_until: new Date(Date.now() + 8 * 3600e3).toISOString() }), 'Muted for 8 hours')}>Mute for 8 hours</button>
              <button className="sheet-item" onClick={() => run(() => rpc('set_mute', { p_conv: item.conversation_id, p_until: '9999-12-31T00:00:00Z' }), 'Muted')}>Mute until I turn it back on</button>
            </>}
        <button className="sheet-item" onClick={onClose}>Cancel</button>
    </Sheet>
  );
}

function NewGroup({ onClose }: { onClose: () => void }) {
  const nav = useNavigate();
  const [friends, setFriends] = useState<Array<{ user_id: string; username: string; display_name: string; nickname: string | null }> | null>(null);
  const [picked, setPicked] = useState<Set<string>>(new Set());
  const [name, setName] = useState('');
  const [busy, setBusy] = useState(false);
  const [error, setError] = useState<string | null>(null);
  useEffect(() => { rpc<typeof friends>('list_friends').then(setFriends).catch((e) => setError(errorMessage(e))); }, []);

  async function create() {
    if (busy) return;
    setBusy(true); setError(null);
    try { const id = await rpc<string>('create_group', { p_name: name.trim(), p_members: [...picked] }); nav(`/chats/${id}`); }
    catch (e) { setError(errorMessage(e)); setBusy(false); }
  }
  return (
    <Sheet label="New group" onClose={onClose} style={{ maxHeight: '85vh', overflowY: 'auto' }}>
        <h2 style={{ fontSize: 18, margin: '4px 4px 8px' }}>New group</h2>
        {error && <Banner>{error}</Banner>}
        <label className="field" htmlFor="group-name"><span className="field-label">Group name</span>
          <input id="group-name" value={name} maxLength={50} onChange={(e) => setName(e.target.value)} placeholder="Weekend crew" /></label>
        <span className="field-label" style={{ margin: '8px 4px 0' }}>Friends ({picked.size} selected, up to 31)</span>
        {friends === null ? <Spinner /> : friends.length === 0 ? <p className="muted small">Add friends first.</p> :
          friends.map((f) => (
            <label key={f.user_id} className="list-item">
              <input type="checkbox" checked={picked.has(f.user_id)} onChange={(e) => {
                const next = new Set(picked); if (e.target.checked) next.add(f.user_id); else next.delete(f.user_id); setPicked(next);
              }} />
              <Avatar name={f.nickname ?? f.display_name} size={34} />
              <span className="grow truncate">{f.nickname ?? f.display_name} <span className="muted small">@{f.username}</span></span>
            </label>
          ))}
        <Button busy={busy} disabled={!name.trim() || picked.size === 0 || picked.size > 31} onClick={create}>Create group</Button>
        <Button variant="ghost" onClick={onClose}>Cancel</Button>
    </Sheet>
  );
}
