import { createContext, useCallback, useContext, useEffect, useMemo, useRef, useState, type ReactNode } from 'react';
import type { RealtimeChannel } from '@supabase/supabase-js';
import { rpc, supabase } from './supabase';
import { errorMessage } from './errors';
import { useAuth } from './auth';
import type { ChatListItem } from './types';

export interface RequestRow {
  id: string; direction: 'incoming' | 'outgoing'; user_id: string; username: string; display_name: string; created_at: string;
}

interface Live {
  chats: ChatListItem[] | null;
  chatsError: string | null;
  reloadChats: () => Promise<void>;
  requests: RequestRow[];
  reloadRequests: () => Promise<void>;
}

const LiveContext = createContext<Live | null>(null);

/**
 * One set of Realtime subscriptions per tab (mounted by the Shell), shared by the chat
 * list, the friends screen and the nav badges. Every subscription is filtered so the
 * server only RLS-checks changes that concern this user:
 *  - conversations UPDATE for the user's own chats (last_message_at moves on each send),
 *  - the user's own conversation_members rows (new chats, pins, mutes, leaving),
 *  - read receipts for messages the user sent ("Opened"),
 *  - Snap view state changes for Snaps the user sent or received,
 *  - friend requests sent to or by the user.
 * Lists are re-read after any reconnect and when the app returns to the foreground, so a
 * missed event never leaves them stale.
 */
export function LiveProvider({ children }: { children: ReactNode }) {
  const { profile } = useAuth();
  const me = profile?.id;
  const [chats, setChats] = useState<ChatListItem[] | null>(null);
  const [chatsError, setChatsError] = useState<string | null>(null);
  const [requests, setRequests] = useState<RequestRow[]>([]);
  const timer = useRef<ReturnType<typeof setTimeout> | null>(null);

  const reloadChats = useCallback(async () => {
    try { setChats(await rpc<ChatListItem[]>('chat_list')); setChatsError(null); }
    catch (e) { setChatsError(errorMessage(e)); setChats((x) => x ?? []); }
  }, []);
  const reloadRequests = useCallback(async () => {
    try { setRequests(await rpc<RequestRow[]>('my_friend_requests')); } catch { /* shown on the Friends screen */ }
  }, []);
  const soon = useCallback(() => {
    if (timer.current) clearTimeout(timer.current);
    timer.current = setTimeout(() => void reloadChats(), 400);
  }, [reloadChats]);

  // Conversation ids, as a stable key: resubscribe only when the set of chats changes.
  const convKey = useMemo(() => (chats ?? []).map((c) => c.conversation_id).sort().join(','), [chats]);

  useEffect(() => {
    if (!me) return;
    void reloadChats(); void reloadRequests();
    const onVisible = () => { if (document.visibilityState === 'visible') { soon(); void reloadRequests(); } };
    document.addEventListener('visibilitychange', onVisible);
    window.addEventListener('online', onVisible);
    return () => {
      document.removeEventListener('visibilitychange', onVisible);
      window.removeEventListener('online', onVisible);
      if (timer.current) clearTimeout(timer.current);
    };
  }, [me, reloadChats, reloadRequests, soon]);

  useEffect(() => {
    if (!me) return;
    const ch = supabase.channel(`live:${me}:${crypto.randomUUID()}`)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'conversation_members', filter: `user_id=eq.${me}` }, soon)
      .on('postgres_changes', { event: 'INSERT', schema: 'public', table: 'message_reads', filter: `sender_id=eq.${me}` }, soon)
      .on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'snap_recipients', filter: `sender_id=eq.${me}` }, soon)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'snap_recipients', filter: `recipient_id=eq.${me}` }, soon)
      .on('postgres_changes', { event: '*', schema: 'public', table: 'friend_requests', filter: `recipient_id=eq.${me}` },
          () => { void reloadRequests(); })
      .on('postgres_changes', { event: '*', schema: 'public', table: 'friend_requests', filter: `sender_id=eq.${me}` },
          () => { void reloadRequests(); });
    // Realtime "in" filters take up to 100 values; chunk for larger chat lists.
    const ids = convKey ? convKey.split(',') : [];
    for (let i = 0; i < ids.length; i += 100) {
      ch.on('postgres_changes', { event: 'UPDATE', schema: 'public', table: 'conversations',
        filter: `id=in.(${ids.slice(i, i + 100).join(',')})` }, soon);
    }
    let first = true;
    (ch as RealtimeChannel).subscribe((status) => {
      if (status !== 'SUBSCRIBED') return;
      // Catch up on anything missed while (re)connecting.
      if (!first) { soon(); void reloadRequests(); }
      first = false;
    });
    return () => { void supabase.removeChannel(ch); };
  }, [me, convKey, soon, reloadRequests]);

  const value = useMemo<Live>(() => ({ chats, chatsError, reloadChats, requests, reloadRequests }),
    [chats, chatsError, reloadChats, requests, reloadRequests]);
  return <LiveContext.Provider value={value}>{children}</LiveContext.Provider>;
}

export function useLive(): Live {
  const ctx = useContext(LiveContext);
  if (!ctx) throw new Error('useLive outside LiveProvider');
  return ctx;
}

export function useChatList() {
  const { chats, chatsError, reloadChats } = useLive();
  return { items: chats, error: chatsError, reload: reloadChats };
}

export function useFriendRequests() {
  const { requests, reloadRequests } = useLive();
  return { requests, reload: reloadRequests };
}
