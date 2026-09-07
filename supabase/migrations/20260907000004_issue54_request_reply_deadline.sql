-- Issue #54 request-form parity: initial light Requests need a response deadline
-- distinct from the work deadline. Preserve the public server_tx_send_request
-- shape for existing callers and add a v2 overload used by PWA/LINE adapters.

create or replace function private.fn_command_create_light_request_v2(
  p_household_id uuid,
  p_operator_user_id uuid,
  p_requester_actor_ref_id uuid,
  p_test_context_id uuid,
  p_recipient_actor_ref_id uuid,
  p_shared_title text,
  p_shared_message text,
  p_due_at timestamptz,
  p_reply_due_at timestamptz,
  p_operation_id uuid,
  p_source text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_claim jsonb;
  v_receipt_id uuid;
  v_request_id uuid;
  v_attempt_id uuid;
  v_requester_user uuid;
  v_recipient_user uuid;
  v_result jsonb;
begin
  if nullif(btrim(coalesce(p_shared_title, '')), '') is null then raise exception 'REQUEST_TITLE_REQUIRED'; end if;
  if p_requester_actor_ref_id = p_recipient_actor_ref_id then raise exception 'REQUEST_PARTIES_MUST_DIFFER'; end if;
  if p_source not in ('line', 'pwa') then raise exception 'COMMAND_SOURCE_INVALID'; end if;
  if p_reply_due_at is not null and p_reply_due_at < now() then raise exception 'REQUEST_REPLY_DUE_IN_PAST'; end if;

  v_claim := private.fn_claim_canonical_operation_v1(
    p_household_id, p_operator_user_id, p_requester_actor_ref_id, p_test_context_id,
    p_operation_id, 'request.create.light',
    private.fn_canonical_request_hash_v1(jsonb_build_object(
      'recipient_actor_ref_id', p_recipient_actor_ref_id,
      'shared_title', btrim(p_shared_title),
      'shared_message', nullif(btrim(coalesce(p_shared_message, '')), ''),
      'due_at', p_due_at, 'reply_due_at', p_reply_due_at, 'source', p_source
    ))
  );
  if v_claim->>'disposition' = 'replay' then return v_claim->'result_payload'; end if;
  v_receipt_id := (v_claim->>'receipt_id')::uuid;

  perform private.fn_assert_actor_ref_scope(p_household_id, p_recipient_actor_ref_id, p_test_context_id);
  v_requester_user := private.fn_legacy_user_for_actor_ref_v1(p_household_id, p_requester_actor_ref_id, p_test_context_id);
  v_recipient_user := private.fn_legacy_user_for_actor_ref_v1(p_household_id, p_recipient_actor_ref_id, p_test_context_id);

  insert into public.requests (
    household_id, requester_id, recipient_id, requester_actor_ref_id,
    recipient_actor_ref_id, request_kind, shared_title, shared_message,
    due_at, status, test_context_id
  ) values (
    p_household_id, v_requester_user, v_recipient_user, p_requester_actor_ref_id,
    p_recipient_actor_ref_id, 'light', btrim(p_shared_title),
    nullif(btrim(coalesce(p_shared_message, '')), ''), p_due_at, 'pending', p_test_context_id
  ) returning id into v_request_id;

  insert into public.request_attempts (
    household_id, request_id, attempt_kind, state, terms_revision, terms,
    reply_due_at, created_by_actor_ref_id, test_context_id
  ) values (
    p_household_id, v_request_id, 'initial', 'pending', 1,
    jsonb_build_object('title', btrim(p_shared_title), 'due_at', p_due_at),
    p_reply_due_at, p_requester_actor_ref_id, p_test_context_id
  ) returning id into v_attempt_id;

  perform private.fn_emit_notification_intent_v1(
    p_household_id, p_operator_user_id, p_requester_actor_ref_id, p_test_context_id,
    p_recipient_actor_ref_id, 'request.received', 'お願いが届きました',
    btrim(p_shared_title),
    jsonb_build_object('request_id', v_request_id, 'attempt_id', v_attempt_id,
      'reply_due_at', p_reply_due_at, 'due_at', p_due_at),
    'request:received:' || v_request_id::text,
    'immediate', 'normal', 'request:' || v_request_id::text,
    p_reply_due_at, 'request', v_request_id, 1
  );

  v_result := jsonb_build_object(
    'request_id', v_request_id, 'attempt_id', v_attempt_id,
    'state', 'pending', 'terms_revision', 1,
    'reply_due_at', p_reply_due_at, 'due_at', p_due_at
  );
  perform private.fn_complete_canonical_operation_v1(v_receipt_id, 'request', v_request_id, v_result);
  return v_result;
end;
$$;
revoke all on function private.fn_command_create_light_request_v2(uuid,uuid,uuid,uuid,uuid,text,text,timestamptz,timestamptz,uuid,text) from public, anon, authenticated;
grant execute on function private.fn_command_create_light_request_v2(uuid,uuid,uuid,uuid,uuid,text,text,timestamptz,timestamptz,uuid,text) to service_role;

create or replace function public.server_tx_send_request_v2(
  p_actor_id uuid,
  p_operation_id uuid,
  p_recipient_user_id uuid,
  p_shared_title text,
  p_shared_message text,
  p_due_at timestamptz,
  p_reply_due_at timestamptz
) returns jsonb
language plpgsql security invoker set search_path = '' as $$
declare
  v_context jsonb;
  v_household_id uuid;
  v_actor_ref_id uuid;
  v_recipient_actor_ref_id uuid;
  v_result jsonb;
  v_request_id uuid;
  v_accept_action_id uuid;
  v_decline_action_id uuid;
  v_expiry timestamptz;
begin
  v_context := private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id := (v_context->>'household_id')::uuid;
  v_actor_ref_id := (v_context->>'actor_ref_id')::uuid;

  select a.id into v_recipient_actor_ref_id
  from public.domain_actor_refs a
  where a.household_id = v_household_id and a.actor_kind = 'real_user'
    and a.real_user_id = p_recipient_user_id;
  if v_recipient_actor_ref_id is null or p_recipient_user_id = p_actor_id then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  v_result := private.fn_command_create_light_request_v2(
    v_household_id, p_actor_id, v_actor_ref_id, null,
    v_recipient_actor_ref_id, p_shared_title, p_shared_message, p_due_at,
    p_reply_due_at, p_operation_id, 'pwa'
  );
  v_request_id := (v_result->>'request_id')::uuid;
  v_expiry := greatest(
    now() + interval '24 hours',
    coalesce(p_reply_due_at + interval '6 hours', p_due_at + interval '6 hours', now() + interval '24 hours')
  );

  insert into private.pending_actions (
    household_id, actor_id, source, action_type, normalized_payload,
    operation_id, status, expires_at, actor_ref_id, test_context_id
  ) values (
    v_household_id, p_recipient_user_id, 'line', 'request_accept',
    jsonb_build_object('request_id', v_request_id),
    md5(p_operation_id::text || ':canonical-request-accept')::uuid,
    'draft', v_expiry, v_recipient_actor_ref_id, null
  ) on conflict do nothing;
  select id into v_accept_action_id from private.pending_actions
  where actor_id = p_recipient_user_id and action_type = 'request_accept'
    and normalized_payload->>'request_id' = v_request_id::text;

  insert into private.pending_actions (
    household_id, actor_id, source, action_type, normalized_payload,
    operation_id, status, expires_at, actor_ref_id, test_context_id
  ) values (
    v_household_id, p_recipient_user_id, 'line', 'request_decline',
    jsonb_build_object('request_id', v_request_id),
    md5(p_operation_id::text || ':canonical-request-decline')::uuid,
    'draft', v_expiry, v_recipient_actor_ref_id, null
  ) on conflict do nothing;
  select id into v_decline_action_id from private.pending_actions
  where actor_id = p_recipient_user_id and action_type = 'request_decline'
    and normalized_payload->>'request_id' = v_request_id::text;

  update public.user_notifications
  set payload = payload || jsonb_build_object(
    'request_kind', 'general', 'due_at', p_due_at, 'reply_due_at', p_reply_due_at,
    'accept_pending_action_id', v_accept_action_id,
    'decline_pending_action_id', v_decline_action_id
  )
  where recipient_user_id = p_recipient_user_id
    and dedup_key = 'request:received:' || v_request_id::text;

  return v_result;
end;
$$;
revoke all on function public.server_tx_send_request_v2(uuid,uuid,uuid,text,text,timestamptz,timestamptz) from public, anon, authenticated;
grant execute on function public.server_tx_send_request_v2(uuid,uuid,uuid,text,text,timestamptz,timestamptz) to service_role;
