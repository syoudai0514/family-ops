-- WP-DD3A + WP-DD3 coherent command E2E.
-- One real operator executes papa + simulated-mama domain actions without fake
-- auth/member identity and without production LINE/Google side effects.
\set ON_ERROR_STOP on

set role service_role;

do $$
declare
  v_operator uuid := gen_random_uuid();
  v_partner uuid := gen_random_uuid();
  v_hh jsonb;
  v_hh_id uuid;
  v_test_context uuid;
  v_papa uuid;
  v_mama uuid;
  v_request_op uuid := gen_random_uuid();
  v_check_op uuid := gen_random_uuid();
  v_accept_op uuid := gen_random_uuid();
  v_wait_op uuid := gen_random_uuid();
  v_resume_op uuid := gen_random_uuid();
  v_complete_op uuid := gen_random_uuid();
  v_request_result jsonb;
  v_replay jsonb;
  v_request_id uuid;
  v_attempt_id uuid;
  v_task_id uuid;
  v_task_revision bigint;
  v_any_task uuid;
  v_takeover_op uuid;
  v_group_task_required uuid;
  v_group_task_optional uuid;
  v_group_result jsonb;
  v_info_id uuid;
  v_info_new_id uuid;
  v_candidate_id uuid;
  v_before_notification_outbox bigint;
  v_before_user_notifications bigint;
  v_before_google_mirrors bigint;
  v_before_google_writes bigint;
  v_after bigint;
  v_inventory_total bigint;
  v_inventory_missing bigint;
