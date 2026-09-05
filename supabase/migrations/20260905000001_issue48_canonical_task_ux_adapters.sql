-- Issue #48: expose the already-reviewed canonical task command foundation
-- through narrow public server_tx adapters.  These adapters deliberately do
-- not change domain semantics; they bind the authenticated production actor
-- and resolve the routine-session snapshot on the server so the PWA cannot
-- submit another household's task IDs or manufacture a bulk-complete set.

create or replace function public.server_tx_set_task_waiting(
  p_actor_id uuid,
  p_operation_id uuid,
  p_task_id uuid,
  p_waiting_action text,
  p_waiting_note text,
  p_next_check_at timestamptz,
  p_expected_revision bigint
) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare v_context jsonb;
begin
  v_context := private.fn_require_production_actor_context_v1(p_actor_id);
  return private.fn_command_task_waiting_v1(
    (v_context->>'household_id')::uuid, p_actor_id,
    (v_context->>'actor_ref_id')::uuid, null, p_task_id,
    p_waiting_action, p_waiting_note, p_next_check_at, p_expected_revision,
    p_operation_id, 'pwa'
  );
end;
$$;

create or replace function public.server_tx_correct_task_actual(
  p_actor_id uuid,
  p_operation_id uuid,
  p_task_id uuid,
  p_performer_actor_ref_ids uuid[],
  p_expected_revision bigint
) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare v_context jsonb;
begin
  v_context := private.fn_require_production_actor_context_v1(p_actor_id);
  return private.fn_command_correct_task_actual_v1(
    (v_context->>'household_id')::uuid, p_actor_id,
    (v_context->>'actor_ref_id')::uuid, null, p_task_id,
    p_performer_actor_ref_ids, p_expected_revision, p_operation_id, 'pwa'
  );
end;
$$;

create or replace function public.server_tx_change_task_assignment(
  p_actor_id uuid,
  p_operation_id uuid,
  p_task_id uuid,
  p_assignment_mode text,
  p_assignee_actor_ref_id uuid,
  p_already_agreed boolean,
  p_expected_revision bigint
) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare v_context jsonb;
begin
  v_context := private.fn_require_production_actor_context_v1(p_actor_id);
  return private.fn_command_change_task_assignment_v1(
    (v_context->>'household_id')::uuid, p_actor_id,
    (v_context->>'actor_ref_id')::uuid, null, p_task_id,
    p_assignment_mode, p_assignee_actor_ref_id, p_already_agreed,
    p_expected_revision, p_operation_id, 'pwa'
  );
end;
$$;

create or replace function public.server_tx_reconcile_routine_session(
  p_actor_id uuid,
  p_operation_id uuid,
  p_session_id uuid,
  p_response_kind text
) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare
  v_context jsonb;
  v_session public.routine_checkin_sessions%rowtype;
  v_task_ids uuid[];
begin
  if p_response_kind not in ('all_done', 'mostly_done', 'individual') then
    raise exception 'RECONCILIATION_RESPONSE_INVALID';
  end if;
  v_context := private.fn_require_production_actor_context_v1(p_actor_id);

  select * into v_session
  from public.routine_checkin_sessions
  where household_id = (v_context->>'household_id')::uuid
    and id = p_session_id
  for share;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if v_session.status <> 'open' or v_session.assignee_id <> p_actor_id then
    raise exception 'ROUTINE_SESSION_NOT_ACTIONABLE';
  end if;

  -- The eligible snapshot is resolved here, not accepted from the client.
  -- Waiting rows are deliberately excluded: they are neither failure nor an
  -- ordinary reconciliation/nag target (Q22/Q64).
  select coalesce(array_agg(ti.id order by si.display_order), '{}'::uuid[])
  into v_task_ids
  from public.routine_checkin_session_items si
  join public.task_instances ti
    on ti.household_id = si.household_id and ti.id = si.task_instance_id
  where si.household_id = v_session.household_id
    and si.session_id = v_session.id
    and ti.scheduled_date = v_session.scheduled_date
    and ti.status in ('todo', 'in_progress')
    and ti.attention_state = 'active';
  if coalesce(array_length(v_task_ids, 1), 0) = 0 then
    raise exception 'RECONCILIATION_EMPTY_GROUP';
  end if;

  return private.fn_command_reconcile_task_group_v1(
    v_session.household_id, p_actor_id, (v_context->>'actor_ref_id')::uuid,
    null, v_session.scheduled_date, 'routine:' || v_session.session_type,
    v_task_ids, p_response_kind, p_operation_id, 'pwa'
  );
