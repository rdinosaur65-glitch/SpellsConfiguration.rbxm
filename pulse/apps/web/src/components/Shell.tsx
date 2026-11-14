import { Suspense, useEffect } from 'react';
import { NavLink, Outlet, useMatch } from 'react-router-dom';
import { useRegisterSW } from 'virtual:pwa-register/react';
import { Icon, Spinner } from './ui';
import { useOnline } from '../lib/useOnline';
import { LiveProvider, useChatList, useFriendRequests } from '../lib/live';
import { resyncPush } from '../lib/push';

export function Shell() {
  return <LiveProvider><ShellInner /></LiveProvider>;
}

function ShellInner() {
  const online = useOnline();
  useEffect(() => { void resyncPush(); }, []);   // re-attach this device's notifications to the new session
  const { items } = useChatList();
  const { requests } = useFriendRequests();
  const unread = (items ?? []).filter((c) => c.unread && !c.muted).length;
  const incoming = requests.filter((r) => r.direction === 'incoming').length;
  const { needRefresh: [needRefresh], updateServiceWorker } = useRegisterSW();
  // Conversations are full-screen: the composer takes the place of the tab bar.
  const chatMatch = useMatch('/chats/:id');
  const infoMatch = useMatch('/chats/:id/info');
  const inConversation = chatMatch !== null || infoMatch !== null;
  const peopleMatch = useMatch('/people') !== null;   // People belongs to Chats

  return (
    <div className="app">
      {!online && <div className="offline" role="status">Offline · messages send when you reconnect</div>}
      <Suspense fallback={<div className="center" style={{ flex: 1 }}><Spinner /></div>}><Outlet /></Suspense>
      {needRefresh && (
        <div className="update-bar" role="status">
          <span className="grow small">A new version of PULSE is ready.</span>
          <button className="btn btn-primary btn-sm" onClick={() => updateServiceWorker(true)}>Update</button>
        </div>
      )}
      {!inConversation && <nav className="nav" aria-label="Main">
        <div className="nav-inner">
          <NavLink to="/camera"><Icon name="camera" />Camera</NavLink>
          <NavLink to="/chats" className={({ isActive }) => (isActive || peopleMatch ? 'active' : undefined)}><Icon name="chat" />Chats
            {unread > 0 ? <span className="nav-badge" aria-label={`${unread} unread`}>{unread}</span>
              : incoming > 0 ? <span className="nav-dot" aria-label={`${incoming} friend request${incoming > 1 ? 's' : ''}`} /> : null}</NavLink>
          <NavLink to="/settings"><Icon name="settings" />Settings</NavLink>
        </div>
      </nav>}
    </div>
  );
}