begin
  insert into auth.users (id) values (v_operator), (v_partner);

  v_hh := public.server_tx_create_household(
    v_operator, gen_random_uuid(), 'DD3 E2E HH ' || v_operator::text, 'Owner'
  );
  v_hh_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role)
  values (v_hh_id, v_partner, 'adult');

  perform private.backfill_canonical_foundation_v1();
  select id into v_papa
  from public.domain_actor_refs
  where household_id = v_hh_id and actor_kind = 'real_user' and real_user_id = v_operator;

  insert into public.test_simulation_contexts (household_id, operator_user_id, label)
  values (v_hh_id, v_operator, 'DD3 coherent E2E') returning id into v_test_context;
  insert into public.domain_actor_refs (
    household_id, actor_kind, test_context_id, simulated_role
  ) values (
    v_hh_id, 'simulated_member', v_test_context, 'mama'
  ) returning id into v_mama;

  select count(*) into v_before_notification_outbox from private.notification_outbox;
  select count(*) into v_before_user_notifications from public.user_notifications;
  select count(*) into v_before_google_mirrors from private.family_ops_calendar_mirrors;
  select count(*) into v_before_google_writes from private.google_write_operations;

  -- Papa creates a light Request whose semantic recipient is simulated mama.
  v_request_result := private.fn_command_create_light_request_v1(
    v_hh_id, v_operator, v_papa, v_test_context, v_mama,
    '保育園バッグを確認', 'テスト依頼', now() + interval '4 hours',
    v_request_op, 'pwa'
  );
  v_request_id := (v_request_result->>'request_id')::uuid;
  v_attempt_id := (v_request_result->>'attempt_id')::uuid;

  if not exists (
    select 1 from public.requests r
    where r.id = v_request_id
      and r.requester_id = v_operator
      and r.requester_actor_ref_id = v_papa
      and r.recipient_id is null
      and r.recipient_actor_ref_id = v_mama
      and r.test_context_id = v_test_context
      and r.status = 'pending'
  ) then
    raise exception 'FAIL dd3 e2e: simulated request recipient was substituted or lost';
  end if;

  if not exists (
    select 1 from private.test_delivery_outbox d
    where d.test_context_id = v_test_context
      and d.operator_user_id = v_operator
      and d.semantic_actor_ref_id = v_mama
      and d.rendered_payload->>'text' like '🧪 テスト: ママへの通知%'
  ) then
    raise exception 'FAIL dd3 e2e: request did not use synthetic mama delivery';
  end if;

  -- Exact duplicate replays the canonical receipt instead of duplicating rows.
  v_replay := private.fn_command_create_light_request_v1(
    v_hh_id, v_operator, v_papa, v_test_context, v_mama,
    '保育園バッグを確認', 'テスト依頼', (select due_at from public.requests where id = v_request_id),
    v_request_op, 'pwa'
  );
  if (v_replay->>'request_id')::uuid <> v_request_id then
    raise exception 'FAIL dd3 e2e: request receipt replay changed result identity';
  end if;
  if (select count(*) from public.requests where id = v_request_id) <> 1 then
    raise exception 'FAIL dd3 e2e: duplicate request created another row';
  end if;

  -- Simulated mama uses checking then accepts. Legacy compatibility remains a
  -- CHECK-valid tuple while canonical Attempt carries the richer state.
  perform private.fn_command_transition_request_attempt_v1(
    v_hh_id, v_operator, v_mama, v_test_context,
    v_request_id, v_attempt_id, 'checking', null, 1, 1, v_check_op, 'line'
  );
  if (select status from public.requests where id = v_request_id) <> 'pending' then
    raise exception 'FAIL dd3 e2e: checking leaked into legacy Request status';
  end if;

  v_request_result := private.fn_command_transition_request_attempt_v1(
    v_hh_id, v_operator, v_mama, v_test_context,
    v_request_id, v_attempt_id, 'accept', null, 2, 1, v_accept_op, 'line'
  );
  v_task_id := (v_request_result->>'linked_task_id')::uuid;
  if v_task_id is null then
    raise exception 'FAIL dd3 e2e: accepted light request did not create linked task';
  end if;

  if not exists (
    select 1 from public.task_instances t
    where t.id = v_task_id
      and t.origin = 'request'
      and t.planned_assignee_id is null
      and t.planned_assignee_actor_ref_id = v_mama
      and t.assignment_mode = 'person'
      and t.assignment_source = 'agreement'
      and t.test_context_id = v_test_context
  ) then
    raise exception 'FAIL dd3 e2e: linked task did not preserve simulated mama assignment';
  end if;

  -- Same successful accept operation replays before terminal-state validation.
  v_replay := private.fn_command_transition_request_attempt_v1(
    v_hh_id, v_operator, v_mama, v_test_context,
    v_request_id, v_attempt_id, 'accept', null, 2, 1, v_accept_op, 'line'
  );
  if (v_replay->>'linked_task_id')::uuid <> v_task_id then
    raise exception 'FAIL dd3 e2e: accept replay changed linked task';
  end if;

  begin
    perform private.fn_command_transition_request_attempt_v1(
      v_hh_id, v_operator, v_mama, v_test_context,
      v_request_id, v_attempt_id, 'accept', null, 999, 1, v_accept_op, 'line'
    );
    raise exception 'FAIL dd3 e2e: same operation accepted different request hash';
  exception when others then
    if sqlerrm not like '%IDEMPOTENCY_CONFLICT%' then raise; end if;
  end;

  begin
    perform private.fn_command_transition_request_attempt_v1(
      v_hh_id, v_operator, v_mama, v_test_context,
      v_request_id, v_attempt_id, 'decline', null, 3, 1, gen_random_uuid(), 'line'
    );
    raise exception 'FAIL dd3 e2e: terminal accepted attempt reopened';
  exception when others then
    if sqlerrm not like '%REQUEST_ATTEMPT_STALE%' then raise; end if;
  end;

  -- Waiting is orthogonal, revision-safe, and then resumes without changing due.
  select revision into v_task_revision from public.task_instances where id = v_task_id;
  perform private.fn_command_task_waiting_v1(
    v_hh_id, v_operator, v_mama, v_test_context, v_task_id,
    'set', '園からの返事待ち', now() + interval '1 hour',
    v_task_revision, v_wait_op, 'pwa'
  );

  begin
    perform private.fn_command_task_waiting_v1(
      v_hh_id, v_operator, v_mama, v_test_context, v_task_id,
      'update', 'stale', now() + interval '2 hours',
      v_task_revision, gen_random_uuid(), 'pwa'
    );
    raise exception 'FAIL dd3 e2e: stale task waiting update was accepted';
  exception when others then
    if sqlerrm not like '%AGGREGATE_REVISION_CONFLICT%' then raise; end if;
  end;

  select revision into v_task_revision from public.task_instances where id = v_task_id;
  perform private.fn_command_task_waiting_v1(
    v_hh_id, v_operator, v_mama, v_test_context, v_task_id,
    'resume', null, null, v_task_revision, v_resume_op, 'pwa'
  );

  -- Simulated mama completes the Task. actor_id stays NULL and participant
  -- evidence carries the semantic performer/recorder identity.
  select revision into v_task_revision from public.task_instances where id = v_task_id;
  v_request_result := private.fn_command_complete_task_v1(
    v_hh_id, v_operator, v_mama, v_test_context, v_task_id,
    array[v_mama]::uuid[], v_task_revision, v_complete_op, 'line'
  );
  if v_request_result->>'status' <> 'completed' then
    raise exception 'FAIL dd3 e2e: task completion did not complete';
  end if;
  if not exists (
    select 1 from public.task_actual_participants p
    where p.task_instance_id = v_task_id
      and p.actor_ref_id = v_mama
      and p.recorded_by_actor_ref_id = v_mama
      and p.test_context_id = v_test_context
      and p.removed_at is null
  ) then
    raise exception 'FAIL dd3 e2e: simulated performer evidence missing';
  end if;
  if not exists (
    select 1 from public.task_events e
    where e.task_instance_id = v_task_id
      and e.event_type = 'completed'
      and e.actor_id is null
      and e.actor_ref_id = v_mama
      and e.test_context_id = v_test_context
  ) then
    raise exception 'FAIL dd3 e2e: simulated audit actor was replaced by operator';
  end if;
  if (select actual_completed_by_id from public.task_instances where id = v_task_id) is not null then
    raise exception 'FAIL dd3 e2e: test task acquired legacy real-user actual';
  end if;

  v_replay := private.fn_command_complete_task_v1(
    v_hh_id, v_operator, v_mama, v_test_context, v_task_id,
    array[v_mama]::uuid[], v_task_revision, v_complete_op, 'line'
  );
  if (v_replay->>'revision')::bigint <> (v_request_result->>'revision')::bigint then
    raise exception 'FAIL dd3 e2e: task completion replay changed revision';
  end if;

  -- Anyone claim/takeover: simulated mama can hold the claim, and takeover is
  -- guarded by exact expected claimant + aggregate revision.
  insert into public.task_instances (
    household_id, origin, title, category, routine_phase, scheduled_date,
    completion_mode, status, source, created_by, assignment_mode,
    assignment_source, test_context_id
  ) values (
    v_hh_id, 'manual', '誰でもOKタスク', 'other', 'anytime',
    (now() at time zone 'Asia/Tokyo')::date, 'whole', 'todo', 'dd3_test',
    v_operator, 'anyone', 'manual', v_test_context
  ) returning id into v_any_task;

  perform private.fn_command_task_claim_v1(
    v_hh_id, v_operator, v_mama, v_test_context, v_any_task,
    'claim', null, null, 1, gen_random_uuid(), 'pwa'
  );
  if (select active_claimant_actor_ref_id from public.task_instances where id = v_any_task) <> v_mama then
    raise exception 'FAIL dd3 e2e: simulated mama could not claim anyone task';
  end if;

  v_takeover_op := gen_random_uuid();
  perform private.fn_command_task_claim_v1(
    v_hh_id, v_operator, v_papa, v_test_context, v_any_task,
    'takeover', v_papa, v_mama, 2, v_takeover_op, 'pwa'
  );
  if (select active_claimant_actor_ref_id from public.task_instances where id = v_any_task) <> v_papa then
    raise exception 'FAIL dd3 e2e: claim takeover did not change claimant';
  end if;
  if not exists (
    select 1 from private.test_delivery_outbox
    where test_context_id = v_test_context
      and semantic_actor_ref_id = v_mama
      and rendered_payload->>'notification_kind' = 'task.claim_taken_over'
  ) then
    raise exception 'FAIL dd3 e2e: takeover notification escaped synthetic adapter';
  end if;

  -- Group all_done mutates only eligible items; optional item remains open.
  insert into public.task_instances (
    household_id, origin, title, category, routine_phase, scheduled_date,
    completion_mode, status, source, created_by, assignment_mode,
    assignment_source, planned_assignee_actor_ref_id, expectation, test_context_id
  ) values
    (v_hh_id, 'manual', '必須グループ', 'other', 'anytime', (now() at time zone 'Asia/Tokyo')::date,
     'whole', 'todo', 'dd3_test', v_operator, 'person', 'manual', v_mama, 'required', v_test_context),
    (v_hh_id, 'manual', '余力グループ', 'other', 'anytime', (now() at time zone 'Asia/Tokyo')::date,
     'whole', 'todo', 'dd3_test', v_operator, 'person', 'manual', v_mama, 'optional', v_test_context)
  returning id into v_group_task_required;
  -- Multi-row RETURNING assigns only the final row in PL/pgSQL, so recover IDs by title.
  select id into v_group_task_required from public.task_instances
    where household_id = v_hh_id and title = '必須グループ' and test_context_id = v_test_context order by created_at desc limit 1;
  select id into v_group_task_optional from public.task_instances
    where household_id = v_hh_id and title = '余力グループ' and test_context_id = v_test_context order by created_at desc limit 1;

  v_group_result := private.fn_command_reconcile_task_group_v1(
    v_hh_id, v_operator, v_mama, v_test_context,
    (now() at time zone 'Asia/Tokyo')::date, 'dd3:e2e',
    array[v_group_task_required, v_group_task_optional]::uuid[],
    'all_done', gen_random_uuid(), 'line'
  );
  if (v_group_result->>'completed_count')::int <> 1 then
    raise exception 'FAIL dd3 e2e: group completion count ignored eligibility';
  end if;
  if (select status from public.task_instances where id = v_group_task_required) <> 'completed'
     or (select status from public.task_instances where id = v_group_task_optional) <> 'todo' then
    raise exception 'FAIL dd3 e2e: all_done completed optional task or missed required task';
  end if;

  -- Information acknowledgement is separate from task completion, and a
  -- correction creates a superseding immutable row rather than overwriting it.
  insert into public.handovers (
    household_id, author_id, author_actor_ref_id, shared_text, period, categories,
    occurred_on, info_kind, ack_policy, test_context_id
  ) values (
    v_hh_id, null, v_mama, '明日はタオルが必要', 'day', array['school'],
    (now() at time zone 'Asia/Tokyo')::date, 'share', 'required', v_test_context
  ) returning id into v_info_id;

  perform private.fn_command_ack_info_v1(
    v_hh_id, v_operator, v_papa, v_test_context, v_info_id, gen_random_uuid()
  );
  if not exists (
    select 1 from public.info_acknowledgements
    where handover_id = v_info_id and actor_ref_id = v_papa and test_context_id = v_test_context
  ) then
    raise exception 'FAIL dd3 e2e: canonical information acknowledgement missing';
  end if;

  v_request_result := private.fn_command_correct_info_v1(
    v_hh_id, v_operator, v_mama, v_test_context,
    v_info_id, '明日はフェイスタオルが必要', 1, gen_random_uuid()
  );
  v_info_new_id := (v_request_result->>'handover_id')::uuid;
  if (select status from public.handovers where id = v_info_id) <> 'superseded'
     or (select status from public.handovers where id = v_info_new_id) <> 'active'
     or (select author_id from public.handovers where id = v_info_new_id) is not null
     or (select author_actor_ref_id from public.handovers where id = v_info_new_id) <> v_mama then
    raise exception 'FAIL dd3 e2e: info correction rewrote history or substituted actor';
  end if;

  -- Candidate rejection is revision-safe. Generic accept remains deliberately
  -- fail-closed until the target-specific transaction adapter exists.
  insert into public.change_candidates (
    household_id, target_type, target_id, source_type, source_ref,
    proposed_patch, status, test_context_id
  ) values (
    v_hh_id, 'task', v_any_task, 'ai_inference', 'dd3-e2e',
    jsonb_build_object('title', 'blind patch must not apply'), 'pending', v_test_context
  ) returning id into v_candidate_id;

  perform private.fn_command_resolve_change_candidate_v1(
    v_hh_id, v_operator, v_mama, v_test_context, v_candidate_id,
    'reject', 1, gen_random_uuid(), 'pwa'
  );
  if (select status from public.change_candidates where id = v_candidate_id) <> 'rejected' then
    raise exception 'FAIL dd3 e2e: candidate rejection not persisted';
  end if;

  insert into public.change_candidates (
    household_id, target_type, target_id, source_type, source_ref,
    proposed_patch, status, test_context_id
  ) values (
    v_hh_id, 'task', v_any_task, 'ai_inference', 'dd3-e2e-accept',
    jsonb_build_object('title', 'must fail closed'), 'pending', v_test_context
  ) returning id into v_candidate_id;
  begin
    perform private.fn_command_resolve_change_candidate_v1(
      v_hh_id, v_operator, v_mama, v_test_context, v_candidate_id,
      'accept', 1, gen_random_uuid(), 'pwa'
    );
    raise exception 'FAIL dd3 e2e: generic candidate blind accept was enabled';
  exception when others then
    if sqlerrm not like '%CANDIDATE_ACCEPT_TARGET_ADAPTER_NOT_ENABLED%' then raise; end if;
  end;

  -- Core DD3A invariant: all above test mutations used synthetic delivery only.
  select count(*) into v_after from private.notification_outbox;
  if v_after <> v_before_notification_outbox then
    raise exception 'FAIL dd3a: test command wrote production notification_outbox before=% after=%',
      v_before_notification_outbox, v_after;
  end if;
  select count(*) into v_after from public.user_notifications;
  if v_after <> v_before_user_notifications then
    raise exception 'FAIL dd3a: test command wrote production user_notifications before=% after=%',
      v_before_user_notifications, v_after;
  end if;
  select count(*) into v_after from private.family_ops_calendar_mirrors;
  if v_after <> v_before_google_mirrors then
    raise exception 'FAIL dd3a: test task wrote production Google mirror before=% after=%',
      v_before_google_mirrors, v_after;
  end if;
  select count(*) into v_after from private.google_write_operations;
  if v_after <> v_before_google_writes then
    raise exception 'FAIL dd3a: test command wrote Google write operation before=% after=%',
      v_before_google_writes, v_after;
  end if;

  select count(*), count(*) filter (where not present)
    into v_inventory_total, v_inventory_missing
  from private.canonical_current_main_table_inventory_v1();
  if v_inventory_total <> 50 or v_inventory_missing <> 0 then
    raise exception 'FAIL dd2: CURRENT main baseline inventory total=% missing=%',
      v_inventory_total, v_inventory_missing;
  end if;

  -- Provider inventory must be executable without creating/adopting Family Events.
  perform count(*) from private.canonical_google_provider_lifecycle_inventory_v1();
end;
$$;
