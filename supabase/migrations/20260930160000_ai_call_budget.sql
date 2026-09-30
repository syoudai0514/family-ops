-- A small budget for Gemini calls, so the free tier's per-minute limit is never hit.
--
-- Owner note 2026-09-30: the model in use (Gemini 3.1 Flash Lite, free tier) allows 15
-- requests per minute. Since "AI understands first" (lineUnderstand.ts) every free-text
-- LINE message makes at least one call, and a burst -- several messages in a row, a
-- draft that also needs the decomposition call, a nursery photo -- could exceed it; the
-- over-limit calls then fail (429) and the message falls back to the old path anyway.
--
-- server_tx_reserve_ai_call() counts calls per UTC minute and says no once the minute
-- is full (and once the day is full, counted from midnight Pacific time, when Google
-- resets the daily quota). The understanding step asks before every call and simply
-- uses the old path when told no. The default of 10 per minute leaves room for the
-- other AI features that do not ask yet.

create table if not exists private.ai_call_minutes (
  minute timestamptz primary key,
  calls integer not null default 0 check (calls >= 0)
);

create or replace function public.server_tx_reserve_ai_call(
  p_per_minute integer default 10,
  p_per_day integer default 900
) returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_minute timestamptz := date_trunc('minute', now());
  v_day_start timestamptz := date_trunc('day', now() at time zone 'America/Los_Angeles') at time zone 'America/Los_Angeles';
  v_day_calls integer;
  v_calls integer;
begin
  select coalesce(sum(m.calls), 0) into v_day_calls
  from private.ai_call_minutes m where m.minute >= v_day_start;
  if v_day_calls >= greatest(coalesce(p_per_day, 900), 1) then return false; end if;

  insert into private.ai_call_minutes as m (minute, calls) values (v_minute, 1)
  on conflict (minute) do update set calls = m.calls + 1
  where m.calls < greatest(coalesce(p_per_minute, 10), 1)
  returning m.calls into v_calls;
  if v_calls is null then return false; end if;

  delete from private.ai_call_minutes where minute < now() - interval '3 days';
  return true;
end;
$$;
revoke all on function public.server_tx_reserve_ai_call(integer, integer) from public, anon, authenticated;
grant execute on function public.server_tx_reserve_ai_call(integer, integer) to service_role;
