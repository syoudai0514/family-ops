-- Owner report 2026-10-11: a one-off appointment entered as 予定 (LINE "10/17 9:00 詩乃の便秘通院",
-- confirmed with 種別: 予定) was stored as a hidden やること and never reached Google Calendar.
-- Saving it again in the PWA as 予定（Google Calendarにも同期） also reverted to hidden.
--
-- Cause: two BEFORE triggers forced calendar_visibility = 'hidden' for every task whose
-- routine_phase is morning/evening. That rule exists for the daily routine chores created from
-- task_definitions, but a 9:00 appointment is also classified into the morning band, so a manual
-- event lost its explicit 'special' flag on insert and on every edit.
--
-- Fix: the morning/evening rule applies only to tasks made from a routine definition. A manual
-- task keeps the visibility it was created or edited with; an explicit 'special' manual task is
-- the 'special' kind (mirrored to the family Google Calendar).

create or replace function private.fn_copy_task_calendar_visibility()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
begin
  if new.task_definition_id is not null then
    select calendar_visibility into new.calendar_visibility
    from public.task_definitions
    where household_id = new.household_id and id = new.task_definition_id;
    -- Transport definitions are intentionally morning/evening phased but are
    -- the one routine-shaped domain that must still mirror to Google.
    if new.routine_phase in ('morning', 'evening') and new.calendar_visibility <> 'transport' then
      new.calendar_visibility := 'hidden';
    end if;
  end if;
  return new;
end;
$$;

create or replace function private.fn_review_fix_task_instance_domain()
returns trigger
language plpgsql
security definer
set search_path to ''
as $$
declare v_kind text; v_visibility text;
begin
  -- A manually entered event keeps the user's explicit choice even in the morning/evening band.
  if new.task_definition_id is null and new.calendar_visibility = 'special' then
    new.task_kind := 'special';
    return new;
  end if;
  select task_kind, calendar_visibility into v_kind, v_visibility from public.task_definitions
    where household_id = new.household_id and id = new.task_definition_id;
  new.task_kind := coalesce(v_kind, private.family_ops_task_kind('', new.category, new.routine_phase, new.calendar_visibility));
  if new.task_kind in ('morning_preparation','morning_chore','evening_chore') then new.calendar_visibility := 'hidden';
  elsif new.task_kind = 'transport' then new.calendar_visibility := 'transport';
  elsif new.calendar_visibility is null then new.calendar_visibility := coalesce(v_visibility, 'hidden'); end if;
  return new;
end $$;

-- LINE: after confirming an event the reply says it goes to Google Calendar and offers
-- 「Googleに入れない」/「やっぱり入れる」. This sets the choice on the draft, and on the task once the
-- draft has been executed. Only the actor's own task_create_once draft can be changed.
create or replace function public.server_tx_set_line_pending_calendar_visibility(
  p_actor_id uuid,
  p_pending_action_id uuid,
  p_visibility text
) returns jsonb
language plpgsql
security invoker
set search_path to ''
as $$
declare
  v_household uuid;
  v_pending private.pending_actions%rowtype;
  v_task_id uuid;
begin
  if p_actor_id is null or p_pending_action_id is null or p_visibility not in ('hidden', 'special') then
    raise exception 'INVALID_INPUT';
  end if;
  select household_id into v_household from public.household_members where user_id = p_actor_id;
  if v_household is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;

  select * into v_pending from private.pending_actions
  where id = p_pending_action_id and household_id = v_household and actor_id = p_actor_id
  for update;
  if not found then raise exception 'NOT_FOUND'; end if;
  if v_pending.action_type <> 'task_create_once' then raise exception 'INVALID_INPUT'; end if;

  update private.pending_actions
  set normalized_payload = normalized_payload || jsonb_build_object('calendar_visibility', p_visibility),
      updated_at = now()
  where id = v_pending.id;

  if v_pending.result_type = 'task' and v_pending.result_id is not null then
    update public.task_instances
    set calendar_visibility = p_visibility, revision = revision + 1
    where household_id = v_household and id = v_pending.result_id and test_context_id is null
      and calendar_visibility is distinct from p_visibility
    returning id into v_task_id;
    return jsonb_build_object('applied', 'task', 'task_id', v_pending.result_id, 'visibility', p_visibility);
  end if;
  return jsonb_build_object('applied', 'draft', 'visibility', p_visibility);
end;
$$;

revoke all on function public.server_tx_set_line_pending_calendar_visibility(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.server_tx_set_line_pending_calendar_visibility(uuid, uuid, text) to service_role;