end;
$$;

create or replace function public.server_tx_respond_request(
  p_actor_id uuid,
  p_operation_id uuid,
  p_request_id uuid,
  p_response_action text
) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare
  v_context jsonb;
  v_attempt public.request_attempts%rowtype;
begin
  if p_response_action not in ('checking', 'consult') then
    raise exception 'REQUEST_TRANSITION_INVALID';
  end if;
  v_context := private.fn_require_production_actor_context_v1(p_actor_id);
  select a.* into v_attempt from public.request_attempts a
  where a.household_id = (v_context->>'household_id')::uuid
    and a.request_id = p_request_id and a.test_context_id is null
    and a.state in ('pending', 'checking')
  order by a.created_at desc, a.id desc limit 1;
  if not found then raise exception 'REQUEST_ATTEMPT_STALE'; end if;
  return private.fn_command_transition_request_attempt_v1(
    (v_context->>'household_id')::uuid, p_actor_id,
    (v_context->>'actor_ref_id')::uuid, null, p_request_id, v_attempt.id,
    p_response_action, null, v_attempt.revision, v_attempt.terms_revision,
    p_operation_id, 'pwa'
  );
end;
$$;

create or replace function public.server_read_current_routine_sessions(
  p_actor_id uuid
) returns jsonb
language plpgsql stable security invoker set search_path = '' as $$
declare
  v_household_id uuid;
  v_today date := (now() at time zone 'Asia/Tokyo')::date;
  v_sessions jsonb;
begin
  select household_id into v_household_id
  from public.household_members where user_id = p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', s.id,
    'session_type', s.session_type,
    'scheduled_date', s.scheduled_date,
    'status', s.status,
    'assignee_id', s.assignee_id,
    'can_act', s.status = 'open' and s.assignee_id = p_actor_id,
    'remaining_count', coalesce(items.remaining_count, 0)
  ) order by case s.session_type
      when 'dropoff' then 1 when 'pickup' then 2 else 3 end, s.opened_at), '[]'::jsonb)
  into v_sessions
  from public.routine_checkin_sessions s
  left join lateral (
    select count(*)::int as remaining_count
    from public.routine_checkin_session_items si
    join public.task_instances ti
      on ti.household_id = si.household_id and ti.id = si.task_instance_id
    where si.household_id = s.household_id and si.session_id = s.id
      and ti.status in ('todo', 'in_progress') and ti.attention_state = 'active'
  ) items on true
  where s.household_id = v_household_id
    and s.scheduled_date = v_today
    and s.status = 'open';

  return jsonb_build_object('local_date', v_today, 'sessions', v_sessions);
end;
$$;

revoke all on function public.server_tx_set_task_waiting(uuid,uuid,uuid,text,text,timestamptz,bigint) from public, anon, authenticated;
revoke all on function public.server_tx_correct_task_actual(uuid,uuid,uuid,uuid[],bigint) from public, anon, authenticated;
revoke all on function public.server_tx_change_task_assignment(uuid,uuid,uuid,text,uuid,boolean,bigint) from public, anon, authenticated;
revoke all on function public.server_tx_reconcile_routine_session(uuid,uuid,uuid,text) from public, anon, authenticated;
revoke all on function public.server_tx_respond_request(uuid,uuid,uuid,text) from public, anon, authenticated;
revoke all on function public.server_read_current_routine_sessions(uuid) from public, anon, authenticated;
grant execute on function public.server_tx_set_task_waiting(uuid,uuid,uuid,text,text,timestamptz,bigint) to service_role;
grant execute on function public.server_tx_correct_task_actual(uuid,uuid,uuid,uuid[],bigint) to service_role;
grant execute on function public.server_tx_change_task_assignment(uuid,uuid,uuid,text,uuid,boolean,bigint) to service_role;
grant execute on function public.server_tx_reconcile_routine_session(uuid,uuid,uuid,text) to service_role;
grant execute on function public.server_tx_respond_request(uuid,uuid,uuid,text) to service_role;
grant execute on function public.server_read_current_routine_sessions(uuid) to service_role;
