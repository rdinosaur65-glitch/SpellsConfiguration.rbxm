import { useEffect, useMemo, useState } from 'react';
import { Link, useNavigate } from 'react-router-dom';
import { rpc } from '../lib/supabase';
import { errorMessage } from '../lib/errors';
import { relativeTime } from '../lib/time';
import type { ChatListItem } from '../lib/types';
import { Avatar, Banner, Button, Empty, Header, Icon, Sheet, Spinner, useToast } from '../components/ui';
import { useChatList } from '../lib/live';
import { useAuth } from '../lib/auth';
import { milestonePending, useStreaks, type Streak } from '../lib/streaks';
import { MilestoneBanner, StreakBadge } from '../components/Streak';
import { SearchSheet } from '../components/ChatExtras';

type Folder = 'all' | 'private' | 'groups' | 'unread';
const FOLDERS: Array<[Folder, string]> = [['all', 'All'], ['private', 'Private'], ['groups', 'Groups'], ['unread', 'Unread']];

function labelClass(item: ChatListItem): string {
  const isNew = item.label === 'New Chat' || item.label === 'New Snap';
  const snap = item.label === 'New Snap';
  return `list-sub ${isNew ? 'label-new' : 'label-quiet'}${snap ? ' label-snap' : ''}`;
}

export function Chats() {
  const streaks = useStreaks();
  const [celebrate, setCelebrate] = useState<Streak | null>(null);
  const { items, error, reload } = useChatList();
  const [folder, setFolder] = useState<Folder>('all');
  // Re-read on every visit: some changes (a block, an unfriend) have no realtime event.
  useEffect(() => { void reload(); }, [reload]);
  const [menuFor, setMenuFor] = useState<ChatListItem | null>(null);
  const [creating, setCreating] = useState(false);
  const [searching, setSearching] = useState(false);
  const nav = useNavigate();
  const { profile } = useAuth();
  const [toast, showToast] = useToast();
  const [removing, setRemoving] = useState<string | null>(null);
  const nameFor = (uid: string) => (items ?? []).find((c) => c.kind === 'direct' && c.other_user_id === uid)?.title ?? 'a friend';
  // One quiet celebration per new milestone (the server remembers it was seen).
  useEffect(() => {
    if (celebrate || !items) return;
    const next = [...streaks.values()].find(milestonePending);
    if (next) setCelebrate(next);
  }, [streaks, items, celebrate]);

  /** × on a blocked chat: removes it from *my* list only. Nothing is deleted; the other
   *  person's chat and history are untouched. */
  async function removeFromList(c: ChatListItem) {
    if (removing) return;
    setRemoving(c.conversation_id);
    try { await rpc('hide_chat', { p_conv: c.conversation_id }); showToast('Removed from your chats'); await reload(); }
    catch (e) { showToast(errorMessage(e)); }
    finally { setRemoving(null); }
  }

  const visible = useMemo(() => (items ?? []).filter((c) =>
    folder === 'all' ? true : folder === 'private' ? c.kind === 'direct' : folder === 'groups' ? c.kind === 'group' : c.unread), [items, folder]);

  return (
    <div className="screen">
      <Header title="Chats" left={<button className="icon-btn" aria-label="Search all chats" onClick={() => setSearching(true)}><Icon name="search" /></button>}
        right={<button className="icon-btn" aria-label="New group" onClick={() => setCreating(true)}><Icon name="plus" /></button>} />
      <div className="chips" role="toolbar" aria-label="Chat folders">
        {FOLDERS.map(([f, label]) => (
          <button key={f} className="chip" aria-pressed={folder === f} onClick={() => setFolder(f)}>
            {label}{f === 'unread' && items ? ` ${items.filter((c) => c.unread).length || ''}` : ''}
          </button>
        ))}
      </div>
      {error && <Banner>{error}</Banner>}
      {celebrate && <MilestoneBanner streak={celebrate} name={nameFor(celebrate.friend_id)} onDismiss={() => setCelebrate(null)} />}
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
                    <Button variant="ghost" className="icon-btn" aria-label={`Remove chat with ${title} from your list`}
                      busy={removing === c.conversation_id} onClick={() => void removeFromList(c)}>
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
                      <span className="list-title title-row" style={{ color: c.title_color ?? undefined }}>
                        <span className="truncate">{c.pinned_rank ? '📌 ' : ''}{title}{c.muted ? ' 🔕' : ''}</span>
                        {c.kind === 'direct' && c.other_user_id && <StreakBadge streak={streaks.get(c.other_user_id)} />}
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
      {searching && <SearchSheet title="Search all chats" onClose={() => setSearching(false)}
        nameOf={(uid, conv) => { const t = (items ?? []).find((c) => c.conversation_id === conv)?.title ?? 'Chat'; return uid === profile?.id ? `You in ${t}` : t; }}
        onPick={(h) => { setSearching(false); nav(`/chats/${h.conversation_id}?m=${h.message_id}`); }} />}
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
    <Sheet label="New group" onClose={onClose}>
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
