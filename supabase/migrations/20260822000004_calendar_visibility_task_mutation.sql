-- Calendar visibility is independent from a task category.  This wrapper
-- keeps the existing create-task mutation contract intact for older clients
-- while allowing new clients to opt a one-off special into the Google mirror.

create or replace function public.server_tx_create_task_with_calendar(
  p_actor_id uuid,
  p_operation_id uuid,
  p_title text,
  p_category text,
  p_scheduled_date date,
  p_due_local_time time,
  p_calendar_end_local_time time,
  p_calendar_visibility text,
  p_planned_assignee_user_id uuid,
  p_completion_mode text,
  p_routine_phase text,
  p_subtasks jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_result jsonb;
  v_task_id uuid;
  v_due_at timestamptz;
  v_ends_at timestamptz;
  v_visibility text := coalesce(p_calendar_visibility, 'hidden');
begin
  if v_visibility not in ('special', 'hidden') then raise exception 'INVALID_INPUT'; end if;
  if p_calendar_end_local_time is not null and p_due_local_time is null then raise exception 'INVALID_INPUT'; end if;
  if p_calendar_end_local_time is not null and p_calendar_end_local_time <= p_due_local_time then raise exception 'INVALID_INPUT'; end if;

  v_result := public.server_tx_create_task(
    p_actor_id, p_operation_id, p_title, p_category, p_scheduled_date,
    p_due_local_time, p_planned_assignee_user_id, p_completion_mode,
    p_routine_phase, p_subtasks
  );
  v_task_id := (v_result->>'task_id')::uuid;
  if p_due_local_time is not null then
    v_due_at := (p_scheduled_date::text || ' ' || p_due_local_time::text)::timestamp at time zone 'Asia/Tokyo';
  end if;
  if p_calendar_end_local_time is not null then
    v_ends_at := (p_scheduled_date::text || ' ' || p_calendar_end_local_time::text)::timestamp at time zone 'Asia/Tokyo';
  end if;
  update public.task_instances
  set calendar_visibility = case when coalesce(p_routine_phase, 'anytime') in ('morning', 'evening') then 'hidden' else v_visibility end,
      calendar_ends_at = v_ends_at,
      due_at = v_due_at
  where id = v_task_id and household_id = (
    select household_id from public.household_members where user_id = p_actor_id
  );
  return v_result;
end;
$$;

revoke all on function public.server_tx_create_task_with_calendar(uuid, uuid, text, text, date, time, time, text, uuid, text, text, jsonb) from public, anon, authenticated;
grant execute on function public.server_tx_create_task_with_calendar(uuid, uuid, text, text, date, time, time, text, uuid, text, text, jsonb) to service_role;
