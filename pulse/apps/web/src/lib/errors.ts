/**
 * Maps the machine-readable codes raised by private.fail() (and common Supabase Auth
 * errors) to plain-language messages. Unknown codes fall back to a generic message.
 */
const MESSAGES: Record<string, string> = {
  // accounts
  invalid_username: 'Usernames are 3–20 characters: letters, numbers, dots and underscores, starting and ending with a letter or number.',
  username_reserved: 'That username is reserved. Please pick another.',
  username_taken: 'That username is taken.',
  username_cooldown: 'You can change your username once every 48 hours.',
  registration_closed: 'PULSE is full right now (free-tier capacity). Please try again later.',
  account_not_active: 'This account is not active.',
  no_profile: 'Your profile could not be found.',
  not_authenticated: 'Please sign in again.',
  reauthentication_required: 'For your safety, sign in again before doing this.',
  mfa_required: 'Enter your two-step verification code to continue.',
  owner_account_protected: 'The owner account cannot be deleted from the app.',
  // social
  query_too_short: 'Type at least 3 characters.',
  already_friends: 'You are already friends.',
  request_exists: 'A friend request is already pending.',
  request_not_found: 'That request no longer exists.',
  request_not_pending: 'That request was already answered.',
  invalid_target: 'You can’t do that to yourself.',
  user_not_found: 'User not found.',
  not_allowed: 'This action isn’t available.',
  not_friends: 'You can only do this with friends.',
  // messaging
  empty_message: 'Message is empty.',
  not_a_member: 'You are not in this chat.',
  edit_window_closed: 'Messages can only be edited for 15 minutes.',
  message_not_found: 'That message is no longer available.',
  not_editable: 'Only text messages can be edited.',
  max_three_pins: 'You can pin up to 3 chats.',
  group_too_large: 'Groups can have up to 32 members.',
  group_needs_members: 'Add at least one friend.',
  reply_target_unavailable: 'The message you replied to is gone.',
  transfer_ownership_first: 'Transfer ownership before leaving.',
  // limits
  rate_limited: 'Slow down a little and try again in a minute.',
  storage_pool_full: 'Storage is full on the free plan right now.',
  memories_quota_full: 'Your backup space is full.',
  egress_budget_exhausted: 'Daily media limit reached. Media will be back tomorrow.',
  media_too_large: 'That file is too large.',
  media_too_long: 'That clip is too long.',
  // Supabase Auth
  'Invalid login credentials': 'Wrong email or password.',
  'Email not confirmed': 'Please confirm your email first. Check your inbox.',
  'User already registered': 'An account with that email already exists.',
  over_email_send_rate_limit: 'Too many emails requested. Wait a moment and try again.',
  weak_password: 'Choose a stronger password (at least 8 characters with letters and numbers).',
  same_password: 'The new password must be different.',
  // GoTrue sometimes hides the signup trigger's code behind this generic message.
  'Database error saving new user': 'That username is taken or unavailable. Please try another.',
};

export function errorMessage(err: unknown): string {
  if (!err) return 'Something went wrong.';
  const e = err as { message?: string; code?: string; error_code?: string };
  if (typeof navigator !== 'undefined' && navigator.onLine === false) return 'You appear to be offline.';
  for (const key of [e.message, e.code, e.error_code]) {
    if (key && MESSAGES[key]) return MESSAGES[key];
  }
  if (e.message?.startsWith('Password should')) return MESSAGES.weak_password!;
  if ((typeof navigator !== 'undefined' && navigator.onLine === false)
      || /Failed to fetch|NetworkError|Load failed|fetch failed/i.test(e.message ?? '')) {
    return 'You appear to be offline.';
  }
  return 'Something went wrong. Please try again.';
}
