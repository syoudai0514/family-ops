-- WP-DD3 canonical Task transaction command layer.
--
-- All functions are private + service-role only. No endpoint/capability gate is
-- activated here. Each command uses the WP-DD3A execution context and canonical
-- operation receipt before locking/mutating the aggregate.

create or replace function private.fn_command_complete_task_v1(
  p_household_id uuid,
  p_operator_user_id uuid,
  p_actor_ref_id uuid,
  p_test_context_id uuid,
  p_task_id uuid,
  p_performer_actor_ref_ids uuid[],
  p_expected_revision bigint,
  p_operation_id uuid,
  p_source text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_claim jsonb;
  v_receipt_id uuid;
  v_task public.task_instances%rowtype;
  v_performer uuid;
  v_performer_kind text;
  v_compat_actor_ref uuid;
  v_compat_user_id uuid;
  v_event_actor_user_id uuid;
  v_new_revision bigint;
  v_result jsonb;
  v_notify_actor uuid;
begin
  if p_source not in ('line', 'pwa') then
    raise exception 'COMMAND_SOURCE_INVALID';
  end if;
  if p_performer_actor_ref_ids is null
     or coalesce(array_length(p_performer_actor_ref_ids, 1), 0) = 0 then
    raise exception 'TASK_PERFORMER_REQUIRED';
  end if;
  if exists (
    select 1
    from unnest(p_performer_actor_ref_ids) p(actor_ref_id)
    group by actor_ref_id
    having count(*) > 1
  ) then
    raise exception 'TASK_PERFORMER_DUPLICATE';
  end if;

  v_claim := private.fn_claim_canonical_operation_v1(
    p_household_id,
    p_operator_user_id,
    p_actor_ref_id,
    p_test_context_id,
    p_operation_id,
    'task.complete',
    private.fn_canonical_request_hash_v1(jsonb_build_object(
      'task_id', p_task_id,
      'performers', to_jsonb(p_performer_actor_ref_ids),
      'expected_revision', p_expected_revision,
      'source', p_source
    ))
  );

  if v_claim->>'disposition' = 'replay' then
    return v_claim->'result_payload';
  end if;
  v_receipt_id := (v_claim->>'receipt_id')::uuid;

  select * into v_task
  from public.task_instances
  where household_id = p_household_id and id = p_task_id
  for update;

  if not found then
    raise exception 'TASK_NOT_FOUND';
  end if;
  if v_task.test_context_id is distinct from p_test_context_id then
    raise exception 'ACTOR_SCOPE_CONFLICT';
  end if;
  if v_task.revision <> p_expected_revision then
    raise exception 'AGGREGATE_REVISION_CONFLICT';
  end if;
  if v_task.status = 'completed' then
    raise exception 'TASK_ALREADY_COMPLETED';
  end if;
  if v_task.status not in ('todo', 'in_progress') then
    raise exception 'TASK_NOT_OPEN';
  end if;

  if v_task.completion_mode = 'subtasks' and exists (
    select 1
    from public.task_subtask_instances s
    where s.household_id = p_household_id
      and s.task_instance_id = p_task_id
      and s.required
      and not s.is_completed
  ) then
    raise exception 'TASK_SUBTASKS_INCOMPLETE';
  end if;

  foreach v_performer in array p_performer_actor_ref_ids loop
    perform private.fn_assert_actor_ref_scope(
      p_household_id,
      v_performer,
      p_test_context_id
    );
    select actor_kind into v_performer_kind
    from public.domain_actor_refs
    where household_id = p_household_id and id = v_performer;
    if v_performer_kind not in ('real_user', 'simulated_member') then
      raise exception 'TASK_PERFORMER_ACTOR_KIND_INVALID';
    end if;
  end loop;

  if v_task.completion_mode = 'whole' and p_test_context_id is null then
    -- Compatibility-primary is deterministic and product-invisible: recorder if
    -- explicitly declared as performer, otherwise the first declared performer.
    if p_actor_ref_id = any(p_performer_actor_ref_ids) then
      v_compat_actor_ref := p_actor_ref_id;
    else
      v_compat_actor_ref := p_performer_actor_ref_ids[1];
    end if;
    v_compat_user_id := private.fn_legacy_user_for_actor_ref_v1(
      p_household_id,
      v_compat_actor_ref,
      null
    );
    if v_compat_user_id is null then
      raise exception 'PRODUCTION_WHOLE_COMPLETION_REQUIRES_REAL_COMPATIBILITY_PERFORMER';
    end if;
  end if;

  v_event_actor_user_id := private.fn_legacy_user_for_actor_ref_v1(
    p_household_id,
    p_actor_ref_id,
    p_test_context_id
  );

  update public.task_instances
  set status = 'completed',
      completed_at = now(),
      actual_completed_by_id = case
        when completion_mode = 'whole' and p_test_context_id is null then v_compat_user_id
        else null
      end,
      active_claimant_actor_ref_id = null,
      claimed_at = null,
      attention_state = 'active',
      waiting_note = null,
      next_check_at = null,
      outcome_reason = null,
      revision = revision + 1
  where household_id = p_household_id and id = p_task_id
  returning revision into v_new_revision;

  foreach v_performer in array p_performer_actor_ref_ids loop
    insert into public.task_actual_participants (
      household_id,
      task_instance_id,
      actor_ref_id,
      recorded_by_actor_ref_id,
      compatibility_primary,
      source,
      test_context_id
    ) values (
      p_household_id,
      p_task_id,
      v_performer,
      p_actor_ref_id,
      p_test_context_id is null
        and v_task.completion_mode = 'whole'
        and v_performer = v_compat_actor_ref,
      'canonical',
      p_test_context_id
    );
  end loop;

  insert into public.task_events (
    household_id,
    task_instance_id,
    actor_id,
    actor_ref_id,
    test_context_id,
    event_type,
    payload,
    source,
    idempotency_key
  ) values (
    p_household_id,
    p_task_id,
    v_event_actor_user_id,
    p_actor_ref_id,
    p_test_context_id,
    'completed',
    jsonb_build_object(
      'performer_actor_ref_ids', to_jsonb(p_performer_actor_ref_ids),
      'previous_revision', v_task.revision,
      'revision', v_new_revision
    ),
    p_source,
    'canonical:' || p_operation_id::text
  );

  -- Only behavior-changing duplicate-sensitive completion creates an immediate
  -- neutral notification intent. Normal chores stay quiet.
  if coalesce(v_task.duplicate_sensitivity, 'normal') <> 'normal' then
    if v_task.planned_assignee_actor_ref_id is not null
       and v_task.planned_assignee_actor_ref_id <> p_actor_ref_id then
      v_notify_actor := v_task.planned_assignee_actor_ref_id;
    elsif p_test_context_id is not null then
      select a.id into v_notify_actor
      from public.domain_actor_refs a
      where a.household_id = p_household_id
        and a.actor_kind = 'real_user'
        and a.real_user_id = p_operator_user_id
        and a.id <> p_actor_ref_id
      limit 1;
    else
      select a.id into v_notify_actor
      from public.domain_actor_refs a
      where a.household_id = p_household_id
        and a.actor_kind = 'real_user'
        and a.id <> p_actor_ref_id
      order by a.created_at
      limit 1;
    end if;

    if v_notify_actor is not null then
      perform private.fn_emit_notification_intent_v1(
        p_household_id,
        p_operator_user_id,
        p_actor_ref_id,
        p_test_context_id,
        v_notify_actor,
        'task.completed_neutral',
        '対応済み',
        v_task.title || 'は対応済みです',
        jsonb_build_object('task_id', p_task_id, 'revision', v_new_revision),
        'task:completed:' || p_task_id::text || ':' || v_new_revision::text,
        'immediate',
        coalesce(v_task.duplicate_sensitivity, 'normal'),
        'task:' || p_task_id::text,
        null,
        'task',
        p_task_id,
        v_new_revision
      );
    end if;
  end if;

  v_result := jsonb_build_object(
    'task_id', p_task_id,
    'status', 'completed',
    'revision', v_new_revision,
    'performer_actor_ref_ids', to_jsonb(p_performer_actor_ref_ids)
  );

  perform private.fn_complete_canonical_operation_v1(
    v_receipt_id,
    'task',
    p_task_id,
    v_result
  );

  return v_result;
end;
$$;

revoke all on function private.fn_command_complete_task_v1(
  uuid, uuid, uuid, uuid, uuid, uuid[], bigint, uuid, text
) from public, anon, authenticated;
grant execute on function private.fn_command_complete_task_v1(
  uuid, uuid, uuid, uuid, uuid, uuid[], bigint, uuid, text
) to service_role;

create or replace function private.fn_command_task_waiting_v1(
  p_household_id uuid,
  p_operator_user_id uuid,
  p_actor_ref_id uuid,
  p_test_context_id uuid,
  p_task_id uuid,
  p_waiting_action text,
  p_waiting_note text,
  p_next_check_at timestamptz,
  p_expected_revision bigint,
  p_operation_id uuid,
  p_source text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_claim jsonb;
  v_receipt_id uuid;
  v_task public.task_instances%rowtype;
  v_event_type text;
  v_event_actor_user_id uuid;
  v_new_revision bigint;
  v_result jsonb;
begin
  if p_waiting_action not in ('set', 'update', 'resume') then
    raise exception 'TASK_WAITING_ACTION_INVALID';
  end if;
  if p_source not in ('line', 'pwa') then
    raise exception 'COMMAND_SOURCE_INVALID';
  end if;

  v_claim := private.fn_claim_canonical_operation_v1(
    p_household_id,
    p_operator_user_id,
    p_actor_ref_id,
    p_test_context_id,
    p_operation_id,
    'task.waiting.' || p_waiting_action,
    private.fn_canonical_request_hash_v1(jsonb_build_object(
      'task_id', p_task_id,
      'action', p_waiting_action,
      'waiting_note', p_waiting_note,
      'next_check_at', p_next_check_at,
      'expected_revision', p_expected_revision,
      'source', p_source
    ))
  );
  if v_claim->>'disposition' = 'replay' then
    return v_claim->'result_payload';
  end if;
  v_receipt_id := (v_claim->>'receipt_id')::uuid;

  select * into v_task
  from public.task_instances
  where household_id = p_household_id and id = p_task_id
  for update;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;
  if v_task.test_context_id is distinct from p_test_context_id then
    raise exception 'ACTOR_SCOPE_CONFLICT';
  end if;
  if v_task.revision <> p_expected_revision then
    raise exception 'AGGREGATE_REVISION_CONFLICT';
  end if;
  if v_task.status not in ('todo', 'in_progress') then
    raise exception 'TASK_WAITING_STATE_CONFLICT';
  end if;

  if p_waiting_action = 'resume' then
    if v_task.attention_state <> 'waiting' then
      raise exception 'TASK_WAITING_STATE_CONFLICT';
    end if;
    v_event_type := 'waiting_resumed';
    update public.task_instances
    set attention_state = 'active',
        waiting_note = null,
        next_check_at = null,
        revision = revision + 1
    where household_id = p_household_id and id = p_task_id
    returning revision into v_new_revision;
  else
    if p_waiting_action = 'update' and v_task.attention_state <> 'waiting' then
      raise exception 'TASK_WAITING_STATE_CONFLICT';
    end if;
    v_event_type := case when v_task.attention_state = 'waiting'
      then 'waiting_updated' else 'waiting_started' end;
    update public.task_instances
    set attention_state = 'waiting',
        waiting_note = p_waiting_note,
        next_check_at = p_next_check_at,
        revision = revision + 1
    where household_id = p_household_id and id = p_task_id
    returning revision into v_new_revision;
  end if;

  v_event_actor_user_id := private.fn_legacy_user_for_actor_ref_v1(
    p_household_id, p_actor_ref_id, p_test_context_id
  );

  insert into public.task_events (
    household_id, task_instance_id, actor_id, actor_ref_id, test_context_id,
    event_type, payload, source, idempotency_key
  ) values (
    p_household_id, p_task_id, v_event_actor_user_id, p_actor_ref_id, p_test_context_id,
    v_event_type,
    jsonb_build_object(
      'waiting_note', p_waiting_note,
      'next_check_at', p_next_check_at,
      'previous_revision', v_task.revision,
      'revision', v_new_revision
    ),
    p_source,
    'canonical:' || p_operation_id::text
  );

  v_result := jsonb_build_object(
    'task_id', p_task_id,
    'attention_state', case when p_waiting_action = 'resume' then 'active' else 'waiting' end,
    'revision', v_new_revision,
    'waiting_note', case when p_waiting_action = 'resume' then null else p_waiting_note end,
    'next_check_at', case when p_waiting_action = 'resume' then null else p_next_check_at end
  );

  perform private.fn_complete_canonical_operation_v1(v_receipt_id, 'task', p_task_id, v_result);
  return v_result;
end;
$$;

revoke all on function private.fn_command_task_waiting_v1(
  uuid, uuid, uuid, uuid, uuid, text, text, timestamptz, bigint, uuid, text
) from public, anon, authenticated;
grant execute on function private.fn_command_task_waiting_v1(
  uuid, uuid, uuid, uuid, uuid, text, text, timestamptz, bigint, uuid, text
) to service_role;

create or replace function private.fn_command_task_claim_v1(
  p_household_id uuid,
  p_operator_user_id uuid,
  p_actor_ref_id uuid,
  p_test_context_id uuid,
  p_task_id uuid,
  p_claim_action text,
  p_new_claimant_actor_ref_id uuid,
  p_expected_claimant_actor_ref_id uuid,
  p_expected_revision bigint,
  p_operation_id uuid,
  p_source text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_claim jsonb;
  v_receipt_id uuid;
  v_task public.task_instances%rowtype;
  v_old_claimant uuid;
  v_new_claimant uuid;
  v_event_type text;
  v_event_actor_user_id uuid;
  v_new_revision bigint;
  v_result jsonb;
begin
  if p_claim_action not in ('claim', 'release', 'takeover') then
    raise exception 'TASK_CLAIM_ACTION_INVALID';
  end if;
  if p_source not in ('line', 'pwa') then
    raise exception 'COMMAND_SOURCE_INVALID';
  end if;

  v_claim := private.fn_claim_canonical_operation_v1(
    p_household_id,
    p_operator_user_id,
    p_actor_ref_id,
    p_test_context_id,
    p_operation_id,
    'task.claim.' || p_claim_action,
    private.fn_canonical_request_hash_v1(jsonb_build_object(
      'task_id', p_task_id,
      'action', p_claim_action,
      'new_claimant_actor_ref_id', p_new_claimant_actor_ref_id,
      'expected_claimant_actor_ref_id', p_expected_claimant_actor_ref_id,
      'expected_revision', p_expected_revision,
      'source', p_source
    ))
  );
  if v_claim->>'disposition' = 'replay' then
    return v_claim->'result_payload';
  end if;
  v_receipt_id := (v_claim->>'receipt_id')::uuid;

  select * into v_task
  from public.task_instances
  where household_id = p_household_id and id = p_task_id
  for update;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;
  if v_task.test_context_id is distinct from p_test_context_id then
    raise exception 'ACTOR_SCOPE_CONFLICT';
  end if;
  if v_task.revision <> p_expected_revision then
    raise exception 'AGGREGATE_REVISION_CONFLICT';
  end if;
  if v_task.status = 'completed' then
    raise exception 'TASK_ALREADY_COMPLETED';
  end if;
  if v_task.status not in ('todo', 'in_progress') or v_task.assignment_mode <> 'anyone' then
    raise exception 'TASK_CLAIM_CONFLICT';
  end if;

  v_old_claimant := v_task.active_claimant_actor_ref_id;

  if p_claim_action = 'claim' then
    if v_old_claimant is not null then
      raise exception 'TASK_CLAIM_CONFLICT';
    end if;
    v_new_claimant := p_actor_ref_id;
    v_event_type := 'claim_acquired';
  elsif p_claim_action = 'release' then
    if v_old_claimant is distinct from p_actor_ref_id then
      raise exception 'TASK_CLAIM_CONFLICT';
    end if;
    v_new_claimant := null;
    v_event_type := 'claim_released';
  else
    if v_old_claimant is null
       or p_expected_claimant_actor_ref_id is null
       or v_old_claimant is distinct from p_expected_claimant_actor_ref_id then
      raise exception 'TASK_CLAIM_CONFLICT';
    end if;
    v_new_claimant := coalesce(p_new_claimant_actor_ref_id, p_actor_ref_id);
    if v_new_claimant = v_old_claimant then
      raise exception 'TASK_CLAIM_CONFLICT';
    end if;
    perform private.fn_assert_actor_ref_scope(
      p_household_id, v_new_claimant, p_test_context_id
    );
    v_event_type := 'claim_taken_over';
  end if;

  perform private.fn_assert_actor_ref_scope(
    p_household_id, p_actor_ref_id, p_test_context_id
  );

  update public.task_instances
  set active_claimant_actor_ref_id = v_new_claimant,
      claimed_at = case when v_new_claimant is null then null else now() end,
      revision = revision + 1
  where household_id = p_household_id and id = p_task_id
  returning revision into v_new_revision;

  v_event_actor_user_id := private.fn_legacy_user_for_actor_ref_v1(
    p_household_id, p_actor_ref_id, p_test_context_id
  );

  insert into public.task_events (
    household_id, task_instance_id, actor_id, actor_ref_id, test_context_id,
    event_type, payload, source, idempotency_key
  ) values (
    p_household_id, p_task_id, v_event_actor_user_id, p_actor_ref_id, p_test_context_id,
    v_event_type,
    jsonb_build_object(
      'previous_claimant_actor_ref_id', v_old_claimant,
      'claimant_actor_ref_id', v_new_claimant,
      'previous_revision', v_task.revision,
      'revision', v_new_revision
    ),
    p_source,
    'canonical:' || p_operation_id::text
  );

  if p_claim_action = 'takeover' and v_old_claimant is not null then
    perform private.fn_emit_notification_intent_v1(
      p_household_id,
      p_operator_user_id,
      p_actor_ref_id,
      p_test_context_id,
      v_old_claimant,
      'task.claim_taken_over',
      '担当が変わりました',
      v_task.title || 'の担当が変わりました',
      jsonb_build_object('task_id', p_task_id, 'revision', v_new_revision),
      'task:claim-takeover:' || p_task_id::text || ':' || v_new_revision::text,
      'immediate', 'normal', 'task:' || p_task_id::text,
      null, 'task', p_task_id, v_new_revision
    );
  end if;

  v_result := jsonb_build_object(
    'task_id', p_task_id,
    'assignment_mode', 'anyone',
    'active_claimant_actor_ref_id', v_new_claimant,
    'revision', v_new_revision
  );
  perform private.fn_complete_canonical_operation_v1(v_receipt_id, 'task', p_task_id, v_result);
  return v_result;
end;
$$;

revoke all on function private.fn_command_task_claim_v1(
  uuid, uuid, uuid, uuid, uuid, text, uuid, uuid, bigint, uuid, text
) from public, anon, authenticated;
grant execute on function private.fn_command_task_claim_v1(
  uuid, uuid, uuid, uuid, uuid, text, uuid, uuid, bigint, uuid, text
) to service_role;

create or replace function private.fn_command_change_task_assignment_v1(
  p_household_id uuid,
  p_operator_user_id uuid,
  p_actor_ref_id uuid,
  p_test_context_id uuid,
  p_task_id uuid,
  p_assignment_mode text,
  p_assignee_actor_ref_id uuid,
  p_already_agreed boolean,
  p_expected_revision bigint,
  p_operation_id uuid,
  p_source text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_claim jsonb;
  v_receipt_id uuid;
  v_task public.task_instances%rowtype;
  v_legacy_assignee uuid;
  v_event_actor_user_id uuid;
  v_new_revision bigint;
  v_result jsonb;
begin
  if p_assignment_mode not in ('person', 'unassigned', 'anyone') then
    raise exception 'TASK_ASSIGNMENT_MODE_INVALID';
  end if;
  if (p_assignment_mode = 'person' and p_assignee_actor_ref_id is null)
     or (p_assignment_mode <> 'person' and p_assignee_actor_ref_id is not null) then
    raise exception 'TASK_ASSIGNMENT_SHAPE_INVALID';
  end if;
  if p_source not in ('line', 'pwa') then
    raise exception 'COMMAND_SOURCE_INVALID';
  end if;

  v_claim := private.fn_claim_canonical_operation_v1(
    p_household_id,
    p_operator_user_id,
    p_actor_ref_id,
    p_test_context_id,
    p_operation_id,
    'task.assignment.change',
    private.fn_canonical_request_hash_v1(jsonb_build_object(
      'task_id', p_task_id,
      'assignment_mode', p_assignment_mode,
      'assignee_actor_ref_id', p_assignee_actor_ref_id,
      'already_agreed', p_already_agreed,
      'expected_revision', p_expected_revision,
      'source', p_source
    ))
  );
  if v_claim->>'disposition' = 'replay' then
    return v_claim->'result_payload';
  end if;
  v_receipt_id := (v_claim->>'receipt_id')::uuid;

  select * into v_task
  from public.task_instances
  where household_id = p_household_id and id = p_task_id
  for update;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;
  if v_task.test_context_id is distinct from p_test_context_id then
    raise exception 'ACTOR_SCOPE_CONFLICT';
  end if;
  if v_task.revision <> p_expected_revision then
    raise exception 'AGGREGATE_REVISION_CONFLICT';
  end if;
  if v_task.status not in ('todo', 'in_progress') then
    raise exception 'TASK_NOT_OPEN';
  end if;

  if v_task.assignment_mode = 'person'
     and v_task.planned_assignee_actor_ref_id is not null
     and v_task.planned_assignee_actor_ref_id <> p_actor_ref_id
     and not coalesce(p_already_agreed, false) then
    raise exception 'ASSIGNMENT_AGREEMENT_REQUIRED';
  end if;

  if p_assignee_actor_ref_id is not null then
    perform private.fn_assert_actor_ref_scope(
      p_household_id, p_assignee_actor_ref_id, p_test_context_id
    );
    v_legacy_assignee := private.fn_legacy_user_for_actor_ref_v1(
      p_household_id, p_assignee_actor_ref_id, p_test_context_id
    );
  else
    v_legacy_assignee := null;
  end if;

  update public.task_instances
  set assignment_mode = p_assignment_mode,
      assignment_source = case when coalesce(p_already_agreed, false)
        then 'agreement' else 'manual' end,
      planned_assignee_actor_ref_id = p_assignee_actor_ref_id,
      planned_assignee_id = v_legacy_assignee,
      active_claimant_actor_ref_id = null,
      claimed_at = null,
      revision = revision + 1
  where household_id = p_household_id and id = p_task_id
  returning revision into v_new_revision;

  v_event_actor_user_id := private.fn_legacy_user_for_actor_ref_v1(
    p_household_id, p_actor_ref_id, p_test_context_id
  );

  insert into public.task_events (
    household_id, task_instance_id, actor_id, actor_ref_id, test_context_id,
    event_type, payload, source, idempotency_key
  ) values (
    p_household_id, p_task_id, v_event_actor_user_id, p_actor_ref_id, p_test_context_id,
    case when coalesce(p_already_agreed, false) then 'assignment_agreed' else 'assignment_changed' end,
    jsonb_build_object(
      'previous_assignment_mode', v_task.assignment_mode,
      'previous_assignee_actor_ref_id', v_task.planned_assignee_actor_ref_id,
      'assignment_mode', p_assignment_mode,
      'assignee_actor_ref_id', p_assignee_actor_ref_id,
      'previous_revision', v_task.revision,
      'revision', v_new_revision
    ),
    p_source,
    'canonical:' || p_operation_id::text
  );

  if coalesce(p_already_agreed, false)
     and v_task.planned_assignee_actor_ref_id is not null
     and v_task.planned_assignee_actor_ref_id is distinct from p_assignee_actor_ref_id then
    perform private.fn_emit_notification_intent_v1(
      p_household_id, p_operator_user_id, p_actor_ref_id, p_test_context_id,
      v_task.planned_assignee_actor_ref_id,
      'task.assignment_changed_neutral',
      '担当を更新しました',
      v_task.title || 'の担当を更新しました',
      jsonb_build_object('task_id', p_task_id, 'revision', v_new_revision),
      'task:assignment:' || p_task_id::text || ':' || v_new_revision::text,
      'immediate', coalesce(v_task.duplicate_sensitivity, 'normal'),
      'task:' || p_task_id::text, null, 'task', p_task_id, v_new_revision
    );
  end if;

  v_result := jsonb_build_object(
    'task_id', p_task_id,
    'assignment_mode', p_assignment_mode,
    'planned_assignee_actor_ref_id', p_assignee_actor_ref_id,
    'revision', v_new_revision
  );
  perform private.fn_complete_canonical_operation_v1(v_receipt_id, 'task', p_task_id, v_result);
  return v_result;
end;
$$;

revoke all on function private.fn_command_change_task_assignment_v1(
  uuid, uuid, uuid, uuid, uuid, text, uuid, boolean, bigint, uuid, text
) from public, anon, authenticated;
grant execute on function private.fn_command_change_task_assignment_v1(
  uuid, uuid, uuid, uuid, uuid, text, uuid, boolean, bigint, uuid, text
) to service_role;

create or replace function private.fn_command_correct_task_actual_v1(
  p_household_id uuid,
  p_operator_user_id uuid,
  p_actor_ref_id uuid,
  p_test_context_id uuid,
  p_task_id uuid,
  p_performer_actor_ref_ids uuid[],
  p_expected_revision bigint,
  p_operation_id uuid,
  p_source text
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_claim jsonb;
  v_receipt_id uuid;
  v_task public.task_instances%rowtype;
  v_performer uuid;
  v_compat_actor_ref uuid;
  v_compat_user_id uuid;
  v_event_actor_user_id uuid;
  v_new_revision bigint;
  v_result jsonb;
begin
  if p_performer_actor_ref_ids is null
     or coalesce(array_length(p_performer_actor_ref_ids, 1), 0) = 0 then
    raise exception 'TASK_PERFORMER_REQUIRED';
  end if;
  if p_source not in ('line', 'pwa') then
    raise exception 'COMMAND_SOURCE_INVALID';
  end if;
  if exists (
    select 1 from unnest(p_performer_actor_ref_ids) p(actor_ref_id)
    group by actor_ref_id having count(*) > 1
  ) then
    raise exception 'TASK_PERFORMER_DUPLICATE';
  end if;

  v_claim := private.fn_claim_canonical_operation_v1(
    p_household_id, p_operator_user_id, p_actor_ref_id, p_test_context_id,
    p_operation_id, 'task.actual.correct',
    private.fn_canonical_request_hash_v1(jsonb_build_object(
      'task_id', p_task_id,
      'performers', to_jsonb(p_performer_actor_ref_ids),
      'expected_revision', p_expected_revision,
      'source', p_source
    ))
  );
  if v_claim->>'disposition' = 'replay' then return v_claim->'result_payload'; end if;
  v_receipt_id := (v_claim->>'receipt_id')::uuid;

  select * into v_task
  from public.task_instances
  where household_id = p_household_id and id = p_task_id
  for update;
  if not found then raise exception 'TASK_NOT_FOUND'; end if;
  if v_task.test_context_id is distinct from p_test_context_id then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
  if v_task.revision <> p_expected_revision then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  if v_task.status <> 'completed' then raise exception 'TASK_PERFORMER_CONFLICT'; end if;

  foreach v_performer in array p_performer_actor_ref_ids loop
    perform private.fn_assert_actor_ref_scope(p_household_id, v_performer, p_test_context_id);
  end loop;

  update public.task_actual_participants
  set compatibility_primary = false
  where household_id = p_household_id
    and task_instance_id = p_task_id
    and removed_at is null
    and compatibility_primary;

  if v_task.completion_mode = 'whole' and p_test_context_id is null then
    if p_actor_ref_id = any(p_performer_actor_ref_ids) then
      v_compat_actor_ref := p_actor_ref_id;
    else
      v_compat_actor_ref := p_performer_actor_ref_ids[1];
    end if;
    v_compat_user_id := private.fn_legacy_user_for_actor_ref_v1(
      p_household_id, v_compat_actor_ref, null
    );
    if v_compat_user_id is null then
      raise exception 'PRODUCTION_WHOLE_COMPLETION_REQUIRES_REAL_COMPATIBILITY_PERFORMER';
    end if;
  end if;

  update public.task_instances
  set actual_completed_by_id = case
        when completion_mode = 'whole' and p_test_context_id is null then v_compat_user_id
        else null
      end,
      revision = revision + 1
  where household_id = p_household_id and id = p_task_id
  returning revision into v_new_revision;

  update public.task_actual_participants
  set removed_at = now(),
      removed_by_actor_ref_id = p_actor_ref_id,
      compatibility_primary = false
  where household_id = p_household_id
    and task_instance_id = p_task_id
    and removed_at is null
    and not (actor_ref_id = any(p_performer_actor_ref_ids));

  foreach v_performer in array p_performer_actor_ref_ids loop
    if not exists (
      select 1 from public.task_actual_participants p
      where p.household_id = p_household_id
        and p.task_instance_id = p_task_id
        and p.actor_ref_id = v_performer
        and p.removed_at is null
    ) then
      insert into public.task_actual_participants (
        household_id, task_instance_id, actor_ref_id, recorded_by_actor_ref_id,
        compatibility_primary, source, test_context_id
      ) values (
        p_household_id, p_task_id, v_performer, p_actor_ref_id,
        false, 'canonical', p_test_context_id
      );
    end if;
  end loop;

  if v_compat_actor_ref is not null then
    update public.task_actual_participants
    set compatibility_primary = true
    where household_id = p_household_id
      and task_instance_id = p_task_id
      and actor_ref_id = v_compat_actor_ref
      and removed_at is null;
  end if;

  v_event_actor_user_id := private.fn_legacy_user_for_actor_ref_v1(
    p_household_id, p_actor_ref_id, p_test_context_id
  );
  insert into public.task_events (
    household_id, task_instance_id, actor_id, actor_ref_id, test_context_id,
    event_type, payload, source, idempotency_key
  ) values (
    p_household_id, p_task_id, v_event_actor_user_id, p_actor_ref_id, p_test_context_id,
    'actual_corrected',
    jsonb_build_object(
      'performer_actor_ref_ids', to_jsonb(p_performer_actor_ref_ids),
      'previous_revision', v_task.revision,
      'revision', v_new_revision
    ),
    p_source,
    'canonical:' || p_operation_id::text
  );

  v_result := jsonb_build_object(
    'task_id', p_task_id,
    'status', 'completed',
    'revision', v_new_revision,
    'performer_actor_ref_ids', to_jsonb(p_performer_actor_ref_ids),
    'corrected', true
  );
  perform private.fn_complete_canonical_operation_v1(v_receipt_id, 'task', p_task_id, v_result);
  return v_result;
end;
$$;

revoke all on function private.fn_command_correct_task_actual_v1(
  uuid, uuid, uuid, uuid, uuid, uuid[], bigint, uuid, text
) from public, anon, authenticated;
grant execute on function private.fn_command_correct_task_actual_v1(
  uuid, uuid, uuid, uuid, uuid, uuid[], bigint, uuid, text
) to service_role;
