import { Suspense } from 'react';
import { NavLink, Outlet, useMatch } from 'react-router-dom';
import { useRegisterSW } from 'virtual:pwa-register/react';
import { Icon, Spinner } from './ui';
import { useOnline } from '../lib/useOnline';
import { LiveProvider, useChatList, useFriendRequests } from '../lib/live';

export function Shell() {
  return <LiveProvider><ShellInner /></LiveProvider>;
}

function ShellInner() {
  const online = useOnline();
  const { items } = useChatList();
  const { requests } = useFriendRequests();
  const unread = (items ?? []).filter((c) => c.unread && !c.muted).length;
  const incoming = requests.filter((r) => r.direction === 'incoming').length;
  const { needRefresh: [needRefresh], updateServiceWorker } = useRegisterSW();
  // Conversations are full-screen: the composer takes the place of the tab bar.
  const chatMatch = useMatch('/chats/:id');
  const infoMatch = useMatch('/chats/:id/info');
  const inConversation = chatMatch !== null || infoMatch !== null;

  return (
    <div className="app">
      {!online && <div className="offline" role="status">You're offline. Messages you send now go out when you reconnect, as long as PULSE stays open.</div>}
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
          <NavLink to="/chats"><Icon name="chat" />Chats{unread > 0 && <span className="nav-badge" aria-label={`${unread} unread`}>{unread}</span>}</NavLink>
          <NavLink to="/friends"><Icon name="friends" />Friends{incoming > 0 && <span className="nav-badge" aria-label={`${incoming} requests`}>{incoming}</span>}</NavLink>
          <NavLink to="/settings"><Icon name="settings" />Settings</NavLink>
        </div>
      </nav>}
    </div>
  );
}
