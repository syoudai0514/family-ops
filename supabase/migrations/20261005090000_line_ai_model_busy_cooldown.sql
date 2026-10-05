-- A busy LINE understanding model steps aside for ten minutes.
--
-- 2026-10-05: Gemini 3.5 Flash answered 503 after ~20 s and then took ~23 s on the
-- retry, so a LINE reply took 49 s; during the investigation it timed out on 6 of 6
-- calls while 3.1 Flash-Lite answered in 2-4 s. The worker now cuts each attempt at
-- 12 s and retries on the environment model. When the configured model fails that way
-- it is marked busy, and for the next ten minutes the setting reads as null (= the
-- environment model) so later messages do not wait on it again. Nothing else changes:
-- the configured model comes back on its own when the cooldown ends.

alter table private.line_ai_settings
  add column if not exists understand_model_busy_until timestamptz;

create or replace function public.server_read_line_understand_model()
returns text
language sql
stable
security invoker
set search_path = ''
as $$
  select (
    select s.understand_model
    from private.line_ai_settings s
    where s.id
      and (s.understand_model_busy_until is null or s.understand_model_busy_until <= now())
  );
$$;
revoke all on function public.server_read_line_understand_model() from public, anon, authenticated;
grant execute on function public.server_read_line_understand_model() to service_role;

create or replace function public.server_tx_mark_line_understand_model_busy(p_model text)
returns boolean
language plpgsql
security definer
set search_path = ''
as $$
declare
  marked integer;
begin
  update private.line_ai_settings s
     set understand_model_busy_until = now() + interval '10 minutes'
   where s.id
     and s.understand_model = p_model;
  get diagnostics marked = row_count;
  return marked > 0;
end;
$$;
revoke all on function public.server_tx_mark_line_understand_model_busy(text) from public, anon, authenticated;
grant execute on function public.server_tx_mark_line_understand_model_busy(text) to service_role;
