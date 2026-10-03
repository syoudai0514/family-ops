-- Which Gemini model reads LINE messages, switchable without a redeploy.
--
-- Owner decision 2026-10-04: use Gemini 3.5 Flash (same free-tier limit as 3.1 Flash-Lite,
-- better at reading context). The model was only an Edge Function secret, which needs
-- the dashboard to change. It is now a setting next to understand_enabled: null means
-- "use the environment" (unchanged behaviour); a valid id overrides it at the next
-- message, and setting it back to null is the rollback.

alter table private.line_ai_settings
  add column if not exists understand_model text
  check (understand_model is null or understand_model ~ '^gemini-[a-z0-9.-]{1,60}$');

create or replace function public.server_read_line_understand_model()
returns text
language sql
stable
security invoker
set search_path = ''
as $$
  select (select s.understand_model from private.line_ai_settings s where s.id);
$$;
revoke all on function public.server_read_line_understand_model() from public, anon, authenticated;
grant execute on function public.server_read_line_understand_model() to service_role;
