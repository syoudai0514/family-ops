-- CF-01 follow-up: assignment-change creation must use the same canonical
-- SECURITY DEFINER command boundary as request transitions.
--
-- DD9 intentionally revoked service_role access to the generic receipt-claim
-- helper.  Keep that privacy boundary: the public RPC remains an adapter and
-- delegates to a private canonical command which owns idempotency + creation.

create or replace function private.fn_command_create_assignment_change_request_v1(
  p_household_id uuid,
  p_operator_user_id uuid,
  p_requester_actor_ref_id uuid,
  p_recipient_actor_ref_id uuid,
  p_task_id uuid,
  p_shared_message text,
  p_scope text,
  p_operation_id uuid,
  p_source text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_task public.task_instances%rowtype;
  v_candidate public.task_instances%rowtype;
  v_targets jsonb := '[]'::jsonb;
  v_claim jsonb;
  v_result jsonb;
  v_request_id uuid;
  v_attempt_id uuid;
  v_reply_due timestamptz;
  v_requester_user_id uuid;
  v_recipient_user_id uuid;
begin
  if p_scope is null or p_scope not in ('once', 'this_week') then
    raise exception 'INVALID_INPUT';
  end if;
  if p_source not in ('pwa', 'line') then
    raise exception 'COMMAND_SOURCE_INVALID';
  end if;
  if p_requester_actor_ref_id = p_recipient_actor_ref_id then
    raise exception 'REQUEST_PARTIES_MUST_DIFFER';
  end if;

  v_claim := private.fn_claim_canonical_operation_v1(
    p_household_id,
    p_operator_user_id,
    p_requester_actor_ref_id,
    null,
    p_operation_id,
    'request.create.assignment_change',
    private.fn_canonical_request_hash_v1(jsonb_build_object(
      'task_id', p_task_id,
      'recipient', p_recipient_actor_ref_id,
      'message', p_shared_message,
      'scope', p_scope
    ))
  );
  if v_claim->>'disposition' = 'replay' then
    return v_claim->'result_payload';
  end if;

  perform private.fn_assert_actor_ref_scope(
    p_household_id, p_recipient_actor_ref_id, null
  );
  v_requester_user_id := private.fn_legacy_user_for_actor_ref_v1(
    p_household_id, p_requester_actor_ref_id, null
  );
  v_recipient_user_id := private.fn_legacy_user_for_actor_ref_v1(
    p_household_id, p_recipient_actor_ref_id, null
  );
  if v_requester_user_id is distinct from p_operator_user_id
     or v_recipient_user_id is null then
    raise exception 'ACTOR_SCOPE_CONFLICT';
  end if;

  select * into v_task
  from public.task_instances
  where household_id = p_household_id
    and id = p_task_id
    and test_context_id is null;
  if not found then
    raise exception 'TASK_NOT_FOUND';
  end if;
  if v_task.planned_assignee_actor_ref_id is distinct from p_requester_actor_ref_id
     or v_task.status not in ('todo', 'in_progress') then
    raise exception 'ASSIGNMENT_CHANGE_NOT_ALLOWED';
  end if;

  -- Lock the complete proposed target set before persisting its revision
  -- snapshot.  Acceptance later validates every snapshot before any Task write.
  for v_candidate in
    select *
    from public.task_instances x
    where x.household_id = p_household_id
      and x.test_context_id is null
      and x.status in ('todo', 'in_progress')
      and x.planned_assignee_actor_ref_id = p_requester_actor_ref_id
      and (
        x.id = v_task.id
        or (
          p_scope = 'this_week'
          and v_task.task_definition_id is not null
          and x.task_definition_id = v_task.task_definition_id
          and x.scheduled_date between v_task.scheduled_date
            and (v_task.scheduled_date + (7 - extract(isodow from v_task.scheduled_date)::integer))
        )
      )
    order by x.id
    for update
  loop
    v_targets := v_targets || jsonb_build_array(jsonb_build_object(
      'task_id', v_candidate.id,
      'revision', v_candidate.revision,
      'assignee_actor_ref_id', v_candidate.planned_assignee_actor_ref_id
    ));
  end loop;

  if not v_targets @> jsonb_build_array(jsonb_build_object('task_id', p_task_id)) then
    raise exception 'AGGREGATE_REVISION_CONFLICT';
  end if;

  v_reply_due := private.fn_propose_request_reply_due_v1(v_task.due_at, now());

  insert into public.requests (
    household_id,
    requester_id,
    recipient_id,
    requester_actor_ref_id,
    recipient_actor_ref_id,
    request_kind,
    shared_title,
    shared_message,
    due_at,
    status,
    assignment_task_instance_id,
    assignment_scope
  ) values (
    p_household_id,
    v_requester_user_id,
    v_recipient_user_id,
    p_requester_actor_ref_id,
    p_recipient_actor_ref_id,
    'assignment_change',
    v_task.title,
    p_shared_message,
    v_task.due_at,
    'pending',
    p_task_id,
    p_scope
  ) returning id into v_request_id;

  insert into public.request_attempts (
    household_id,
    request_id,
    attempt_kind,
    state,
    terms_revision,
    terms,
    reply_due_at,
    created_by_actor_ref_id
  ) values (
    p_household_id,
    v_request_id,
    'initial',
    'pending',
    1,
    jsonb_build_object(
      'title', v_task.title,
      'due_at', v_task.due_at,
      'scope', p_scope,
      'assignment_targets', v_targets
    ),
    v_reply_due,
    p_requester_actor_ref_id
  ) returning id into v_attempt_id;

  perform private.fn_emit_notification_intent_v1(
    p_household_id,
    p_operator_user_id,
    p_requester_actor_ref_id,
    null,
    p_recipient_actor_ref_id,
    'request.received',
    '担当変更のお願い',
    coalesce(p_shared_message, v_task.title),
    jsonb_build_object(
      'request_id', v_request_id,
      'attempt_id', v_attempt_id,
      'revision', 1,
      'terms_revision', 1,
      'request_kind', 'assignment_change',
      'scope', p_scope,
      'reply_due_at', v_reply_due,
      'due_at', v_task.due_at
    ),
    'request:received:' || v_request_id::text,
    'immediate',
    'normal',
    'request:' || v_request_id::text,
    v_reply_due,
    'request',
    v_request_id,
    1
  );

  v_result := jsonb_build_object(
    'request_id', v_request_id,
    'attempt_id', v_attempt_id,
    'revision', 1,
    'terms_revision', 1,
    'state', 'pending',
    'reply_due_at', v_reply_due,
    'task_id', p_task_id
  );
  perform private.fn_complete_canonical_operation_v1(
    (v_claim->>'receipt_id')::uuid,
    'request',
    v_request_id,
    v_result
  );
  return v_result;
end;
$$;

revoke all on function private.fn_command_create_assignment_change_request_v1(
  uuid, uuid, uuid, uuid, uuid, text, text, uuid, text
) from public, anon, authenticated;
grant execute on function private.fn_command_create_assignment_change_request_v1(
  uuid, uuid, uuid, uuid, uuid, text, text, uuid, text
) to service_role;

create or replace function public.server_tx_create_assignment_change_request(
  p_actor_id uuid,
  p_operation_id uuid,
  p_task_id uuid,
  p_recipient_user_id uuid,
  p_shared_message text,
  p_scope text
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_context jsonb;
  v_household_id uuid;
  v_requester_actor_ref_id uuid;
  v_recipient_actor_ref_id uuid;
begin
  v_context := private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id := (v_context->>'household_id')::uuid;
  v_requester_actor_ref_id := (v_context->>'actor_ref_id')::uuid;

  select id into v_recipient_actor_ref_id
  from public.domain_actor_refs
  where household_id = v_household_id
    and actor_kind = 'real_user'
    and real_user_id = p_recipient_user_id;

  if v_recipient_actor_ref_id is null
     or v_recipient_actor_ref_id = v_requester_actor_ref_id then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  return private.fn_command_create_assignment_change_request_v1(
    v_household_id,
    p_actor_id,
    v_requester_actor_ref_id,
    v_recipient_actor_ref_id,
    p_task_id,
    p_shared_message,
    p_scope,
    p_operation_id,
    'pwa'
  );
end;
$$;

revoke all on function public.server_tx_create_assignment_change_request(
  uuid, uuid, uuid, uuid, text, text
) from public, anon, authenticated;
grant execute on function public.server_tx_create_assignment_change_request(
  uuid, uuid, uuid, uuid, text, text
) to service_role;
