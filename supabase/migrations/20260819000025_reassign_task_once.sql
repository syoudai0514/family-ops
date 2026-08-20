-- WP3 (Recurrence engine): `reassign-task-once` endpoint.
-- docs/design/v6/18_MUTATION_CONTRACT_MATRIX.md #3 "Once reassignment";
-- 08_RECURRING_TASKS_AND_RULES.md #7 "Once change".
--
-- Changes a single task_instance's planned_assignee_id without touching its
-- recurrence_rule at all (a one-off swap, e.g. "just today, the other
-- parent does pickup"), recorded as task_event `reassigned_once`. Same
-- server_tx_* pattern as supabase/migrations/20260819000016_task_instance_mutations.sql
-- (claim-then-fill mutation_receipts, household-membership check,
-- cross-household assignee validation, row lock, TASK_TERMINAL when status
-- is not todo/in_progress, task_events insert).
--
-- Implementation decisions not pinned down verbatim by the matrix text:
--   - Scope restricted to origin='recurring' task_instances, INVALID_INPUT
--     otherwise. The matrix's own precondition text ("recurring/manual
--     active task") is in tension with edit-task's already-reviewed,
--     already-shipped restriction to origin='manual' only (see that
--     migration's header comment: "recurring/request/calendar_assist-origin
--     instances only ever get reassigned via the WP3 reassign-once
--     endpoint, never retitled/rescheduled here"). Manual tasks already
--     have edit-task for changing assignee, so letting reassign-once also
--     accept origin='manual' would give two divergent code paths for the
--     same mutation with no way to pick one deterministically. Narrowing
--     reassign-once to its literal namesake — recurring occurrences — is
--     the smallest resolution that keeps every origin covered by exactly
--     one mutation endpoint. request/calendar_assist-origin reassignment is
--     out of scope for this WP (no request/calendar-assist WP has asked for
--     it yet); extending the allowed origin set later is a small,
--     backward-compatible follow-up, not a breaking one.
--   - Routine check-in session supersession/rebuild and the "assignment
--     change" LINE/notification dispatch named in the matrix text are
--     WP4 (Realtime/history) and WP6 (LINE) concerns — routine_checkin_sessions
--     and notification_outbox do not yet have WP3-owned write paths. This
--     endpoint emits the durable `reassigned_once` task_event (with the old
--     and new assignee in its payload) that those downstream workers can
--     react to; it does not itself touch routine_checkin_sessions or
--     notification_outbox.

create or replace function public.server_tx_reassign_task_once(
  p_actor_id uuid,
  p_operation_id uuid,
  p_task_id uuid,
  p_new_assignee_user_id uuid
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_request_hash text;
  v_receipt record;
  v_household_id uuid;
  v_task record;
  v_old_assignee uuid;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_task_id is null or p_new_assignee_user_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to(
      'reassign-task-once|' || p_task_id::text || '|' || p_new_assignee_user_id::text,
      'UTF8'
    )),
    'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'reassign-task-once', v_request_hash)
    on conflict (actor_id, operation_id) do nothing;

    if found then
      exit;
    end if;

    select * into v_receipt
    from private.mutation_receipts
    where actor_id = p_actor_id and operation_id = p_operation_id
    for update;

    if found then
      if v_receipt.request_hash <> v_request_hash then
        raise exception 'IDEMPOTENCY_CONFLICT';
      end if;
      return v_receipt.result_payload;
    end if;
  end loop;

  select household_id into v_household_id
  from public.household_members
  where user_id = p_actor_id;

  if v_household_id is null then
    raise exception 'NOT_HOUSEHOLD_MEMBER';
  end if;

  if not exists (
    select 1 from public.household_members
    where household_id = v_household_id and user_id = p_new_assignee_user_id
  ) then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  select * into v_task
  from public.task_instances
  where household_id = v_household_id and id = p_task_id
  for update;

  if not found then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;
  if v_task.origin <> 'recurring' then
    raise exception 'INVALID_INPUT';
  end if;
  if v_task.status not in ('todo', 'in_progress') then
    raise exception 'TASK_TERMINAL';
  end if;

  v_old_assignee := v_task.planned_assignee_id;

  update public.task_instances
  set planned_assignee_id = p_new_assignee_user_id
  where household_id = v_household_id and id = p_task_id;

  insert into public.task_events
    (household_id, task_instance_id, actor_id, event_type, payload, source, idempotency_key)
  values
    (v_household_id, p_task_id, p_actor_id, 'reassigned_once',
     jsonb_build_object('old_assignee_id', v_old_assignee, 'new_assignee_id', p_new_assignee_user_id),
     'pwa', p_operation_id::text || ':reassigned_once');

  v_result := jsonb_build_object('ok', true, 'task_id', p_task_id, 'new_assignee_user_id', p_new_assignee_user_id);

  update private.mutation_receipts
  set result_type = 'task_instance', result_id = p_task_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_reassign_task_once(uuid, uuid, uuid, uuid) from public;
revoke all on function public.server_tx_reassign_task_once(uuid, uuid, uuid, uuid) from anon;
revoke all on function public.server_tx_reassign_task_once(uuid, uuid, uuid, uuid) from authenticated;
grant execute on function public.server_tx_reassign_task_once(uuid, uuid, uuid, uuid) to service_role;
