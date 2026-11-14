import { useCallback, useEffect, useRef, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { rpc, supabase } from '../lib/supabase';
import { errorMessage } from '../lib/errors';
import { relativeTime } from '../lib/time';
import type { SearchResult } from '../lib/types';
import { Avatar, Banner, Button, Empty, Header, Icon, Sheet, Spinner, useToast } from '../components/ui';
import { useAuth } from '../lib/auth';
import { useChatList, useFriendRequests } from '../lib/live';
import { useStreaks } from '../lib/streaks';
import { StreakBadge } from '../components/Streak';

interface FriendRow { user_id: string; username: string; display_name: string; nickname: string | null; nickname_color: string | null;
  online: boolean | null; last_active_at: string | null }
/** Anyone the user can act on: a friend, or the sender of a request. */
interface Person { user_id: string; username: string; display_name: string; friend?: FriendRow }

const normalizeQuery = (q: string) => q.trim().toLowerCase().replace(/^@+/, '');

export function Friends() {
  const nav = useNavigate();
  const { requests, reload: reloadRequests } = useFriendRequests();
  // Re-read on every visit, like the chat list (a live event can be missed while reconnecting).
  useEffect(() => { void reloadRequests(); }, [reloadRequests]);
  const { reload: reloadChats } = useChatList();
  const streaks = useStreaks();
  const [friends, setFriends] = useState<FriendRow[] | null>(null);
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<SearchResult[] | null>(null);
  const [searchError, setSearchError] = useState<string | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [menuFor, setMenuFor] = useState<Person | null>(null);
  const [toast, showToast] = useToast();
  const searchSeq = useRef(0);

  const loadFriends = useCallback(async () => {
    try { setFriends(await rpc<FriendRow[]>('list_friends')); } catch (e) { showToast(errorMessage(e)); setFriends((f) => f ?? []); }
  }, [showToast]);
  // Any change to requests (accepted on another device, the other side removing us…) and
  // returning to the app re-read the list; friendships themselves are not streamed.
  useEffect(() => { void loadFriends(); }, [requests, loadFriends]);
  useEffect(() => {
    const onVisible = () => { if (document.visibilityState === 'visible') void loadFriends(); };
    document.addEventListener('visibilitychange', onVisible);
    return () => document.removeEventListener('visibilitychange', onVisible);
  }, [loadFriends]);

  // Only the newest search may update the list (out-of-order responses are dropped).
  const search = useCallback(async (q: string) => {
    const seq = ++searchSeq.current;
    try {
      const rows = await rpc<SearchResult[]>('search_users', { p_query: q });
      if (seq === searchSeq.current) { setResults(rows); setSearchError(null); }
    } catch (e) { if (seq === searchSeq.current) setSearchError(errorMessage(e)); }
  }, []);

  // Debounced, server-rate-limited username search (min 3 chars; "@name" works too).
  useEffect(() => {
    const q = normalizeQuery(query);
    if (q.length < 3) { searchSeq.current++; setResults(null); setSearchError(null); return; }
    const t = setTimeout(() => void search(q), 300);
    return () => clearTimeout(t);
  }, [query, search]);

  async function act(id: string, fn: () => Promise<unknown>, done: string) {
    if (busyId) return;
    setBusyId(id);
    try { await fn(); showToast(done); await Promise.all([reloadRequests(), loadFriends()]); }
    catch (e) { showToast(errorMessage(e)); }
    finally { setBusyId(null); }
    const q = normalizeQuery(query);
    if (q.length >= 3) void search(q);
  }

  const opening = useRef(false);
  async function openChat(userId: string) {
    if (opening.current) return;                 // a double tap opens the chat once
    opening.current = true;
    try { const conv = await rpc<string>('create_direct_conversation', { p_friend: userId }); nav(`/chats/${conv}`); }
    catch (e) { showToast(errorMessage(e)); }
    finally { opening.current = false; }
  }

  const incoming = requests.filter((r) => r.direction === 'incoming');
  const outgoing = requests.filter((r) => r.direction === 'outgoing');

  return (
    <div className="screen">
      <Header title="Friends" />
      <div className="search">
        <Icon name="search" size={20} />
        <div className="field">
          <input type="search" aria-label="Search by username" placeholder="Search by username" value={query}
                 autoCapitalize="none" spellCheck={false} onChange={(e) => setQuery(e.target.value)} />
        </div>
      </div>

      {searchError && <div style={{ marginTop: 12 }}><Banner>{searchError}</Banner></div>}
      {results && (
        <>
          <h2 className="section-title">Results</h2>
          {results.length === 0 ? <p className="muted small">No one found with that username.</p> : (
            <div className="list">
              {results.map((r) => (
                <div key={r.id} className="list-item">
                  <Avatar name={r.display_name} />
                  <div className="grow">
                    <div className="list-title truncate">{r.display_name}</div>
                    <div className="list-sub">@{r.username}</div>
                  </div>
                  {r.relationship === 'none' && <Button className="btn btn-primary btn-sm" busy={busyId === r.id} aria-label={`Add @${r.username}`}
                    onClick={() => act(r.id, () => rpc('send_friend_request', { p_target: r.id }), 'Request sent')}>Add</Button>}
                  {r.relationship === 'request_sent' && <span className="muted small">Requested</span>}
                  {r.relationship === 'request_received' && <Button className="btn btn-primary btn-sm" busy={busyId === r.id}
                    onClick={() => act(r.id, () => rpc('send_friend_request', { p_target: r.id }), 'You are now friends')}>Accept</Button>}
                  {r.relationship === 'friend' && <Button className="btn btn-subtle btn-sm" onClick={() => openChat(r.id)}>Chat</Button>}
                  {r.relationship !== 'friend' && <button className="icon-btn" aria-label={`More options for ${r.username}`}
                    onClick={() => setMenuFor({ user_id: r.id, username: r.username, display_name: r.display_name })}>
                    <Icon name="more" size={18} /></button>}
                </div>
              ))}
            </div>
          )}
        </>
      )}

      {incoming.length > 0 && (
        <>
          <h2 className="section-title">Friend requests · {incoming.length}</h2>
          <div className="list">
            {incoming.map((r) => (
              <div key={r.id} className="list-item" data-testid="incoming-request">
                <Avatar name={r.display_name} />
                <div className="grow">
                  <div className="list-title truncate">{r.display_name}</div>
                  <div className="list-sub">@{r.username} · {relativeTime(r.created_at)}</div>
                </div>
                <Button className="btn btn-primary btn-sm" busy={busyId === r.id}
                  onClick={() => act(r.id, () => rpc('respond_friend_request', { p_request: r.id, p_accept: true }), 'Friend added')}>Accept</Button>
                <button className="icon-btn" aria-label={`Decline ${r.username}`} disabled={busyId === r.id}
                  onClick={() => act(r.id, () => rpc('respond_friend_request', { p_request: r.id, p_accept: false }), 'Declined')}>
                  <Icon name="close" size={18} />
                </button>
                <button className="icon-btn" aria-label={`More options for ${r.username}`}
                  onClick={() => setMenuFor({ user_id: r.user_id, username: r.username, display_name: r.display_name })}>
                  <Icon name="more" size={18} />
                </button>
              </div>
            ))}
          </div>
        </>
      )}

      {outgoing.length > 0 && (
        <>
          <h2 className="section-title">Sent</h2>
          <div className="list">
            {outgoing.map((r) => (
              <div key={r.id} className="list-item">
                <Avatar name={r.display_name} size={36} />
                <div className="grow">
                  <div className="list-title truncate">{r.display_name}</div>
                  <div className="list-sub">@{r.username}</div>
                </div>
                <Button className="btn btn-ghost btn-sm" busy={busyId === r.id}
                  onClick={() => act(r.id, () => rpc('cancel_friend_request', { p_request: r.id }), 'Request cancelled')}>Cancel</Button>
              </div>
            ))}
          </div>
        </>
      )}

      <h2 className="section-title">My friends{friends ? ` · ${friends.length}` : ''}</h2>
      {friends === null ? <div className="center" style={{ minHeight: 120 }}><Spinner /></div> :
        friends.length === 0 ? <Empty title="No friends yet">Search for a username above to send a request.</Empty> : (
          <div className="list">
            {friends.map((f) => {
              const name = f.nickname ?? f.display_name;
              return (
                <div key={f.user_id} className="list-item" data-testid="friend-row">
                  <button className="row grow" style={{ background: 'none', border: 0, padding: 0, cursor: 'pointer', textAlign: 'left' }}
                          onClick={() => openChat(f.user_id)}>
                    <Avatar name={name} online={f.online} />
                    <span className="grow">
                      <span className="list-title title-row" style={{ color: f.nickname_color ?? undefined }}><span className="truncate">{name}</span><StreakBadge streak={streaks.get(f.user_id)} /></span>
                      <span className="list-sub">@{f.username}{f.online ? ' · Online' : f.last_active_at ? ` · ${relativeTime(f.last_active_at)}` : ''}</span>
                    </span>
                  </button>
                  <button className="icon-btn" aria-label={`More options for ${f.username}`}
                    onClick={() => setMenuFor({ user_id: f.user_id, username: f.username, display_name: f.display_name, friend: f })}>
                    <Icon name="more" size={18} />
                  </button>
                </div>
              );
            })}
          </div>
        )}

      {menuFor && <PersonMenu person={menuFor} onClose={() => setMenuFor(null)} onDone={async (msg) => {
        setMenuFor(null); showToast(msg); await Promise.all([loadFriends(), reloadRequests(), reloadChats()]); }} />}
      {toast}
    </div>
  );
}

const REPORT_REASONS: Array<[string, string]> = [
  ['harassment', 'Harassment or bullying'], ['spam', 'Spam'], ['impersonation', 'Pretending to be someone'],
  ['hate', 'Hate speech'], ['sexual_content', 'Sexual content'], ['violence', 'Violence or threats'],
  ['self_harm', 'Self-harm concern'], ['underage', 'May be under age'], ['other', 'Something else'],
];

function PersonMenu({ person, onClose, onDone }: { person: Person; onClose: () => void; onDone: (msg: string) => void }) {
  const { profile } = useAuth();
  const friend = person.friend;
  const [mode, setMode] = useState<'menu' | 'nickname' | 'report' | 'confirm-report'>('menu');
  const [reason, setReason] = useState<[string, string] | null>(null);
  const [nickname, setNickname] = useState(friend?.nickname ?? '');
  const [color, setColor] = useState(friend?.nickname_color ?? '#8B5CF6');
  const [error, setError] = useState<string | null>(null);
  const [busy, setBusy] = useState(false);

  async function run(fn: () => Promise<unknown>, msg: string) {
    if (busy) return;
    setBusy(true);
    try { await fn(); onDone(msg); } catch (e) { setError(errorMessage(e)); } finally { setBusy(false); }
  }
  async function saveNickname() {
    if (!profile || !friend) return;
    const nick = nickname.trim();
    await run(async () => {
      if (!nick) {
        const { error } = await supabase.from('friend_nicknames').delete().eq('owner_id', profile.id).eq('friend_id', person.user_id);
        if (error) throw error;
      } else {
        const { error } = await supabase.from('friend_nicknames').upsert(
          { owner_id: profile.id, friend_id: person.user_id, nickname: nick, color, updated_at: new Date().toISOString() });
        if (error) throw error;
      }
    }, nick ? 'Nickname saved (only you can see it)' : 'Nickname removed');
  }

  return (
    <Sheet label={`Options for ${person.username}`} onClose={onClose}>
      {error && <Banner>{error}</Banner>}
      {mode === 'menu' ? (
        <>
          {friend && <button className="sheet-item" onClick={() => setMode('nickname')}>Set private nickname</button>}
          {friend && <button className="sheet-item danger" disabled={busy} onClick={() => {
            if (confirm(`Remove ${person.display_name} from your friends?`)) void run(() => rpc('remove_friend', { p_friend: person.user_id }), 'Friend removed');
          }}>Remove friend</button>}
          <button className="sheet-item danger" disabled={busy} onClick={() => {
            if (confirm(`Block @${person.username}? They won't be able to find or contact you. You can unblock them in Settings.`)) {
              void run(() => rpc('block_user', { p_target: person.user_id }), 'Blocked');
            }
          }}>Block</button>
          <button className="sheet-item danger" onClick={() => setMode('report')}>Report</button>
          <button className="sheet-item" onClick={onClose}>Cancel</button>
        </>
      ) : mode === 'report' ? (
        <>
          <p className="muted small" style={{ margin: '4px 4px 8px' }}>Why are you reporting @{person.username}? The owner sees only the report, never your chats.</p>
          {REPORT_REASONS.map((r) => (
            <button key={r[0]} className="sheet-item" onClick={() => { setReason(r); setMode('confirm-report'); }}>{r[1]}</button>
          ))}
          <button className="sheet-item" onClick={() => setMode('menu')}>Back</button>
        </>
      ) : mode === 'confirm-report' && reason ? (
        <div className="stack" style={{ padding: '4px 0' }}>
          <p className="small" style={{ margin: '4px' }}>Report @{person.username} for “{reason[1]}”?</p>
          <Button variant="danger" busy={busy}
            onClick={() => void run(() => rpc('report_user', { p_user: person.user_id, p_reason: reason[0], p_details: null }), 'Report sent. Thank you.')}>
            Send report</Button>
          <Button variant="ghost" onClick={() => setMode('report')}>Back</Button>
        </div>
      ) : (
        <div className="stack" style={{ padding: '4px 0' }}>
          <label className="field" htmlFor="nickname-input">
            <span className="field-label">Nickname for @{person.username} (only you see this)</span>
            <input id="nickname-input" value={nickname} maxLength={40} onChange={(e) => setNickname(e.target.value)} autoFocus />
          </label>
          <label className="row"><span className="field-label">Colour</span>
            <input type="color" value={color} onChange={(e) => setColor(e.target.value)} aria-label="Nickname colour" /></label>
          <Button busy={busy} onClick={saveNickname}>Save</Button>
          <Button variant="ghost" onClick={() => setMode('menu')}>Back</Button>
        </div>
      )}
    </Sheet>
  );
}
