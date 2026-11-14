export type AccountState = 'active' | 'suspended' | 'banned' | 'deleting';

export interface Profile {
  id: string;
  username: string;
  display_name: string;
  bio: string | null;
  status_text: string | null;
  account_state: AccountState;
  username_changed_at: string | null;
  created_at: string;
  avatar_asset_id?: string | null;
}

export interface Appearance {
  mode: 'dark' | 'light' | 'system';
  accent: string;
  font: 'system' | 'rounded' | 'serif' | 'mono';
  bubbles: 'rounded' | 'square';
  reduce_motion: boolean;
}

export interface UserSettings {
  user_id: string;
  appearance: Appearance;
  ghost_mode: boolean;
  show_online: boolean;
  show_last_active: boolean;
  show_typing: boolean;
  show_recording: boolean;
  data_saver: boolean;
  notifications: Record<string, boolean>;
}

export interface ChatListItem {
  conversation_id: string;
  kind: 'direct' | 'group';
  title: string | null;
  other_user_id: string | null;
  title_color: string | null;
  label: 'Start chatting' | 'New Chat' | 'New Snap' | 'Received' | 'Opened' | 'Delivered';
  unread: boolean;
  last_activity: string;
  pinned_rank: number | null;
  muted: boolean;
}

export interface Message {
  id: string;
  conversation_id: string;
  sender_id: string;
  kind: 'text' | 'photo' | 'video' | 'voice' | 'snap' | 'system';
  body: string | null;
  reply_to_id: string | null;
  client_msg_id: string;
  created_at: string;
  edited_at: string | null;
  deleted_at: string | null;
  expires_at: string | null;
}

export interface Participant {
  user_id: string;
  username: string;
  display_name: string;
  nickname: string | null;
  nickname_color: string | null;
  role: 'owner' | 'admin' | 'member';
}

export interface SearchResult {
  id: string;
  username: string;
  display_name: string;
  relationship: 'friend' | 'request_sent' | 'request_received' | 'none';
}

export interface FriendRequest {
  id: string;
  sender_id: string;
  recipient_id: string;
  status: 'pending' | 'accepted' | 'declined' | 'cancelled';
  created_at: string;
}
