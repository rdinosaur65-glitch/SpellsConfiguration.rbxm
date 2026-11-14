-- PULSE 0012 — publish conversation changes (expiry mode, group name) to members.
-- Found by e2e: a channel that listens to a table missing from the publication is
-- rejected as a whole by Realtime, which silently stopped live messages in the chat.
-- RLS (conv_member) limits delivery to current members.
do $$
begin
  if exists (select 1 from pg_publication where pubname = 'supabase_realtime')
     and not exists (select 1 from pg_publication_tables
                     where pubname = 'supabase_realtime' and schemaname = 'public' and tablename = 'conversations') then
    alter publication supabase_realtime add table public.conversations;
  end if;
end $$;
