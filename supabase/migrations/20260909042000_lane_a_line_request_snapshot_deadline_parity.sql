-- CF-01 / CF-12 follow-up: make the persisted RequestAttempt snapshot and
-- reply_due_at the truth consumed by both PWA and LINE adapters.
--
-- New LINE pending actions freeze attempt/revision/terms_revision at creation.
-- Legacy ID-only pending actions are never silently upgraded to a newer
-- revision: their execution is rejected as stale.  Actual state mutation still
-- belongs exclusively to fn_command_transition_request_attempt_v1.

create or replace function public.server_tx_send_request_v2(
  p_actor_id uuid,
  p_operation_id uuid,
  p_recipient_user_id uuid,
  p_shared_title text,
  p_shared_message text,
  p_due_at timestamptz,
  p_reply_due_at timestamptz
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_context jsonb;
  v_household_id uuid;
  v_actor_ref_id uuid;
  v_recipient_actor_ref_id uuid;
  v_result jsonb;
  v_request_id uuid;
  v_attempt_id uuid;
  v_attempt_revision bigint;
  v_terms_revision integer;
  v_reply_due timestamptz;
  v_accept_action_id uuid;
  v_decline_action_id uuid;
  v_expiry timestamptz;
begin
  v_context := private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id := (v_context->>'household_id')::uuid;
  v_actor_ref_id := (v_context->>'actor_ref_id')::uuid;

  if p_recipient_user_id = p_actor_id then
    raise exception 'INVALID_INPUT';
  end if;

  select a.id into v_recipient_actor_ref_id
  from public.domain_actor_refs a
  where a.household_id = v_household_id
    and a.actor_kind = 'real_user'
    and a.real_user_id = p_recipient_user_id;
  if v_recipient_actor_ref_id is null then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  v_result := private.fn_command_create_light_request_v2(
    v_household_id,
    p_actor_id,
    v_actor_ref_id,
    null,
    v_recipient_actor_ref_id,
    p_shared_title,
    p_shared_message,
    p_due_at,
    p_reply_due_at,
    p_operation_id,
    'pwa'
  );

  v_request_id := (v_result->>'request_id')::uuid;
  v_attempt_id := (v_result->>'attempt_id')::uuid;
  v_reply_due := (v_result->>'reply_due_at')::timestamptz;

  select revision, terms_revision
    into v_attempt_revision, v_terms_revision
  from public.request_attempts
  where household_id = v_household_id
    and request_id = v_request_id
    and id = v_attempt_id
    and test_context_id is null;
  if not found then raise exception 'REQUEST_ATTEMPT_NOT_FOUND'; end if;

  -- The response action may remain available briefly after the business
  -- deadline only so the worker can return the typed expired/stale response;
  -- the canonical Attempt itself is still authoritative and cannot revive.
  v_expiry := greatest(now() + interval '24 hours', v_reply_due + interval '6 hours');

  insert into private.pending_actions (
    household_id, actor_id, source, action_type, normalized_payload,
    operation_id, status, expires_at, actor_ref_id, test_context_id
  ) values (
    v_household_id,
    p_recipient_user_id,
    'line',
    'request_accept',
    jsonb_build_object(
      'request_id', v_request_id,
      'attempt_id', v_attempt_id,
      'action', 'accept',
      'expected_revision', v_attempt_revision,
      'expected_terms_revision', v_terms_revision,
      'reply_due_at', v_reply_due
    ),
    md5(p_operation_id::text || ':canonical-request-accept')::uuid,
    'draft',
    v_expiry,
    v_recipient_actor_ref_id,
    null
  ) on conflict do nothing;

  select id into v_accept_action_id
  from private.pending_actions
  where actor_id = p_recipient_user_id
    and action_type = 'request_accept'
    and normalized_payload->>'request_id' = v_request_id::text;

  insert into private.pending_actions (
    household_id, actor_id, source, action_type, normalized_payload,
    operation_id, status, expires_at, actor_ref_id, test_context_id
  ) values (
    v_household_id,
    p_recipient_user_id,
    'line',
    'request_decline',
    jsonb_build_object(
      'request_id', v_request_id,
      'attempt_id', v_attempt_id,
      'action', 'decline',
      'expected_revision', v_attempt_revision,
      'expected_terms_revision', v_terms_revision,
      'reply_due_at', v_reply_due
    ),
    md5(p_operation_id::text || ':canonical-request-decline')::uuid,
    'draft',
    v_expiry,
    v_recipient_actor_ref_id,
    null
  ) on conflict do nothing;

  select id into v_decline_action_id
  from private.pending_actions
  where actor_id = p_recipient_user_id
    and action_type = 'request_decline'
    and normalized_payload->>'request_id' = v_request_id::text;

  -- fn_command_create_light_request_v2 already emitted the notification using
  -- v_reply_due.  Enrich rather than replacing it with the nullable input.
  update public.user_notifications
  set payload = payload || jsonb_build_object(
    'request_kind', 'general',
    'due_at', p_due_at,
    'reply_due_at', v_reply_due,
    'attempt_id', v_attempt_id,
    'revision', v_attempt_revision,
    'terms_revision', v_terms_revision,
    'accept_pending_action_id', v_accept_action_id,
    'decline_pending_action_id', v_decline_action_id
  )
  where recipient_user_id = p_recipient_user_id
    and dedup_key = 'request:received:' || v_request_id::text;

  return v_result;
end;
$$;

revoke all on function public.server_tx_send_request_v2(
  uuid, uuid, uuid, text, text, timestamptz, timestamptz
) from public, anon, authenticated;
grant execute on function public.server_tx_send_request_v2(
  uuid, uuid, uuid, text, text, timestamptz, timestamptz
) to service_role;

-- Keep the historical signature as a pure adapter.  Omitted reply deadline
-- now means "use the canonical proposal rule", never "no response deadline".
create or replace function public.server_tx_send_request(
  p_actor_id uuid,
  p_operation_id uuid,
  p_recipient_user_id uuid,
  p_shared_title text,
  p_shared_message text,
  p_due_at timestamptz
) returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select public.server_tx_send_request_v2(
    p_actor_id,
    p_operation_id,
    p_recipient_user_id,
    p_shared_title,
    p_shared_message,
    p_due_at,
    null
  )
$$;

revoke all on function public.server_tx_send_request(
  uuid, uuid, uuid, text, text, timestamptz
) from public, anon, authenticated;
grant execute on function public.server_tx_send_request(
  uuid, uuid, uuid, text, text, timestamptz
) to service_role;

create or replace function public.server_tx_accept_request(
  p_actor_id uuid,
  p_operation_id uuid,
  p_request_id uuid
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_context jsonb;
  v_household_id uuid;
  v_actor_ref_id uuid;
  v_attempt public.request_attempts%rowtype;
  v_pending_payload jsonb;
  v_result jsonb;
begin
  v_context := private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id := (v_context->>'household_id')::uuid;
  v_actor_ref_id := (v_context->>'actor_ref_id')::uuid;

  -- process-pending-actions preserves the immutable LINE snapshot in its row.
  -- If such a row exists, never replace a missing/old revision with CURRENT.
  select normalized_payload into v_pending_payload
  from private.pending_actions
  where actor_id = p_actor_id
    and operation_id = p_operation_id
    and action_type = 'request_accept'
  limit 1;

  if found then
    if v_pending_payload->>'request_id' is distinct from p_request_id::text
       or nullif(v_pending_payload->>'attempt_id', '') is null
       or nullif(v_pending_payload->>'expected_revision', '') is null
       or nullif(v_pending_payload->>'expected_terms_revision', '') is null then
      raise exception 'REQUEST_ATTEMPT_STALE';
    end if;

    v_result := private.fn_command_transition_request_attempt_v1(
      v_household_id,
      p_actor_id,
      v_actor_ref_id,
      null,
      p_request_id,
      (v_pending_payload->>'attempt_id')::uuid,
      'accept',
      null,
      (v_pending_payload->>'expected_revision')::bigint,
      (v_pending_payload->>'expected_terms_revision')::integer,
      p_operation_id,
      'line'
    );
    return v_result || jsonb_build_object('task_id', v_result->'linked_task_id');
  end if;

  -- Compatibility-only direct caller. Assignment-change ID-only acceptance is
  -- never upgraded because its terms include Task revision snapshots.
  if exists (
    select 1 from public.requests
    where household_id = v_household_id
      and id = p_request_id
      and request_kind = 'assignment_change'
  ) then
    raise exception 'REQUEST_ATTEMPT_STALE';
  end if;

  select a.* into v_attempt
  from public.request_attempts a
  where a.household_id = v_household_id
    and a.request_id = p_request_id
    and a.test_context_id is null
    and a.state in ('pending', 'checking', 'consulting', 'awaiting_confirmation')
  order by a.created_at desc
  limit 1;
  if not found then raise exception 'REQUEST_NOT_PENDING'; end if;

  v_result := private.fn_command_transition_request_attempt_v1(
    v_household_id,
    p_actor_id,
    v_actor_ref_id,
    null,
    p_request_id,
    v_attempt.id,
    case when v_attempt.state in ('consulting', 'awaiting_confirmation')
      then 'confirm_terms' else 'accept' end,
    null,
    v_attempt.revision,
    v_attempt.terms_revision,
    p_operation_id,
    'pwa'
  );
  return v_result || jsonb_build_object('task_id', v_result->'linked_task_id');
end;
$$;

create or replace function public.server_tx_decline_request(
  p_actor_id uuid,
  p_operation_id uuid,
  p_request_id uuid
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_context jsonb;
  v_household_id uuid;
  v_actor_ref_id uuid;
  v_request public.requests%rowtype;
  v_attempt public.request_attempts%rowtype;
  v_pending_payload jsonb;
begin
  v_context := private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id := (v_context->>'household_id')::uuid;
  v_actor_ref_id := (v_context->>'actor_ref_id')::uuid;

  select * into v_request
  from public.requests r
  where r.household_id = v_household_id and r.id = p_request_id;
  if not found then raise exception 'REQUEST_NOT_FOUND'; end if;
  if v_request.recipient_actor_ref_id is distinct from v_actor_ref_id then
    raise exception 'REQUEST_NOT_RECIPIENT';
  end if;

  select normalized_payload into v_pending_payload
  from private.pending_actions
  where actor_id = p_actor_id
    and operation_id = p_operation_id
    and action_type = 'request_decline'
  limit 1;

  if found then
    if v_pending_payload->>'request_id' is distinct from p_request_id::text
       or nullif(v_pending_payload->>'attempt_id', '') is null
       or nullif(v_pending_payload->>'expected_revision', '') is null
       or nullif(v_pending_payload->>'expected_terms_revision', '') is null then
      raise exception 'REQUEST_ATTEMPT_STALE';
    end if;
    return private.fn_command_transition_request_attempt_v1(
      v_household_id,
      p_actor_id,
      v_actor_ref_id,
      null,
      p_request_id,
      (v_pending_payload->>'attempt_id')::uuid,
      'decline',
      null,
      (v_pending_payload->>'expected_revision')::bigint,
      (v_pending_payload->>'expected_terms_revision')::integer,
      p_operation_id,
      'line'
    );
  end if;

  if v_request.request_kind = 'assignment_change' then
    raise exception 'REQUEST_ATTEMPT_STALE';
  end if;

  select a.* into v_attempt
  from public.request_attempts a
  where a.household_id = v_household_id
    and a.request_id = p_request_id
    and a.test_context_id is null
    and a.state in ('pending', 'checking', 'consulting', 'awaiting_confirmation')
  order by a.created_at desc
  limit 1;
  if not found then raise exception 'REQUEST_NOT_PENDING'; end if;

  if v_attempt.attempt_kind in ('change', 'cancel') then
    return private.fn_command_decline_request_followup_v1(
      v_household_id,
      p_actor_id,
      v_actor_ref_id,
      null,
      p_request_id,
      v_attempt.id,
      v_attempt.revision,
      p_operation_id,
      'pwa'
    );
  end if;

  return private.fn_command_transition_request_attempt_v1(
    v_household_id,
    p_actor_id,
    v_actor_ref_id,
    null,
    p_request_id,
    v_attempt.id,
    'decline',
    null,
    v_attempt.revision,
    v_attempt.terms_revision,
    p_operation_id,
    'pwa'
  );
end;
$$;

revoke all on function public.server_tx_accept_request(uuid, uuid, uuid)
  from public, anon, authenticated;
revoke all on function public.server_tx_decline_request(uuid, uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.server_tx_accept_request(uuid, uuid, uuid) to service_role;
grant execute on function public.server_tx_decline_request(uuid, uuid, uuid) to service_role;
