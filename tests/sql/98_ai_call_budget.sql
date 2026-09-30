-- Gemini free tier: 15 requests per minute. The shared budget says no before that.
\set ON_ERROR_STOP on

begin;
set role service_role;

do $$
declare
  n int := 0;
  i int;
begin
  delete from private.ai_call_minutes;
  for i in 1..12 loop
    if public.server_tx_reserve_ai_call() then n := n + 1; end if;
  end loop;
  if n <> 10 then raise exception 'FAIL ai-budget: default 10 per minute, got %', n; end if;
  if (select calls from private.ai_call_minutes where minute = date_trunc('minute', now())) <> 10 then
    raise exception 'FAIL ai-budget: refused calls must not be counted';
  end if;

  -- A new minute starts fresh; the daily cap still applies across minutes.
  update private.ai_call_minutes set minute = minute - interval '1 minute';
  if not public.server_tx_reserve_ai_call() then raise exception 'FAIL ai-budget: a new minute must allow calls'; end if;
  if public.server_tx_reserve_ai_call(10, 11) then raise exception 'FAIL ai-budget: the daily cap must hold'; end if;

  -- Old minutes are cleaned up.
  insert into private.ai_call_minutes(minute, calls) values (date_trunc('minute', now()) - interval '4 days', 3);
  perform public.server_tx_reserve_ai_call();
  if exists (select 1 from private.ai_call_minutes where minute < now() - interval '3 days') then
    raise exception 'FAIL ai-budget: minutes older than 3 days must be deleted';
  end if;
end $$;

rollback;
