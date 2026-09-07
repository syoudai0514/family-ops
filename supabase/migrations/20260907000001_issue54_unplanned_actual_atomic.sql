-- Issue #54: an unplanned actual is one canonical task occurrence that is
-- created and completed in the same PostgreSQL transaction. scheduled_date is
-- the user-selected business/actual date; completed_at remains audit time.
-- Reuse the existing create/complete commands so canonical participant/event
-- semantics and receipt idempotency do not fork.

create or replace function public.server_tx_record_unplanned_actual(
  p_actor_id uuid,
  p_operation_id uuid,
  p_title text,
  p_scheduled_date date
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_create_result jsonb;
  v_task_id uuid;
  v_complete_operation_id uuid;
  v_task public.task_instances%rowtype;
begin
  if p_actor_id is null or p_operation_id is null or p_scheduled_date is null
     or coalesce(btrim(p_title), '') = '' then
    raise exception 'INVALID_INPUT';
  end if;

  -- The outer operation id is consumed by create-task. Completion needs a
  -- different, deterministic id so retrying this wrapper replays both inner
  -- commands without creating a duplicate or leaving an open ToDo.
  v_complete_operation_id := md5(p_operation_id::text || ':unplanned-actual:complete')::uuid;

  v_create_result := public.server_tx_create_task_with_calendar(
    p_actor_id,
    p_operation_id,
    btrim(p_title),
    'todo',
    p_scheduled_date,
    null,
    null,
    'hidden',
    null,
    'whole',
    'anytime',
    null
  );
  v_task_id := (v_create_result->>'task_id')::uuid;
  if v_task_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  perform public.server_tx_complete_task(
    p_actor_id,
    v_complete_operation_id,
    v_task_id,
    'self',
    false,
    'pwa'
  );

  select * into v_task
  from public.task_instances
  where id = v_task_id
    and household_id = (select household_id from public.household_members where user_id = p_actor_id);

  if not found or v_task.status <> 'completed' or v_task.scheduled_date <> p_scheduled_date then
    raise exception 'INVALID_INPUT';
  end if;

  return jsonb_build_object(
    'task_id', v_task_id,
    'status', v_task.status,
    'scheduled_date', v_task.scheduled_date,
    'completed_at', v_task.completed_at
  );
end;
$$;

revoke all on function public.server_tx_record_unplanned_actual(uuid, uuid, text, date) from public, anon, authenticated;
grant execute on function public.server_tx_record_unplanned_actual(uuid, uuid, text, date) to service_role;
