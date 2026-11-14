-- PULSE 0011 — found by end-to-end tests on a real Supabase stack.
-- PostgREST runs STABLE/IMMUTABLE functions in a READ ONLY transaction. search_users()
-- and search_messages() were declared STABLE but write to private.rate_limits through
-- rate_limit_hit(), so every call through the API failed ("cannot execute INSERT in a
-- read-only transaction"). Direct SQL tests did not use read-only transactions, so they
-- passed. Both functions are now VOLATILE; test 80 guards against regressions.
alter function public.search_users(text) volatile;
alter function public.search_messages(text, uuid, timestamptz, timestamptz, boolean,
                                      public.message_kind[], uuid, integer) volatile;
