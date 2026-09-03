-- WP-DD3 command concurrency/replay/reconciliation coverage.
\set ON_ERROR_STOP on
set role service_role;

do $$
declare
  v_operator uuid := gen_random_uuid();
  v_partner uuid := gen_random_uuid();
  v_hh jsonb;
  v_household uuid;
  v_context uuid;
  v_papa uuid;
  v_partner_actor uuid;
  v_mama uuid;
  v_due timestamptz := now() + interval '6 hours';
  v_op uuid := gen_random_uuid();
  v_result jsonb;
  v_replay jsonb;
  v_request uuid;
  v_attempt uuid;
  v_task uuid;
  v_rev bigint;
  v_required uuid;
  v_optional uuid;
  v_mostly uuid;
  v_info uuid;
  v_new_info uuid;
  v_candidate uuid;
  v_prod_task uuid;
begin
  insert into auth.users (id) values (v_operator), (v_partner);
  v_hh := public.server_tx_create_household(
    v_operator, gen_random_uuid(), 'DD3 concurrency ' || v_operator::text, 'Owner'
  );
  v_household := (v_hh->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role)
  values (v_household, v_partner, 'adult');
  perform private.backfill_canonical_foundation_v1();

  select id into v_papa from public.domain_actor_refs
  where household_id = v_household and real_user_id = v_operator;
  select id into v_partner_actor from public.domain_actor_refs
  where household_id = v_household and real_user_id = v_partner;

  insert into public.test_simulation_contexts (household_id, operator_user_id, label)
  values (v_household, v_operator, 'concurrency') returning id into v_context;
  insert into public.domain_actor_refs (household_id, actor_kind, test_context_id, simulated_role)
  values (v_household, 'simulated_member', v_context, 'mama') returning id into v_mama;

  -- Exact operation replay is stable; same operation ID with different payload
  -- is an explicit idempotency conflict.
  v_result := private.fn_command_create_light_request_v1(
    v_household, v_operator, v_papa, v_context, v_mama,
    'replay-test', null, v_due, v_op, 'pwa'
  );
  v_request := (v_result->>'request_id')::uuid;
  v_attempt := (v_result->>'attempt_id')::uuid;
  v_replay := private.fn_command_create_light_request_v1(
    v_household, v_operator, v_papa, v_context, v_mama,
    'replay-test', null, v_due, v_op, 'pwa'
  );
  if (v_replay->>'request_id')::uuid <> v_request then
    raise exception 'FAIL dd3: exact operation replay changed request identity';
  end if;

  begin
    perform private.fn_command_create_light_request_v1(
      v_household, v_operator, v_papa, v_context, v_mama,
      'different-payload', null, v_due, v_op, 'pwa'
    );
    raise exception 'FAIL dd3: idempotency conflict was accepted';
  exception when others then
    if sqlerrm not like '%IDEMPOTENCY_CONFLICT%' then raise; end if;
  end;

  perform private.fn_command_transition_request_attempt_v1(
    v_household, v_operator, v_mama, v_context,
    v_request, v_attempt, 'checking', null, 1, 1, gen_random_uuid(), 'line'
  );
  begin
    perform private.fn_command_transition_request_attempt_v1(
      v_household, v_operator, v_mama, v_context,
      v_request, v_attempt, 'accept', null, 1, 1, gen_random_uuid(), 'line'
    );
    raise exception 'FAIL dd3: stale Request Attempt revision was accepted';
  exception when others then
    if sqlerrm not like '%REQUEST_ATTEMPT_STALE%' then raise; end if;
  end;

  v_result := private.fn_command_transition_request_attempt_v1(
    v_household, v_operator, v_mama, v_context,
    v_request, v_attempt, 'accept', null, 2, 1, gen_random_uuid(), 'line'
  );
  v_task := (v_result->>'linked_task_id')::uuid;

  -- Waiting update stale protection and explicit resume.
  select revision into v_rev from public.task_instances where id = v_task;
  perform private.fn_command_task_waiting_v1(
    v_household, v_operator, v_mama, v_context, v_task,
    'set', '返事待ち', now() + interval '1 hour', v_rev, gen_random_uuid(), 'pwa'
  );
  begin
    perform private.fn_command_task_waiting_v1(
      v_household, v_operator, v_mama, v_context, v_task,
      'update', 'stale', now() + interval '2 hours', v_rev, gen_random_uuid(), 'pwa'
    );
    raise exception 'FAIL dd3: stale waiting update was accepted';
  exception when others then
    if sqlerrm not like '%AGGREGATE_REVISION_CONFLICT%' then raise; end if;
  end;
  select revision into v_rev from public.task_instances where id = v_task;
  perform private.fn_command_task_waiting_v1(
    v_household, v_operator, v_mama, v_context, v_task,
    'resume', null, null, v_rev, gen_random_uuid(), 'pwa'
  );
  if (select attention_state from public.task_instances where id = v_task) <> 'active' then
    raise exception 'FAIL dd3: waiting resume did not restore active attention';
  end if;

  -- Responsibility change cannot silently move another person's assignment
  -- unless the caller declares already-coordinated agreement.
  select revision into v_rev from public.task_instances where id = v_task;
  begin
    perform private.fn_command_change_task_assignment_v1(
      v_household, v_operator, v_papa, v_context, v_task,
      'person', v_papa, false, v_rev, gen_random_uuid(), 'pwa'
    );
    raise exception 'FAIL dd3: responsibility change bypassed agreement guard';
  exception when others then
    if sqlerrm not like '%ASSIGNMENT_AGREEMENT_REQUIRED%' then raise; end if;
  end;
  if (select revision from public.task_instances where id = v_task) <> v_rev
     or (select planned_assignee_actor_ref_id from public.task_instances where id = v_task) <> v_mama then
    raise exception 'FAIL dd3: rejected assignment change partially mutated aggregate';
  end if;

  perform private.fn_command_change_task_assignment_v1(
    v_household, v_operator, v_papa, v_context, v_task,
    'person', v_papa, true, v_rev, gen_random_uuid(), 'pwa'
  );

  -- Completion writes participant + audit atomically; correction preserves old
  -- participant evidence instead of overwriting it.
  select revision into v_rev from public.task_instances where id = v_task;
  perform private.fn_command_complete_task_v1(
    v_household, v_operator, v_mama, v_context, v_task,
    array[v_mama]::uuid[], v_rev, gen_random_uuid(), 'line'
  );
  select revision into v_rev from public.task_instances where id = v_task;
  perform private.fn_command_correct_task_actual_v1(
    v_household, v_operator, v_papa, v_context, v_task,
    array[v_papa]::uuid[], v_rev, gen_random_uuid(), 'pwa'
  );
  if not exists (
    select 1 from public.task_actual_participants
    where task_instance_id = v_task and actor_ref_id = v_mama and removed_at is not null
  ) or not exists (
    select 1 from public.task_actual_participants
    where task_instance_id = v_task and actor_ref_id = v_papa and removed_at is null
  ) then
    raise exception 'FAIL dd3: actual correction overwrote/lost participant history';
  end if;

  select revision into v_rev from public.task_instances where id = v_task;
  begin
    perform private.fn_command_task_claim_v1(
      v_household, v_operator, v_mama, v_context, v_task,
      'claim', null, null, v_rev, gen_random_uuid(), 'pwa'
    );
    raise exception 'FAIL dd3: completed Task was claimable';
  exception when others then
    if sqlerrm not like '%TASK_ALREADY_COMPLETED%' then raise; end if;
  end;

  -- Group all_done completes only eligible required work. mostly_done is
  -- evidence-only and must not mutate child status.
  insert into public.task_instances (
    household_id, origin, title, category, routine_phase, scheduled_date,
    completion_mode, status, source, created_by, assignment_mode,
    assignment_source, planned_assignee_actor_ref_id, expectation, test_context_id
  ) values
    (v_household, 'manual', 'required-group', 'other', 'anytime', (now() at time zone 'Asia/Tokyo')::date,
     'whole', 'todo', 'dd3_test', v_operator, 'person', 'manual', v_mama, 'required', v_context),
    (v_household, 'manual', 'optional-group', 'other', 'anytime', (now() at time zone 'Asia/Tokyo')::date,
     'whole', 'todo', 'dd3_test', v_operator, 'person', 'manual', v_mama, 'optional', v_context),
    (v_household, 'manual', 'mostly-group', 'other', 'anytime', (now() at time zone 'Asia/Tokyo')::date,
     'whole', 'todo', 'dd3_test', v_operator, 'person', 'manual', v_mama, 'required', v_context);
  select id into v_required from public.task_instances
    where household_id = v_household and title = 'required-group' and test_context_id = v_context;
  select id into v_optional from public.task_instances
    where household_id = v_household and title = 'optional-group' and test_context_id = v_context;
  select id into v_mostly from public.task_instances
    where household_id = v_household and title = 'mostly-group' and test_context_id = v_context;

  v_result := private.fn_command_reconcile_task_group_v1(
    v_household, v_operator, v_mama, v_context,
    (now() at time zone 'Asia/Tokyo')::date, 'group:all',
    array[v_required, v_optional]::uuid[], 'all_done', gen_random_uuid(), 'line'
  );
  if (v_result->>'completed_count')::int <> 1
     or (select status from public.task_instances where id = v_required) <> 'completed'
     or (select status from public.task_instances where id = v_optional) <> 'todo' then
    raise exception 'FAIL dd3: all_done eligibility semantics are wrong';
  end if;

  v_result := private.fn_command_reconcile_task_group_v1(
    v_household, v_operator, v_mama, v_context,
    (now() at time zone 'Asia/Tokyo')::date, 'group:mostly',
    array[v_mostly]::uuid[], 'mostly_done', gen_random_uuid(), 'line'
  );
  if (v_result->>'completed_count')::int <> 0
     or (select status from public.task_instances where id = v_mostly) <> 'todo' then
    raise exception 'FAIL dd3: mostly_done mutated child task';
  end if;

  -- Explicit skipped meaning is persisted, never guessed.
  select revision into v_rev from public.task_instances where id = v_optional;
  perform private.fn_command_skip_task_v1(
    v_household, v_operator, v_mama, v_context, v_optional,
    'not_needed_this_occurrence', v_rev, gen_random_uuid(), 'pwa'
  );
  if (select outcome_reason from public.task_instances where id = v_optional)
       <> 'not_needed_this_occurrence' then
    raise exception 'FAIL dd3: skipped outcome meaning was lost';
  end if;

  -- Info ack is ActorRef-native; correction supersedes instead of rewriting.
  insert into public.handovers (
    household_id, author_id, author_actor_ref_id, shared_text, period,
    categories, occurred_on, info_kind, ack_policy, test_context_id
  ) values (
    v_household, null, v_mama, 'タオル必要', 'day', array['school'],
    (now() at time zone 'Asia/Tokyo')::date, 'share', 'required', v_context
  ) returning id into v_info;
  perform private.fn_command_ack_info_v1(
    v_household, v_operator, v_papa, v_context, v_info, gen_random_uuid()
  );
  v_result := private.fn_command_correct_info_v1(
    v_household, v_operator, v_mama, v_context,
    v_info, 'フェイスタオル必要', 1, gen_random_uuid()
  );
  v_new_info := (v_result->>'handover_id')::uuid;
  if (select status from public.handovers where id = v_info) <> 'superseded'
     or (select supersedes_handover_id from public.handovers where id = v_new_info) <> v_info then
    raise exception 'FAIL dd3: information correction did not preserve supersession chain';
  end if;

  -- Candidate rejection/stale resolution works. Generic accept is fail-closed
  -- until target-specific revision/hash adapters exist.
  insert into public.change_candidates (
    household_id, target_type, target_id, source_type, source_ref,
    proposed_patch, test_context_id
  ) values (
    v_household, 'task', v_mostly, 'ai_inference', 'test-candidate',
    jsonb_build_object('title', 'proposal'), v_context
  ) returning id into v_candidate;
  perform private.fn_command_resolve_change_candidate_v1(
    v_household, v_operator, v_mama, v_context, v_candidate,
    'reject', 1, gen_random_uuid(), 'pwa'
  );
  if (select status from public.change_candidates where id = v_candidate) <> 'rejected' then
    raise exception 'FAIL dd3: candidate reject did not resolve';
  end if;

  insert into public.change_candidates (
    household_id, target_type, target_id, source_type, source_ref,
    proposed_patch, test_context_id
  ) values (
    v_household, 'task', v_mostly, 'ai_inference', 'test-blind-accept',
    jsonb_build_object('title', 'must-not-apply'), v_context
  ) returning id into v_candidate;
  begin
    perform private.fn_command_resolve_change_candidate_v1(
      v_household, v_operator, v_mama, v_context, v_candidate,
      'accept', 1, gen_random_uuid(), 'pwa'
    );
    raise exception 'FAIL dd3: generic candidate blind accept was enabled';
  exception when others then
    if sqlerrm not like '%CANDIDATE_ACCEPT_TARGET_ADAPTER_NOT_ENABLED%' then raise; end if;
  end;

  -- Production whole completion retains exactly one technical real-user
  -- compatibility-primary while canonical participant is still the truth.
  insert into public.task_instances (
    household_id, origin, title, category, routine_phase, scheduled_date,
    planned_assignee_id, completion_mode, status, source, created_by,
    assignment_mode, assignment_source, planned_assignee_actor_ref_id
  ) values (
    v_household, 'manual', 'production-compat', 'other', 'anytime',
    (now() at time zone 'Asia/Tokyo')::date, v_operator,
    'whole', 'todo', 'dd3_prod_test', v_operator,
    'person', 'manual', v_papa
  ) returning id into v_prod_task;
  perform private.fn_command_complete_task_v1(
    v_household, v_operator, v_papa, null, v_prod_task,
    array[v_papa]::uuid[], 1, gen_random_uuid(), 'pwa'
  );
  if (select actual_completed_by_id from public.task_instances where id = v_prod_task) <> v_operator
     or not exists (
       select 1 from public.task_actual_participants
       where task_instance_id = v_prod_task and actor_ref_id = v_papa
         and compatibility_primary and removed_at is null
     ) then
    raise exception 'FAIL dd3: production compatibility-primary projection invalid';
  end if;

  -- WP-DD2 physical/provider inventories remain executable and exactly match
  -- the 50-table CURRENT-main precondition declaration.
  if (select count(*) from private.canonical_current_main_table_inventory_v1()) <> 50
     or (select count(*) from private.canonical_current_main_table_inventory_v1() where not present) <> 0 then
    raise exception 'FAIL dd2: CURRENT-main 50-table inventory assertion failed';
  end if;
  perform count(*) from private.canonical_google_provider_lifecycle_inventory_v1();
end;
$$;
