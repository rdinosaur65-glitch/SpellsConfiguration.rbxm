-- PULSE 0009 — final privilege lockdown. Runs last and is safe to re-run.
--
-- Postgres grants EXECUTE on new functions to PUBLIC, and per-schema default
-- privileges cannot remove that. Supabase additionally grants anon/authenticated
-- EXECUTE on functions in "public" by default. So every function is first closed,
-- then the intended surface is re-opened explicitly.

alter default privileges revoke execute on functions from public;

revoke execute on all functions in schema public from public, anon, authenticated;
revoke execute on all functions in schema private from public, anon, authenticated;

-- Private helpers that RLS policies call while running as "authenticated".
-- (Not reachable through the Data API: the private schema is not exposed.)
grant execute on function
  private.is_owner(uuid), private.are_friends(uuid, uuid), private.is_blocked_either(uuid, uuid),
  private.is_member(uuid, uuid), private.can_read_message(uuid, uuid),
  private.message_content_visible(uuid), private.direct_blocked(uuid),
  private.is_snap_recipient(uuid, uuid), private.is_snap_sender(uuid, uuid),
  private.can_use_topic(text), private.try_uuid(text)
  to authenticated;

-- Public RPC surface for signed-in users. Every function re-checks auth.uid(),
-- account state, relationships and quotas internally.
grant execute on function
  public.am_i_owner(),
  public.change_username(text), public.touch_presence(),
  public.search_users(text), public.send_friend_request(uuid),
  public.respond_friend_request(uuid, boolean), public.cancel_friend_request(uuid),
  public.remove_friend(uuid), public.block_user(uuid), public.unblock_user(uuid),
  public.get_friend_presence(),
  public.authorize_upload(public.media_purpose, text, bigint, text, numeric, integer, integer),
  public.confirm_upload(uuid), public.delete_media_asset(uuid), public.my_storage_usage(),
  public.create_direct_conversation(uuid), public.create_group(text, uuid[]),
  public.add_group_members(uuid, uuid[]), public.remove_group_member(uuid, uuid),
  public.set_group_role(uuid, uuid, public.member_role), public.transfer_group_ownership(uuid, uuid),
  public.leave_group(uuid), public.update_group(uuid, text, text, jsonb),
  public.set_chat_expiry(uuid, public.expiry_mode),
  public.send_message(uuid, public.message_kind, text, uuid, uuid, uuid),
  public.edit_message(uuid, text), public.delete_message(uuid),
  public.mark_conversation_read(uuid), public.toggle_reaction(uuid, text),
  public.set_message_saved(uuid, boolean), public.set_pin(uuid, smallint),
  public.set_mute(uuid, timestamptz), public.chat_list(), public.conversation_participants(uuid),
  public.search_messages(text, uuid, timestamptz, timestamptz, boolean, public.message_kind[], uuid, integer),
  public.conversation_gallery(uuid, text),
  public.send_snap(uuid, uuid[], uuid[], smallint, boolean, uuid), public.open_snap(uuid),
  public.close_snap_view(uuid, uuid), public.authorize_snap_media(uuid, uuid),
  public.save_snap(uuid, uuid), public.authorize_media_access(uuid),
  public.report_user(uuid, public.report_reason, text),
  public.report_message(uuid, public.report_reason, text),
  public.report_group(uuid, public.report_reason, text),
  public.admin_search_users(text), public.admin_list_reports(public.report_status),
  public.admin_resolve_report(uuid, public.report_status, text),
  public.admin_set_account_state(uuid, public.account_state, text),
  public.admin_usage_summary(), public.admin_audit_log(integer),
  public.my_sessions(), public.revoke_session(uuid), public.revoke_other_sessions(),
  public.request_account_deletion()
  to authenticated;

-- Service-role only (Edge Functions holding the service key).
grant execute on function public.janitor_claim_deletions(integer), public.janitor_mark_deleted(uuid[])
  to service_role;
