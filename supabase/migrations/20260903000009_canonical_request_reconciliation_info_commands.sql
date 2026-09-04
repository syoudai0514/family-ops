-- WP-DD3 remainder: Request Attempt, deterministic task outcome, group
-- reconciliation, and information acknowledgement/update commands.
--
-- Private/service-role only. No PWA/LINE route is cut over and no capability
-- gate is activated by this migration.

-- ---------------------------------------------------------------------------
-- Deterministic skipped outcome
-- ---------------------------------------------------------------------------

create or replace function private.fn_command_skip_task_v1(
  p_household_id uuid,
  p_operator_user_id uuid,
  p_actor_ref_id uuid,
  p_test_context_id uuid,
  p_task_id uuid,
  p_outcome_reason text,
  p_expected_revision bigint,
  p_operation_id uuid,
  p_source text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_claim jsonb;
  v_receipt_id uuid;
  v_task public.task_instances%rowtype;
  v_actor_user_id uuid;
  v_revision bigint;
  v_result jsonb;
begin
  if p_outcome_reason not in ('could_not_do', 'not_needed_this_occurrence', 'expired_occurrence') then
    raise exception 'TASK_OUTCOME_REASON_INVALID';
  end if;
  if p_source not in ('line', 'pwa') then raise exception 'COMMAND_SOURCE_INVALID'; end if;

  v_claim := private.fn_claim_canonical_operation_v1(
    p_household_id, p_operator_user_id, p_actor_ref_id, p_test_context_id,
    p_operation_id, 'task.skip',
    private.fn_canonical_request_hash_v1(jsonb_build_object(
      'task_id', p_task_id, 'outcome_reason', p_outcome_reason,
      'expected_revision', p_expected_revision, 'source', p_source
    ))
  );
  if v_claim->>'disposition' = 'replay' then return v_claim->'result_payload'; end if;
  v_receipt_id := (v_claim->>'receipt_id')::uuid;

  select * into v_task from public.task_instances
  where household_id = p_household_id and id = p_task_id for update;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;
  if v_task.test_context_id is distinct from p_test_context_id then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
  if v_task.revision <> p_expected_revision then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  if v_task.status not in ('todo', 'in_progress') then raise exception 'TASK_NOT_OPEN'; end if;

  update public.task_instances
  set status = 'skipped',
      outcome_reason = p_outcome_reason,
      active_claimant_actor_ref_id = null,
      claimed_at = null,
      attention_state = 'active',
      waiting_note = null,
      next_check_at = null,
      revision = revision + 1
  where household_id = p_household_id and id = p_task_id
  returning revision into v_revision;

  v_actor_user_id := private.fn_legacy_user_for_actor_ref_v1(
    p_household_id, p_actor_ref_id, p_test_context_id
  );
  insert into public.task_events (
    household_id, task_instance_id, actor_id, actor_ref_id, test_context_id,
    event_type, payload, source, idempotency_key
  ) values (
    p_household_id, p_task_id, v_actor_user_id, p_actor_ref_id, p_test_context_id,
    'skipped',
    jsonb_build_object('outcome_reason', p_outcome_reason, 'revision', v_revision),
    p_source, 'canonical:' || p_operation_id::text
  );

  v_result := jsonb_build_object(
    'task_id', p_task_id, 'status', 'skipped',
    'outcome_reason', p_outcome_reason, 'revision', v_revision
  );
  perform private.fn_complete_canonical_operation_v1(v_receipt_id, 'task', p_task_id, v_result);
  return v_result;
end;
$$;
revoke all on function private.fn_command_skip_task_v1(uuid, uuid, uuid, uuid, uuid, text, bigint, uuid, text) from public, anon, authenticated;
grant execute on function private.fn_command_skip_task_v1(uuid, uuid, uuid, uuid, uuid, text, bigint, uuid, text) to service_role;

-- ---------------------------------------------------------------------------
-- Request / Attempt helpers
-- ---------------------------------------------------------------------------

create or replace function private.fn_request_party_role_v1(
  p_request public.requests,
  p_actor_ref_id uuid
) returns text
language plpgsql immutable security invoker set search_path = '' as $$
begin
  if p_request.requester_actor_ref_id = p_actor_ref_id then return 'requester'; end if;
  if p_request.recipient_actor_ref_id = p_actor_ref_id then return 'recipient'; end if;
  raise exception 'REQUEST_ACTOR_NOT_PARTY';
end;
$$;
revoke all on function private.fn_request_party_role_v1(public.requests, uuid) from public, anon, authenticated;
grant execute on function private.fn_request_party_role_v1(public.requests, uuid) to service_role;

create or replace function private.fn_ensure_light_request_task_v1(
  p_request_id uuid,
  p_operator_user_id uuid
) returns uuid
language plpgsql security definer set search_path = '' as $$
declare
  v_request public.requests%rowtype;
  v_task_id uuid;
  v_legacy_assignee uuid;
begin
  select * into v_request from public.requests where id = p_request_id for update;
  if not found then raise exception 'REQUEST_NOT_FOUND'; end if;
  if v_request.request_kind <> 'light' then
    raise exception 'REQUEST_KIND_NOT_LIGHT';
  end if;
  if v_request.linked_task_instance_id is not null then return v_request.linked_task_instance_id; end if;

  v_legacy_assignee := private.fn_legacy_user_for_actor_ref_v1(
    v_request.household_id, v_request.recipient_actor_ref_id, v_request.test_context_id
  );

  insert into public.task_instances (
    household_id, origin, title, category, routine_phase, scheduled_date, due_at,
    planned_assignee_id, completion_mode, status, source, created_by,
    assignment_mode, assignment_source, planned_assignee_actor_ref_id,
    test_context_id
  ) values (
    v_request.household_id, 'request', v_request.shared_title, 'other', 'anytime',
    coalesce((v_request.due_at at time zone 'Asia/Tokyo')::date, (now() at time zone 'Asia/Tokyo')::date),
    v_request.due_at, v_legacy_assignee, 'whole', 'todo', 'canonical_request',
    p_operator_user_id, 'person', 'agreement', v_request.recipient_actor_ref_id,
    v_request.test_context_id
  ) returning id into v_task_id;

  update public.requests
  set linked_task_instance_id = v_task_id, revision = revision + 1
  where id = v_request.id and linked_task_instance_id is null;

  return v_task_id;
end;
$$;
revoke all on function private.fn_ensure_light_request_task_v1(uuid, uuid) from public, anon, authenticated;
grant execute on function private.fn_ensure_light_request_task_v1(uuid, uuid) to service_role;

create or replace function private.fn_command_create_light_request_v1(
  p_household_id uuid,
  p_operator_user_id uuid,
  p_requester_actor_ref_id uuid,
  p_test_context_id uuid,
  p_recipient_actor_ref_id uuid,
  p_shared_title text,
  p_shared_message text,
  p_due_at timestamptz,
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

  v_claim := private.fn_claim_canonical_operation_v1(
    p_household_id, p_operator_user_id, p_requester_actor_ref_id, p_test_context_id,
    p_operation_id, 'request.create.light',
    private.fn_canonical_request_hash_v1(jsonb_build_object(
      'recipient_actor_ref_id', p_recipient_actor_ref_id,
      'shared_title', btrim(p_shared_title),
      'shared_message', nullif(btrim(coalesce(p_shared_message, '')), ''),
      'due_at', p_due_at, 'source', p_source
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
    p_due_at, p_requester_actor_ref_id, p_test_context_id
  ) returning id into v_attempt_id;

  perform private.fn_emit_notification_intent_v1(
    p_household_id, p_operator_user_id, p_requester_actor_ref_id, p_test_context_id,
    p_recipient_actor_ref_id, 'request.received', 'お願いが届きました',
    btrim(p_shared_title),
    jsonb_build_object('request_id', v_request_id, 'attempt_id', v_attempt_id),
    'request:received:' || v_request_id::text,
    'immediate', 'normal', 'request:' || v_request_id::text,
    p_due_at, 'request', v_request_id, 1
  );

  v_result := jsonb_build_object(
    'request_id', v_request_id, 'attempt_id', v_attempt_id,
    'state', 'pending', 'terms_revision', 1
  );
  perform private.fn_complete_canonical_operation_v1(v_receipt_id, 'request', v_request_id, v_result);
  return v_result;
end;
$$;
revoke all on function private.fn_command_create_light_request_v1(uuid, uuid, uuid, uuid, uuid, text, text, timestamptz, uuid, text) from public, anon, authenticated;
grant execute on function private.fn_command_create_light_request_v1(uuid, uuid, uuid, uuid, uuid, text, text, timestamptz, uuid, text) to service_role;

create or replace function private.fn_command_transition_request_attempt_v1(
  p_household_id uuid,
  p_operator_user_id uuid,
  p_actor_ref_id uuid,
  p_test_context_id uuid,
  p_request_id uuid,
  p_attempt_id uuid,
  p_action text,
  p_terms jsonb,
  p_expected_revision bigint,
  p_expected_terms_revision int,
  p_operation_id uuid,
  p_source text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_claim jsonb;
  v_receipt_id uuid;
  v_request public.requests%rowtype;
  v_attempt public.request_attempts%rowtype;
  v_party text;
  v_new_state text;
  v_new_revision bigint;
  v_new_terms_revision int;
  v_confirmations int;
  v_task_id uuid;
  v_result jsonb;
begin
  if p_action not in ('checking', 'consult', 'edit_terms', 'confirm_terms', 'accept', 'decline', 'cancel') then
    raise exception 'REQUEST_ATTEMPT_ACTION_INVALID';
  end if;
  if p_source not in ('line', 'pwa') then raise exception 'COMMAND_SOURCE_INVALID'; end if;

  v_claim := private.fn_claim_canonical_operation_v1(
    p_household_id, p_operator_user_id, p_actor_ref_id, p_test_context_id,
    p_operation_id, 'request.attempt.' || p_action,
    private.fn_canonical_request_hash_v1(jsonb_build_object(
      'request_id', p_request_id, 'attempt_id', p_attempt_id, 'action', p_action,
      'terms', coalesce(p_terms, '{}'::jsonb), 'expected_revision', p_expected_revision,
      'expected_terms_revision', p_expected_terms_revision, 'source', p_source
    ))
  );
  if v_claim->>'disposition' = 'replay' then return v_claim->'result_payload'; end if;
  v_receipt_id := (v_claim->>'receipt_id')::uuid;

  select * into v_request from public.requests
  where household_id = p_household_id and id = p_request_id for update;
  if not found then raise exception 'REQUEST_NOT_FOUND'; end if;
  if v_request.test_context_id is distinct from p_test_context_id then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
  v_party := private.fn_request_party_role_v1(v_request, p_actor_ref_id);

  select * into v_attempt from public.request_attempts
  where household_id = p_household_id and id = p_attempt_id and request_id = p_request_id
  for update;
  if not found then raise exception 'REQUEST_ATTEMPT_NOT_FOUND'; end if;
  if v_attempt.test_context_id is distinct from p_test_context_id then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
  if v_attempt.revision <> p_expected_revision then raise exception 'REQUEST_ATTEMPT_STALE'; end if;
  if v_attempt.state in ('accepted', 'declined', 'expired', 'cancelled') then raise exception 'REQUEST_ATTEMPT_STALE'; end if;

  v_new_state := v_attempt.state;
  v_new_terms_revision := v_attempt.terms_revision;

  if p_action = 'checking' then
    if v_party <> 'recipient' or v_attempt.state <> 'pending' then raise exception 'REQUEST_TRANSITION_INVALID'; end if;
    v_new_state := 'checking';
    update public.request_attempts set state = v_new_state, revision = revision + 1 where id = v_attempt.id returning revision into v_new_revision;

  elsif p_action = 'consult' then
    if v_attempt.state not in ('pending', 'checking') then raise exception 'REQUEST_TRANSITION_INVALID'; end if;
    v_new_state := 'consulting';
    update public.request_attempts set state = v_new_state, revision = revision + 1 where id = v_attempt.id returning revision into v_new_revision;

  elsif p_action = 'edit_terms' then
    if v_attempt.state not in ('consulting', 'awaiting_confirmation') then raise exception 'REQUEST_TRANSITION_INVALID'; end if;
    if p_terms is null or p_terms = '{}'::jsonb then raise exception 'REQUEST_TERMS_REQUIRED'; end if;
    v_new_terms_revision := v_attempt.terms_revision + 1;
    v_new_state := 'awaiting_confirmation';
    update public.request_attempts
    set terms = p_terms,
        terms_revision = v_new_terms_revision,
        state = v_new_state,
        revision = revision + 1
    where id = v_attempt.id returning revision into v_new_revision;
    insert into public.request_attempt_confirmations (
      household_id, attempt_id, terms_revision, actor_ref_id, test_context_id
    ) values (
      p_household_id, v_attempt.id, v_new_terms_revision, p_actor_ref_id, p_test_context_id
    ) on conflict do nothing;

  elsif p_action = 'confirm_terms' then
    if v_attempt.state not in ('consulting', 'awaiting_confirmation') then raise exception 'REQUEST_TRANSITION_INVALID'; end if;
    if p_expected_terms_revision is null or p_expected_terms_revision <> v_attempt.terms_revision then
      raise exception 'REQUEST_TERMS_REVISION_STALE';
    end if;
    insert into public.request_attempt_confirmations (
      household_id, attempt_id, terms_revision, actor_ref_id, test_context_id
    ) values (
      p_household_id, v_attempt.id, v_attempt.terms_revision, p_actor_ref_id, p_test_context_id
    ) on conflict do nothing;

    select count(*) into v_confirmations
    from public.request_attempt_confirmations c
    where c.attempt_id = v_attempt.id
      and c.terms_revision = v_attempt.terms_revision
      and c.actor_ref_id in (v_request.requester_actor_ref_id, v_request.recipient_actor_ref_id);

    if v_confirmations >= 2 then
      v_new_state := 'accepted';
      update public.request_attempts
      set state = 'accepted', accepted_at = now(), revision = revision + 1
      where id = v_attempt.id returning revision into v_new_revision;
    else
      v_new_state := 'awaiting_confirmation';
      update public.request_attempts
      set state = 'awaiting_confirmation', revision = revision + 1
      where id = v_attempt.id returning revision into v_new_revision;
    end if;

  elsif p_action = 'accept' then
    if v_party <> 'recipient' or v_attempt.state not in ('pending', 'checking') then raise exception 'REQUEST_TRANSITION_INVALID'; end if;
    v_new_state := 'accepted';
    update public.request_attempts
    set state = 'accepted', accepted_at = now(), revision = revision + 1
    where id = v_attempt.id returning revision into v_new_revision;

  elsif p_action = 'decline' then
    if v_party <> 'recipient' or v_attempt.state not in ('pending', 'checking') then raise exception 'REQUEST_TRANSITION_INVALID'; end if;
    v_new_state := 'declined';
    update public.request_attempts
    set state = 'declined', declined_at = now(), revision = revision + 1
    where id = v_attempt.id returning revision into v_new_revision;

  else
    if v_party <> 'requester' then raise exception 'REQUEST_TRANSITION_INVALID'; end if;
    v_new_state := 'cancelled';
    update public.request_attempts
    set state = 'cancelled', cancelled_at = now(), revision = revision + 1
    where id = v_attempt.id returning revision into v_new_revision;
  end if;

  perform private.fn_project_request_legacy_lifecycle_v1(p_household_id, p_request_id);

  if v_new_state = 'accepted' and v_attempt.attempt_kind in ('initial', 'reproposal') then
    if v_request.request_kind = 'light' then
      v_task_id := private.fn_ensure_light_request_task_v1(p_request_id, p_operator_user_id);
    elsif v_request.request_kind = 'assignment_change' then
      -- Existing assignment-change scope may cover multiple tasks. Enabling its
      -- canonical accept path before every scoped Task revision is represented
      -- would permit stale bulk reassignment, so fail closed in this pre-P1 PR.
      raise exception 'CANONICAL_ASSIGNMENT_CHANGE_ACCEPT_NOT_ENABLED';
    end if;
  end if;

  if p_action = 'checking' then
    perform private.fn_emit_notification_intent_v1(
      p_household_id, p_operator_user_id, p_actor_ref_id, p_test_context_id,
      v_request.requester_actor_ref_id, 'request.checking', '確認中です',
      v_request.shared_title,
      jsonb_build_object('request_id', p_request_id, 'attempt_id', p_attempt_id, 'state', v_new_state),
      'request:checking:' || p_attempt_id::text || ':' || v_new_revision::text,
      'immediate', 'normal', 'request:' || p_request_id::text,
      v_request.due_at, 'request', p_request_id, v_new_revision
    );
  elsif v_new_state in ('accepted', 'declined', 'cancelled') then
    perform private.fn_emit_notification_intent_v1(
      p_household_id, p_operator_user_id, p_actor_ref_id, p_test_context_id,
      case when v_party = 'recipient' then v_request.requester_actor_ref_id else v_request.recipient_actor_ref_id end,
      'request.' || v_new_state, 'お願いを更新しました', v_request.shared_title,
      jsonb_build_object('request_id', p_request_id, 'attempt_id', p_attempt_id, 'state', v_new_state, 'task_id', v_task_id),
      'request:' || v_new_state || ':' || p_attempt_id::text || ':' || v_new_revision::text,
      'immediate', 'normal', 'request:' || p_request_id::text,
      v_request.due_at, 'request', p_request_id, v_new_revision
    );
  end if;

  v_result := jsonb_build_object(
    'request_id', p_request_id, 'attempt_id', p_attempt_id,
    'state', v_new_state, 'revision', v_new_revision,
    'terms_revision', v_new_terms_revision, 'linked_task_id', v_task_id
  );
  perform private.fn_complete_canonical_operation_v1(v_receipt_id, 'request', p_request_id, v_result);
  return v_result;
end;
$$;
revoke all on function private.fn_command_transition_request_attempt_v1(uuid, uuid, uuid, uuid, uuid, uuid, text, jsonb, bigint, int, uuid, text) from public, anon, authenticated;
grant execute on function private.fn_command_transition_request_attempt_v1(uuid, uuid, uuid, uuid, uuid, uuid, text, jsonb, bigint, int, uuid, text) to service_role;

-- ---------------------------------------------------------------------------
-- Group reconciliation. p_task_ids is a server-resolved exact snapshot; this
-- private function revalidates every row under lock and never trusts a task ID
-- outside household/date/test scope.
-- ---------------------------------------------------------------------------

create or replace function private.fn_command_reconcile_task_group_v1(
  p_household_id uuid,
  p_operator_user_id uuid,
  p_actor_ref_id uuid,
  p_test_context_id uuid,
  p_target_local_date date,
  p_group_key text,
  p_task_ids uuid[],
  p_response_kind text,
  p_operation_id uuid,
  p_source text
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_claim jsonb;
  v_receipt_id uuid;
  v_session_id uuid;
  v_task public.task_instances%rowtype;
  v_task_id uuid;
  v_actor_user_id uuid;
  v_compat_user uuid;
  v_completed int := 0;
  v_order int := 0;
  v_observed text;
  v_result jsonb;
begin
  if p_response_kind not in ('all_done', 'mostly_done', 'individual') then raise exception 'RECONCILIATION_RESPONSE_INVALID'; end if;
  if p_source not in ('line', 'pwa') then raise exception 'COMMAND_SOURCE_INVALID'; end if;
  if p_task_ids is null or coalesce(array_length(p_task_ids, 1), 0) = 0 then raise exception 'RECONCILIATION_EMPTY_GROUP'; end if;
  if exists (select 1 from unnest(p_task_ids) x(id) group by id having count(*) > 1) then raise exception 'RECONCILIATION_DUPLICATE_TASK'; end if;

  v_claim := private.fn_claim_canonical_operation_v1(
    p_household_id, p_operator_user_id, p_actor_ref_id, p_test_context_id,
    p_operation_id, 'task.reconcile.' || p_response_kind,
    private.fn_canonical_request_hash_v1(jsonb_build_object(
      'target_local_date', p_target_local_date, 'group_key', p_group_key,
      'task_ids', to_jsonb(p_task_ids), 'response_kind', p_response_kind, 'source', p_source
    ))
  );
  if v_claim->>'disposition' = 'replay' then return v_claim->'result_payload'; end if;
  v_receipt_id := (v_claim->>'receipt_id')::uuid;

  perform 1 from public.task_instances t
  where t.household_id = p_household_id and t.id = any(p_task_ids)
  order by t.id for update;

  if (select count(*) from public.task_instances t
      where t.household_id = p_household_id
        and t.id = any(p_task_ids)
        and t.scheduled_date = p_target_local_date
        and t.test_context_id is not distinct from p_test_context_id) <> array_length(p_task_ids, 1) then
    raise exception 'RECONCILIATION_SCOPE_CONFLICT';
  end if;

  insert into public.task_reconciliation_sessions (
    household_id, actor_ref_id, target_local_date, group_key,
    response_kind, source, test_context_id
  ) values (
    p_household_id, p_actor_ref_id, p_target_local_date, p_group_key,
    p_response_kind, p_source, p_test_context_id
  ) returning id into v_session_id;

  v_actor_user_id := private.fn_legacy_user_for_actor_ref_v1(p_household_id, p_actor_ref_id, p_test_context_id);
  if p_test_context_id is null then v_compat_user := v_actor_user_id; end if;

  foreach v_task_id in array p_task_ids loop
    v_order := v_order + 1;
    select * into v_task from public.task_instances where id = v_task_id;
    v_observed := case
      when v_task.status = 'completed' then 'completed'
      when v_task.status in ('skipped', 'cancelled') then 'explicit_exception'
      else 'unknown'
    end;

    if p_response_kind = 'all_done'
       and v_task.status in ('todo', 'in_progress')
       and v_task.attention_state = 'active'
       and coalesce(v_task.expectation, 'normal') <> 'optional'
       and (
         (v_task.assignment_mode = 'person' and v_task.planned_assignee_actor_ref_id = p_actor_ref_id)
         or v_task.active_claimant_actor_ref_id = p_actor_ref_id
       )
       and (v_task.completion_mode = 'whole' or not exists (
         select 1 from public.task_subtask_instances s
         where s.household_id = p_household_id and s.task_instance_id = v_task.id
           and s.required and not s.is_completed
       )) then
      if p_test_context_id is null and v_compat_user is null then
        raise exception 'PRODUCTION_WHOLE_COMPLETION_REQUIRES_REAL_COMPATIBILITY_PERFORMER';
      end if;

      update public.task_instances
      set status = 'completed', completed_at = now(),
          actual_completed_by_id = case when completion_mode = 'whole' and p_test_context_id is null then v_compat_user else null end,
          active_claimant_actor_ref_id = null, claimed_at = null,
          attention_state = 'active', waiting_note = null, next_check_at = null,
          outcome_reason = null, revision = revision + 1
      where id = v_task.id;

      insert into public.task_actual_participants (
        household_id, task_instance_id, actor_ref_id, recorded_by_actor_ref_id,
        compatibility_primary, source, test_context_id
      ) values (
        p_household_id, v_task.id, p_actor_ref_id, p_actor_ref_id,
        p_test_context_id is null and v_task.completion_mode = 'whole',
        'canonical', p_test_context_id
      );

      insert into public.task_events (
        household_id, task_instance_id, actor_id, actor_ref_id, test_context_id,
        event_type, payload, source, idempotency_key
      ) values (
        p_household_id, v_task.id, v_actor_user_id, p_actor_ref_id, p_test_context_id,
        'completed', jsonb_build_object('via', 'reconciliation', 'session_id', v_session_id),
        p_source, 'canonical:' || p_operation_id::text || ':' || v_task.id::text
      );
      v_observed := 'completed';
      v_completed := v_completed + 1;
    end if;

    insert into public.task_reconciliation_session_items (
      household_id, session_id, task_instance_id, observed_state,
      display_order, test_context_id
    ) values (
      p_household_id, v_session_id, v_task.id, v_observed, v_order, p_test_context_id
    );
  end loop;

  v_result := jsonb_build_object(
    'session_id', v_session_id,
    'response_kind', p_response_kind,
    'snapshot_count', array_length(p_task_ids, 1),
    'completed_count', v_completed
  );
  perform private.fn_complete_canonical_operation_v1(v_receipt_id, 'reconciliation', v_session_id, v_result);
  return v_result;
end;
$$;
revoke all on function private.fn_command_reconcile_task_group_v1(uuid, uuid, uuid, uuid, date, text, uuid[], text, uuid, text) from public, anon, authenticated;
grant execute on function private.fn_command_reconcile_task_group_v1(uuid, uuid, uuid, uuid, date, text, uuid[], text, uuid, text) to service_role;

-- ---------------------------------------------------------------------------
-- Information acknowledgement + superseding correction
-- ---------------------------------------------------------------------------

create or replace function private.fn_command_ack_info_v1(
  p_household_id uuid,
  p_operator_user_id uuid,
  p_actor_ref_id uuid,
  p_test_context_id uuid,
  p_handover_id uuid,
  p_operation_id uuid
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_claim jsonb;
  v_receipt_id uuid;
  v_info public.handovers%rowtype;
  v_result jsonb;
begin
  v_claim := private.fn_claim_canonical_operation_v1(
    p_household_id, p_operator_user_id, p_actor_ref_id, p_test_context_id,
    p_operation_id, 'info.ack',
    private.fn_canonical_request_hash_v1(jsonb_build_object('handover_id', p_handover_id))
  );
  if v_claim->>'disposition' = 'replay' then return v_claim->'result_payload'; end if;
  v_receipt_id := (v_claim->>'receipt_id')::uuid;

  select * into v_info from public.handovers
  where household_id = p_household_id and id = p_handover_id for share;
  if not found then raise exception 'INFO_NOT_FOUND'; end if;
  if v_info.test_context_id is distinct from p_test_context_id then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
  if v_info.status <> 'active' then raise exception 'INFO_NOT_ACTIVE'; end if;

  insert into public.info_acknowledgements (
    household_id, handover_id, actor_ref_id, test_context_id
  ) values (
    p_household_id, p_handover_id, p_actor_ref_id, p_test_context_id
  ) on conflict do nothing;

  v_result := jsonb_build_object('handover_id', p_handover_id, 'acknowledged', true);
  perform private.fn_complete_canonical_operation_v1(v_receipt_id, 'info', p_handover_id, v_result);
  return v_result;
end;
$$;
revoke all on function private.fn_command_ack_info_v1(uuid, uuid, uuid, uuid, uuid, uuid) from public, anon, authenticated;
grant execute on function private.fn_command_ack_info_v1(uuid, uuid, uuid, uuid, uuid, uuid) to service_role;

create or replace function private.fn_command_correct_info_v1(
  p_household_id uuid,
  p_operator_user_id uuid,
  p_actor_ref_id uuid,
  p_test_context_id uuid,
  p_handover_id uuid,
  p_shared_text text,
  p_expected_revision bigint,
  p_operation_id uuid
) returns jsonb
language plpgsql security definer set search_path = '' as $$
declare
  v_claim jsonb;
  v_receipt_id uuid;
  v_old public.handovers%rowtype;
  v_new_id uuid;
  v_legacy_author uuid;
  v_result jsonb;
begin
  if nullif(btrim(coalesce(p_shared_text, '')), '') is null then raise exception 'INFO_TEXT_REQUIRED'; end if;
  v_claim := private.fn_claim_canonical_operation_v1(
    p_household_id, p_operator_user_id, p_actor_ref_id, p_test_context_id,
    p_operation_id, 'info.correct',
    private.fn_canonical_request_hash_v1(jsonb_build_object(
      'handover_id', p_handover_id, 'shared_text', btrim(p_shared_text),
      'expected_revision', p_expected_revision
    ))
  );
  if v_claim->>'disposition' = 'replay' then return v_claim->'result_payload'; end if;
  v_receipt_id := (v_claim->>'receipt_id')::uuid;

  select * into v_old from public.handovers
  where household_id = p_household_id and id = p_handover_id for update;
  if not found then raise exception 'INFO_NOT_FOUND'; end if;
  if v_old.test_context_id is distinct from p_test_context_id then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
  if v_old.status <> 'active' or v_old.revision <> p_expected_revision then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;

  v_legacy_author := private.fn_legacy_user_for_actor_ref_v1(p_household_id, p_actor_ref_id, p_test_context_id);
  update public.handovers
  set status = 'superseded', revision = revision + 1
  where id = v_old.id;

  insert into public.handovers (
    household_id, author_id, author_actor_ref_id, shared_text, period,
    categories, occurred_on, info_kind, visibility, valid_from, valid_until,
    ack_policy, related_task_id, status, supersedes_handover_id,
    revision, test_context_id
  ) values (
    p_household_id, v_legacy_author, p_actor_ref_id, btrim(p_shared_text), v_old.period,
    v_old.categories, v_old.occurred_on, v_old.info_kind, v_old.visibility,
    now(), v_old.valid_until, v_old.ack_policy, v_old.related_task_id,
    'active', v_old.id, 1, p_test_context_id
  ) returning id into v_new_id;

  v_result := jsonb_build_object(
    'superseded_handover_id', v_old.id,
    'handover_id', v_new_id,
    'revision', 1
  );
  perform private.fn_complete_canonical_operation_v1(v_receipt_id, 'info', v_new_id, v_result);
  return v_result;
end;
$$;
revoke all on function private.fn_command_correct_info_v1(uuid, uuid, uuid, uuid, uuid, text, bigint, uuid) from public, anon, authenticated;
grant execute on function private.fn_command_correct_info_v1(uuid, uuid, uuid, uuid, uuid, text, bigint, uuid) to service_role;
