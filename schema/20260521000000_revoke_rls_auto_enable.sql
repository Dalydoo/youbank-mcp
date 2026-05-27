-- Audit §2.2: rls_auto_enable() is a SECURITY DEFINER event-trigger helper.
-- It returns 0 rows from pg_event_trigger_ddl_commands() outside an event-trigger
-- context, so direct RPC invocation does nothing useful — but Supabase's
-- security advisor still flags the anon-callable SECURITY DEFINER surface.
-- Revoke from PUBLIC + anon + authenticated; postgres + service_role retain
-- EXECUTE so the event trigger still fires on CREATE TABLE statements.

REVOKE ALL ON FUNCTION public.rls_auto_enable() FROM PUBLIC, anon, authenticated;
