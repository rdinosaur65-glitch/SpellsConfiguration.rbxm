import { useCallback, useEffect, useRef, useState } from 'react';
import { Link, useNavigate, useSearchParams } from 'react-router-dom';
import { rpc, supabase } from '../lib/supabase';
import { errorMessage } from '../lib/errors';
import { relativeTime } from '../lib/time';
import type { SearchResult } from '../lib/types';
import { Avatar, Banner, Button, Header, Icon, Sheet, Spinner, useToast } from '../components/ui';
import { useAuth } from '../lib/auth';
import { useChatList, useFriendRequests } from '../lib/live';
import { useStreaks, type Streak } from '../lib/streaks';
import { StreakBadge } from '../components/Streak';

/**
 * People: everything about friends in one place, opened from the Chats header.
 * Discover (find invited members by username), Requests (incoming and sent), Friends.
 * All rules stay on the server: search only returns people the privacy rules allow
 * (never someone who blocked you), and every action is an RPC with its own checks.
 */
interface FriendRow { user_id: string; username: string; display_name: string; nickname: string | null; nickname_color: string | null;
  online: boolean | null; last_active_at: string | null }
interface BlockedRow { user_id: string; username: string; display_name: string }
/** Anyone the user can act on: a friend, or the sender of a request. */
interface Person { user_id: string; username: string; display_name: string; friend?: FriendRow }
type Tab = 'discover' | 'requests' | 'friends';

const normalizeQuery = (q: string) => q.trim().toLowerCase().replace(/^@+/, '');

