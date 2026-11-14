import { useCallback, useEffect, useState } from 'react';
import { useNavigate } from 'react-router-dom';
import { rpc, supabase } from '../lib/supabase';
import { errorMessage } from '../lib/errors';
import { relativeTime } from '../lib/time';
import type { SearchResult } from '../lib/types';
import { Avatar, Banner, Button, Empty, Header, Icon, Spinner, useToast } from '../components/ui';
import { useAuth } from '../lib/auth';

interface RequestRow { id: string; direction: 'incoming' | 'outgoing'; user_id: string; username: string; display_name: string; created_at: string }
interface FriendRow { user_id: string; username: string; display_name: string; nickname: string | null; nickname_color: string | null;
  online: boolean | null; last_active_at: string | null }

export function useFriendRequests() {
  const { profile } = useAuth();
  const [requests, setRequests] = useState<RequestRow[]>([]);
  const reload = useCallback(async () => {
    try { setRequests(await rpc<RequestRow[]>('my_friend_requests')); } catch { /* shown elsewhere */ }
  }, []);
  useEffect(() => {
    if (!profile?.id) return;
    void reload();
    // RLS limits these change events to requests the user is part of.
    const ch = supabase.channel(`fr:${profile.id}:${crypto.randomUUID()}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'friend_requests' }, () => { void reload(); })
      .subscribe();
    return () => { void supabase.removeChannel(ch); };
  }, [profile?.id, reload]);  // re-subscribe only when the account changes
  return { requests, reload };
}

export function Friends() {
  const nav = useNavigate();
  const { requests, reload: reloadRequests } = useFriendRequests();
  const [friends, setFriends] = useState<FriendRow[] | null>(null);
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<SearchResult[] | null>(null);
  const [searchError, setSearchError] = useState<string | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [menuFor, setMenuFor] = useState<FriendRow | null>(null);
  const [toast, showToast] = useToast();

  const loadFriends = useCallback(async () => {
    try { setFriends(await rpc<FriendRow[]>('list_friends')); } catch (e) { showToast(errorMessage(e)); setFriends([]); }
  }, [showToast]);
  useEffect(() => { void loadFriends(); }, [loadFriends]);
  useEffect(() => { void loadFriends(); }, [requests.length, loadFriends]);

  // Debounced, server-rate-limited username search (min 3 chars).
  useEffect(() => {
    const q = query.trim().toLowerCase();
    if (q.length < 3) { setResults(null); setSearchError(null); return; }
    const t = setTimeout(async () => {
      try { setResults(await rpc<SearchResult[]>('search_users', { p_query: q })); setSearchError(null); }
      catch (e) { setSearchError(errorMessage(e)); }
    }, 300);
    return () => clearTimeout(t);
  }, [query]);

  async function act(id: string, fn: () => Promise<unknown>, done: string) {
    setBusyId(id);
    try { await fn(); showToast(done); await Promise.all([reloadRequests(), loadFriends()]); }
    catch (e) { showToast(errorMessage(e)); }
    finally { setBusyId(null); }
    if (query.trim().length >= 3) {
      rpc<SearchResult[]>('search_users', { p_query: query.trim().toLowerCase() }).then(setResults).catch(() => {});
    }
  }

  async function openChat(userId: string) {
    try { const conv = await rpc<string>('create_direct_conversation', { p_friend: userId }); nav(`/chats/${conv}`); }
    catch (e) { showToast(errorMessage(e)); }
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
                      <span className="list-title truncate" style={{ display: 'block', color: f.nickname_color ?? undefined }}>{name}</span>
                      <span className="list-sub">@{f.username}{f.online ? ' · Online' : f.last_active_at ? ` · ${relativeTime(f.last_active_at)}` : ''}</span>
                    </span>
                  </button>
                  <button className="icon-btn" aria-label={`More options for ${f.username}`} onClick={() => setMenuFor(f)}>
                    <Icon name="more" size={18} />
                  </button>
                </div>
              );
            })}
          </div>
        )}

      {menuFor && <FriendMenu friend={menuFor} onClose={() => setMenuFor(null)} onDone={async (msg) => {
        setMenuFor(null); showToast(msg); await loadFriends(); }} />}
      {toast}
    </div>
  );
}

const REPORT_REASONS: Array<[string, string]> = [
  ['harassment', 'Harassment or bullying'], ['spam', 'Spam'], ['impersonation', 'Pretending to be someone'],
  ['hate', 'Hate speech'], ['sexual_content', 'Sexual content'], ['violence', 'Violence or threats'],
  ['self_harm', 'Self-harm concern'], ['underage', 'May be under age'], ['other', 'Something else'],
];

function FriendMenu({ friend, onClose, onDone }: { friend: FriendRow; onClose: () => void; onDone: (msg: string) => void }) {
  const { profile } = useAuth();
  const [mode, setMode] = useState<'menu' | 'nickname' | 'report'>('menu');
  const [nickname, setNickname] = useState(friend.nickname ?? '');
  const [color, setColor] = useState(friend.nickname_color ?? '#8B5CF6');
  const [error, setError] = useState<string | null>(null);

  async function run(fn: () => Promise<unknown>, msg: string) {
    try { await fn(); onDone(msg); } catch (e) { setError(errorMessage(e)); }
  }
  async function saveNickname() {
    if (!profile) return;
    const nick = nickname.trim();
    await run(async () => {
      if (!nick) {
        const { error } = await supabase.from('friend_nicknames').delete().eq('owner_id', profile.id).eq('friend_id', friend.user_id);
        if (error) throw error;
      } else {
        const { error } = await supabase.from('friend_nicknames').upsert(
          { owner_id: profile.id, friend_id: friend.user_id, nickname: nick, color, updated_at: new Date().toISOString() });
        if (error) throw error;
      }
    }, nick ? 'Nickname saved (only you can see it)' : 'Nickname removed');
  }

  return (
    <div className="sheet-backdrop" onClick={onClose}>
      <div className="sheet" role="dialog" aria-label={`Options for ${friend.username}`} onClick={(e) => e.stopPropagation()}>
        {error && <Banner>{error}</Banner>}
        {mode === 'menu' ? (
          <>
            <button className="sheet-item" onClick={() => setMode('nickname')}>Set private nickname</button>
            <button className="sheet-item danger" onClick={() => {
              if (confirm(`Remove ${friend.display_name} from your friends?`)) void run(() => rpc('remove_friend', { p_friend: friend.user_id }), 'Friend removed');
            }}>Remove friend</button>
            <button className="sheet-item danger" onClick={() => {
              if (confirm(`Block @${friend.username}? They won't be able to find or contact you.`)) void run(() => rpc('block_user', { p_target: friend.user_id }), 'Blocked');
            }}>Block</button>
            <button className="sheet-item danger" onClick={() => setMode('report')}>Report</button>
            <button className="sheet-item" onClick={onClose}>Cancel</button>
          </>
        ) : mode === 'report' ? (
          <>
            <p className="muted small" style={{ margin: '4px 4px 8px' }}>Why are you reporting @{friend.username}? The owner sees only the report, never your chats.</p>
            {REPORT_REASONS.map(([value, label]) => (
              <button key={value} className="sheet-item" onClick={() =>
                void run(() => rpc('report_user', { p_user: friend.user_id, p_reason: value, p_details: null }), 'Report sent. Thank you.')}>{label}</button>
            ))}
            <button className="sheet-item" onClick={() => setMode('menu')}>Back</button>
          </>
        ) : (
          <div className="stack" style={{ padding: '4px 0' }}>
            <div className="field">
              <span className="field-label">Nickname for @{friend.username} (only you see this)</span>
              <input value={nickname} maxLength={40} onChange={(e) => setNickname(e.target.value)} autoFocus />
            </div>
            <label className="row"><span className="field-label">Colour</span>
              <input type="color" value={color} onChange={(e) => setColor(e.target.value)} aria-label="Nickname colour" /></label>
            <Button onClick={saveNickname}>Save</Button>
            <Button variant="ghost" onClick={() => setMode('menu')}>Back</Button>
          </div>
        )}
      </div>
    </div>
  );
}
