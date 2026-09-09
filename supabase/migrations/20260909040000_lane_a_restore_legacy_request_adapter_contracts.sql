-- CF-01 compatibility follow-up.
--
-- The Lane A cutover redefined the legacy public decline/cancel RPCs after the
-- DD4 compatibility migrations. Keep those public error/lifecycle contracts,
-- while delegating every actual pending-attempt mutation to the canonical
-- RequestAttempt command. No legacy function below owns independent state.

create or replace function public.server_tx_decline_request(
  p_actor_id uuid, p_operation_id uuid, p_request_id uuid
) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare
  v_context jsonb;
  v_household_id uuid;
  v_actor_ref_id uuid;
  v_request public.requests%rowtype;
  v_attempt public.request_attempts%rowtype;
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
  if v_request.request_kind = 'assignment_change' then
    -- ID-only legacy actions have no trustworthy attempt/revision snapshot.
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
      v_household_id, p_actor_id, v_actor_ref_id, null, p_request_id,
      v_attempt.id, v_attempt.revision, p_operation_id, 'pwa'
    );
  end if;

  return private.fn_command_transition_request_attempt_v1(
    v_household_id, p_actor_id, v_actor_ref_id, null, p_request_id,
    v_attempt.id, 'decline', null, v_attempt.revision,
    v_attempt.terms_revision, p_operation_id, 'pwa'
  );
end;
$$;

create or replace function public.server_tx_cancel_request(
  p_actor_id uuid, p_operation_id uuid, p_request_id uuid
) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare
  v_context jsonb;
  v_household_id uuid;
  v_actor_ref_id uuid;
  v_request public.requests%rowtype;
  v_attempt public.request_attempts%rowtype;
begin
  v_context := private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id := (v_context->>'household_id')::uuid;
  v_actor_ref_id := (v_context->>'actor_ref_id')::uuid;

  select * into v_request
  from public.requests r
  where r.household_id = v_household_id and r.id = p_request_id;
  if not found then raise exception 'REQUEST_NOT_FOUND'; end if;
  if v_request.requester_actor_ref_id is distinct from v_actor_ref_id then
    raise exception 'REQUEST_NOT_REQUESTER';
  end if;
  if v_request.request_kind = 'assignment_change' then
    -- The old ID-only endpoint cannot safely select a current Attempt.
    raise exception 'REQUEST_ATTEMPT_STALE';
  end if;
  -- DD4 contract: this historical endpoint is pending-only. Post-agreement
  -- changes/cancellation use the explicit follow-up command instead.
  if v_request.status <> 'pending' then
    raise exception 'REQUEST_CANCEL_NOT_ALLOWED';
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

  return private.fn_command_transition_request_attempt_v1(
    v_household_id, p_actor_id, v_actor_ref_id, null, p_request_id,
    v_attempt.id, 'cancel', null, v_attempt.revision,
    v_attempt.terms_revision, p_operation_id, 'pwa'
  );
end;
$$;

revoke all on function public.server_tx_decline_request(uuid,uuid,uuid)
  from public, anon, authenticated;
revoke all on function public.server_tx_cancel_request(uuid,uuid,uuid)
  from public, anon, authenticated;
grant execute on function public.server_tx_decline_request(uuid,uuid,uuid) to service_role;
grant execute on function public.server_tx_cancel_request(uuid,uuid,uuid) to service_role;
