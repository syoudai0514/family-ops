-- Owner instruction 2026-09-30: LINE free text must reach the AI WITH the
-- conversation, not one message at a time.
--
-- Live 2026-09-30 22:27-22:29: "買うものは？" -> the AI asked which shopping list;
-- "おれ" (the answer to that question) -> "「おれ」について、何かお困りごとや相談したい
-- ことがありますか？"; "いや、買うべきもの教えてよ" -> "「さきほどの入力」は取り消し済みです".
-- Each message was judged alone. The bot's own replies were never stored anywhere,
-- so even a context-aware model could not have known what "おれ" answered.
--
-- private.line_conversation_turns keeps the last few turns (the user's messages and
-- the bot's replies) per person so the router can be given them. It is short-lived
-- on purpose: rows older than 3 days are deleted whenever a new turn is written,
-- and at most 60 rows are kept per person.

create table if not exists private.line_conversation_turns (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null,
  actor_id uuid not null,
  role text not null check (role in ('user', 'assistant')),
  text text not null check (char_length(text) between 1 and 2000),
  -- clock_timestamp(), not now(): turns written in one transaction must still keep their order.
  created_at timestamptz not null default clock_timestamp()
);
create index if not exists line_conversation_turns_actor_created_idx
  on private.line_conversation_turns (actor_id, created_at desc);

create or replace function public.server_tx_log_line_turn(
  p_actor_id uuid,
  p_role text,
  p_text text
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_text text := left(btrim(coalesce(p_text, '')), 2000);
begin
  if p_actor_id is null or p_role not in ('user', 'assistant') or v_text = '' then
    raise exception 'INVALID_INPUT';
  end if;
  select m.household_id into v_household_id
  from public.household_members m where m.user_id = p_actor_id and m.member_role = 'adult';
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;

  insert into private.line_conversation_turns(household_id, actor_id, role, text)
  values (v_household_id, p_actor_id, p_role, v_text);

  -- Short retention: 3 days, and never more than the latest 60 turns per person.
  delete from private.line_conversation_turns
  where actor_id = p_actor_id
    and (
      created_at < now() - interval '3 days'
      or id in (
        select t.id from private.line_conversation_turns t
        where t.actor_id = p_actor_id
        order by t.created_at desc, t.id desc
        offset 60
      )
    );
end;
$$;
revoke all on function public.server_tx_log_line_turn(uuid, text, text) from public, anon, authenticated;
grant execute on function public.server_tx_log_line_turn(uuid, text, text) to service_role;

-- The recent conversation, oldest first: [{"role":"user","text":"...","at":"..."}].
create or replace function public.server_read_line_turns(
  p_actor_id uuid,
  p_limit integer default 10,
  p_within interval default interval '3 hours'
) returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object('role', x.role, 'text', x.text, 'at', x.created_at) order by x.created_at, x.id), '[]'::jsonb)
  from (
    select t.id, t.role, t.text, t.created_at
    from private.line_conversation_turns t
    where t.actor_id = p_actor_id
      and t.created_at >= now() - least(p_within, interval '3 days')
    order by t.created_at desc, t.id desc
    limit greatest(1, least(coalesce(p_limit, 10), 30))
  ) x;
$$;
revoke all on function public.server_read_line_turns(uuid, integer, interval) from public, anon, authenticated;
grant execute on function public.server_read_line_turns(uuid, integer, interval) to service_role;

-- On/off switch for "AI understands first" (lineUnderstand.ts). Off until the prompt has
-- been checked against the real model in production (the evaluation endpoint in
-- process-line-inbox); then switched on with one UPDATE, and off again the same way if
-- it ever misbehaves -- no redeploy either way.
create table if not exists private.line_ai_settings (
  id boolean primary key default true check (id),
  understand_enabled boolean not null default false,
  updated_at timestamptz not null default now()
);
insert into private.line_ai_settings(id) values (true) on conflict (id) do nothing;

create or replace function public.server_read_line_understand_enabled()
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce((select s.understand_enabled from private.line_ai_settings s where s.id), false);
$$;
revoke all on function public.server_read_line_understand_enabled() from public, anon, authenticated;
grant execute on function public.server_read_line_understand_enabled() to service_role;
