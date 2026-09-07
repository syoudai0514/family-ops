-- Issue #54 final-v11 Check-in parity: expose the canonical task expectation
-- used by bulk reconciliation so the PWA can show the exact pre-mutation
-- required/normal target count and excluded optional (余力) count.
-- No mutation semantics change here: fn_command_reconcile_task_group_v1
-- remains the authority and already excludes expectation='optional'.

create or replace function public.server_tx_get_routine_session(
  p_actor_id uuid,
  p_session_id uuid
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_session record;
  v_items jsonb;
  v_current uuid;
begin
  if p_actor_id is null or p_session_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  select household_id into v_household_id
  from public.household_members
  where user_id = p_actor_id;
  if v_household_id is null then
    raise exception 'NOT_HOUSEHOLD_MEMBER';
  end if;

  select * into v_session
  from public.routine_checkin_sessions
  where household_id = v_household_id and id = p_session_id;
  if not found then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'task_instance_id', ti.id,
    'title', ti.title,
    'status', ti.status,
    'completion_mode', ti.completion_mode,
    'actual_completed_by_id', ti.actual_completed_by_id,
    'outcome_reason', ti.outcome_reason,
    'rescheduled_to', ti.rescheduled_to,
    'expectation', coalesce(ti.expectation, 'normal'),
    'revision', ti.revision,
    'display_order', si.display_order,
    'subtasks', (
      select coalesce(jsonb_agg(jsonb_build_object(
        'id', st.id,
        'title', st.title,
        'required', st.required,
        'is_completed', st.is_completed,
        'completed_by', st.completed_by
      ) order by st.sort_order), '[]'::jsonb)
      from public.task_subtask_instances st
      where st.household_id = v_household_id
        and st.task_instance_id = ti.id
    )
  ) order by si.display_order), '[]'::jsonb)
  into v_items
  from public.routine_checkin_session_items si
  join public.task_instances ti
    on ti.household_id = si.household_id and ti.id = si.task_instance_id
  where si.household_id = v_household_id
    and si.session_id = p_session_id;

  if v_session.status = 'superseded' then
    select id into v_current
    from public.routine_checkin_sessions
    where household_id = v_household_id
      and session_type = v_session.session_type
      and scheduled_date = v_session.scheduled_date
      and status <> 'superseded'
    order by opened_at desc
    limit 1;
  end if;

  return jsonb_build_object(
    'id', v_session.id,
    'session_type', v_session.session_type,
    'scheduled_date', v_session.scheduled_date,
    'assignee_id', v_session.assignee_id,
    'status', v_session.status,
    'assignment_generation', v_session.assignment_generation,
    'opened_at', v_session.opened_at,
    'submitted_at', v_session.submitted_at,
    'can_act', v_session.status = 'open' and v_session.assignee_id = p_actor_id,
    'current_session_id', v_current,
    'items', v_items
  );
end;
$$;

revoke all on function public.server_tx_get_routine_session(uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.server_tx_get_routine_session(uuid, uuid)
  to service_role;