export function People() {
  const nav = useNavigate();
  const [params, setParams] = useSearchParams();
  const { requests, reload: reloadRequests } = useFriendRequests();
  // Re-read on every visit, like the chat list (a live event can be missed while reconnecting).
  useEffect(() => { void reloadRequests(); }, [reloadRequests]);
  const { reload: reloadChats } = useChatList();
  const streaks = useStreaks();
  const [friends, setFriends] = useState<FriendRow[] | null>(null);
  const [blocked, setBlocked] = useState<BlockedRow[]>([]);
  const [query, setQuery] = useState('');
  const [results, setResults] = useState<SearchResult[] | null>(null);
  const [searching, setSearching] = useState(false);
  const [searchError, setSearchError] = useState<string | null>(null);
  const [busyId, setBusyId] = useState<string | null>(null);
  const [menuFor, setMenuFor] = useState<Person | null>(null);
  const [toast, showToast] = useToast();
  const searchSeq = useRef(0);

  const incoming = requests.filter((r) => r.direction === 'incoming');
  const outgoing = requests.filter((r) => r.direction === 'outgoing');
  // Where to land: waiting requests first, then your friends, or Discover when you have none.
  const asked = params.get('tab');
  const tab: Tab = asked === 'discover' || asked === 'requests' || asked === 'friends' ? asked
    : incoming.length > 0 ? 'requests' : friends && friends.length === 0 ? 'discover' : 'friends';
  const choose = (t: Tab) => setParams({ tab: t }, { replace: true });

  const loadFriends = useCallback(async () => {
    try { setFriends(await rpc<FriendRow[]>('list_friends')); } catch (e) { showToast(errorMessage(e)); setFriends((f) => f ?? []); }
  }, [showToast]);
  const loadBlocked = useCallback(async () => {
    try { setBlocked(await rpc<BlockedRow[]>('my_blocked_users')); } catch { /* only used to label search results */ }
  }, []);
  // Any change to requests (accepted on another device, the other side removing us…) and
  // returning to the app re-read the list; friendships themselves are not streamed.
  useEffect(() => { void loadFriends(); }, [requests, loadFriends]);
  useEffect(() => { void loadBlocked(); }, [loadBlocked]);
  useEffect(() => {
    const onVisible = () => { if (document.visibilityState === 'visible') void loadFriends(); };
    document.addEventListener('visibilitychange', onVisible);
    return () => document.removeEventListener('visibilitychange', onVisible);
  }, [loadFriends]);

  // Only the newest search may update the list (out-of-order responses are dropped).
  const search = useCallback(async (q: string) => {
    const seq = ++searchSeq.current;
    setSearching(true);
    try {
      const rows = await rpc<SearchResult[]>('search_users', { p_query: q });
      if (seq === searchSeq.current) { setResults(rows); setSearchError(null); }
    } catch (e) { if (seq === searchSeq.current) setSearchError(errorMessage(e)); }
    finally { if (seq === searchSeq.current) setSearching(false); }
  }, []);

  // Debounced, server-rate-limited username search (min 3 chars; "@name" works too).
  useEffect(() => {
    const q = normalizeQuery(query);
    if (q.length < 3) { searchSeq.current++; setResults(null); setSearchError(null); setSearching(false); return; }
    const t = setTimeout(() => void search(q), 300);
    return () => clearTimeout(t);
  }, [query, search]);

  async function act(id: string, fn: () => Promise<unknown>, done: string) {
    if (busyId) return;
    setBusyId(id);
    try { await fn(); showToast(done); await Promise.all([reloadRequests(), loadFriends(), loadBlocked()]); }
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

  const q = normalizeQuery(query);
  // People *I* blocked never appear in search (by design); show them here, from my own
  // block list, so they can be unblocked. Someone who blocked me stays invisible.
  const blockedMatches = q.length >= 3 ? blocked.filter((b) => b.username.toLowerCase().includes(q)) : [];

  const TABS: Array<[Tab, string]> = [['discover', 'Discover'], ['requests', 'Requests'], ['friends', 'Friends']];

  return (
    <div className="screen people">
      <Header title="People" left={<Link to="/chats" className="icon-btn" aria-label="Back to chats"><Icon name="back" /></Link>} />
      <div className="people-tabs" role="tablist" aria-label="People">
        {TABS.map(([t, label]) => (
          <button key={t} role="tab" id={`people-tab-${t}`} aria-selected={tab === t} aria-controls={`people-panel-${t}`}
                  className="people-tab" onClick={() => choose(t)}>
            {label}
            {t === 'requests' && incoming.length > 0 && <span className="tab-count" aria-label={`${incoming.length} waiting`}>{incoming.length}</span>}
            {t === 'friends' && friends && friends.length > 0 && <span className="tab-count tab-count-quiet">{friends.length}</span>}
          </button>
        ))}
      </div>

      <div role="tabpanel" id={`people-panel-${tab}`} aria-labelledby={`people-tab-${tab}`} className="people-panel" key={tab}>
        {tab === 'discover' && (
          <>
            <div className="search">
              <Icon name="search" size={20} />
              <div className="field">
                <input type="search" aria-label="Search by username" placeholder="Search by username" value={query}
                       autoCapitalize="none" autoCorrect="off" spellCheck={false} enterKeyHint="search" onChange={(e) => setQuery(e.target.value)} />
              </div>
            </div>
            {searchError && <div style={{ marginTop: 12 }}><Banner>{searchError}</Banner></div>}
            {q.length < 3 ? (
              <div className="people-empty">
                <span className="people-empty-mark" aria-hidden="true"><Icon name="person-add" size={26} /></span>
                <strong>Find your people</strong>
                <span>Type at least 3 letters of a username. PULSE is invite-only, so everyone you find here was invited.</span>
              </div>
            ) : results === null || (searching && results.length === 0) ? <div className="center" style={{ minHeight: 100 }}><Spinner small /></div> : (
              results.length === 0 && blockedMatches.length === 0 ? <p className="people-note">No one found with that username.</p> : (
                <div className="list" data-testid="search-results">
                  {results.map((r) => (
                    <div key={r.id} className="list-item person-row" data-testid="person-result">
                      <Avatar name={r.display_name} />
                      <div className="grow">
                        <div className="list-title truncate">{r.display_name}</div>
                        <div className="list-sub"><span className="truncate">@{r.username}</span></div>
                        {r.relationship === 'friend' && <div className="list-meta list-meta-accent">✓ Friends</div>}
                      </div>
                      <div className="person-actions">
                        {r.relationship === 'none' && <Button className="btn btn-primary btn-sm" busy={busyId === r.id} aria-label={`Add @${r.username}`}
                          onClick={() => act(r.id, () => rpc('send_friend_request', { p_target: r.id }), 'Request sent')}>Add</Button>}
                        {r.relationship === 'request_sent' && <span className="state-pill">Requested</span>}
                        {r.relationship === 'request_received' && <Button className="btn btn-primary btn-sm" busy={busyId === r.id} aria-label={`Accept @${r.username}`}
                          onClick={() => act(r.id, () => rpc('send_friend_request', { p_target: r.id }), 'You are now friends')}>Accept</Button>}
                        {r.relationship === 'friend' &&
                          <Button className="btn btn-subtle btn-sm" aria-label={`Chat with @${r.username}`} onClick={() => openChat(r.id)}>Chat</Button>}
                        {r.relationship !== 'friend' && <button className="icon-btn" aria-label={`More options for ${r.username}`}
                          onClick={() => setMenuFor({ user_id: r.id, username: r.username, display_name: r.display_name })}>
                          <Icon name="more" size={18} /></button>}
                      </div>
                    </div>
                  ))}
                  {blockedMatches.map((b) => (
                    <div key={b.user_id} className="list-item person-row" data-testid="person-result">
                      <Avatar name={b.display_name} />
                      <div className="grow">
                        <div className="list-title truncate">{b.display_name}</div>
                        <div className="list-sub"><span className="truncate">@{b.username}</span></div>
                      </div>
                      <div className="person-actions">
                        <span className="state-pill state-pill-blocked">Blocked</span>
                        <Button className="btn btn-ghost btn-sm" busy={busyId === b.user_id} aria-label={`Unblock @${b.username}`}
                          onClick={() => act(b.user_id, () => rpc('unblock_user', { p_target: b.user_id }), `Unblocked @${b.username}`)}>Unblock</Button>
                      </div>
                    </div>
                  ))}
                </div>
              )
            )}
          </>
        )}

        {tab === 'requests' && (
          <>
            <h2 className="section-title">Waiting for you{incoming.length ? ` · ${incoming.length}` : ''}</h2>
            {incoming.length === 0 ? <p className="people-note">No requests right now.</p> : (
              <div className="list">
                {incoming.map((r) => (
                  <div key={r.id} className="request-card" data-testid="incoming-request">
                    <div className="row" style={{ gap: 12, minWidth: 0 }}>
                      <Avatar name={r.display_name} />
                      <div className="grow" style={{ minWidth: 0 }}>
                        <div className="list-title truncate">{r.display_name}</div>
                        <div className="list-sub"><span className="truncate">@{r.username}</span></div>
                        <div className="list-meta">{relativeTime(r.created_at)}</div>
                      </div>
                      <button className="icon-btn" aria-label={`More options for ${r.username}`}
                        onClick={() => setMenuFor({ user_id: r.user_id, username: r.username, display_name: r.display_name })}>
                        <Icon name="more" size={18} />
                      </button>
                    </div>
                    <div className="request-actions">
                      <Button className="btn btn-primary btn-sm" busy={busyId === r.id} aria-label={`Accept @${r.username}`}
                        onClick={() => act(r.id, () => rpc('respond_friend_request', { p_request: r.id, p_accept: true }), 'Friend added')}>Accept</Button>
                      <Button className="btn btn-ghost btn-sm" disabled={busyId === r.id} aria-label={`Decline ${r.username}`}
                        onClick={() => act(r.id, () => rpc('respond_friend_request', { p_request: r.id, p_accept: false }), 'Declined')}>Decline</Button>
                    </div>
                  </div>
                ))}
              </div>
            )}
            <h2 className="section-title">Sent{outgoing.length ? ` · ${outgoing.length}` : ''}</h2>
            {outgoing.length === 0 ? <p className="people-note">Requests you send show up here until they're answered.</p> : (
              <div className="list">
                {outgoing.map((r) => (
                  <div key={r.id} className="list-item person-row" data-testid="outgoing-request">
                    <Avatar name={r.display_name} size={40} />
                    <div className="grow">
                      <div className="list-title truncate">{r.display_name}</div>
                      <div className="list-sub"><span className="truncate">@{r.username}</span></div>
                      <div className="list-meta">Sent {relativeTime(r.created_at)}</div>
                    </div>
                    <div className="person-actions">
                      <Button className="btn btn-ghost btn-sm" busy={busyId === r.id} aria-label={`Cancel request to @${r.username}`}
                        onClick={() => act(r.id, () => rpc('cancel_friend_request', { p_request: r.id }), 'Request cancelled')}>Cancel</Button>
                    </div>
                  </div>
                ))}
              </div>
            )}
          </>
        )}

        {tab === 'friends' && (
          friends === null ? <div className="center" style={{ minHeight: 120 }}><Spinner /></div> :
          friends.length === 0 ? (
            <div className="people-empty">
              <span className="people-empty-mark" aria-hidden="true"><Icon name="friends" size={26} /></span>
              <strong>No friends yet</strong>
              <span>Find the people who invited you, or who you invited, by their username.</span>
              <Button className="btn btn-primary btn-sm" onClick={() => choose('discover')}>Discover people</Button>
            </div>
          ) : (
            <div className="list">
              {friends.map((f) => {
                const name = f.nickname ?? f.display_name;
                return (
                  <div key={f.user_id} className="list-item person-row" data-testid="friend-row">
                    <button className="row grow person-open" aria-label={`Chat with ${name}`} onClick={() => openChat(f.user_id)}>
                      <Avatar name={name} online={f.online} />
                      <span className="grow">
                        <span className="list-title title-row" style={{ color: f.nickname_color ?? undefined }}><span className="truncate">{name}</span><StreakBadge streak={streaks.get(f.user_id)} /></span>
                        <span className="list-sub"><span className="truncate">@{f.username}</span></span>
                        {(f.online || f.last_active_at) && <span className="list-meta">{f.online ? 'Online' : `Active ${relativeTime(f.last_active_at)}`}</span>}
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
          )
        )}
      </div>

      {menuFor && <PersonMenu person={menuFor} streak={streaks.get(menuFor.user_id)} onChat={menuFor.friend ? () => { setMenuFor(null); void openChat(menuFor.user_id); } : undefined}
        onClose={() => setMenuFor(null)} onDone={async (msg) => {
        setMenuFor(null); showToast(msg); await Promise.all([loadFriends(), reloadRequests(), reloadChats(), loadBlocked()]); }} />}
      {toast}
    </div>
  );
}

const REPORT_REASONS: Array<[string, string]> = [
  ['harassment', 'Harassment or bullying'], ['spam', 'Spam'], ['impersonation', 'Pretending to be someone'],
  ['hate', 'Hate speech'], ['sexual_content', 'Sexual content'], ['violence', 'Violence or threats'],
  ['self_harm', 'Self-harm concern'], ['underage', 'May be under age'], ['other', 'Something else'],
];

function PersonMenu({ person, streak, onChat, onClose, onDone }:
  { person: Person; streak?: Streak; onChat?: () => void; onClose: () => void; onDone: (msg: string) => void }) {
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
          <div className="person-card">
            <Avatar name={friend?.nickname ?? person.display_name} size={64} />
            <div className="person-card-name">{friend?.nickname ?? person.display_name}<StreakBadge streak={streak} /></div>
            <div className="muted small">@{person.username}{friend?.nickname ? ` · ${person.display_name}` : ''}</div>
            {friend && <div className="muted small">{friend.online ? 'Online now' : friend.last_active_at ? `Active ${relativeTime(friend.last_active_at)}` : 'Friends'}</div>}
          </div>
          {onChat && <button className="sheet-item" onClick={onChat}>Open chat</button>}
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
