-- Canonical detailed-design implementation Batch 1A source-review tests.
\set ON_ERROR_STOP on

set role service_role;
do $$
declare
  v_owner uuid := gen_random_uuid();
  v_partner uuid := gen_random_uuid();
  v_hh jsonb;
  v_hh_id uuid;
  v_task_assigned uuid := gen_random_uuid();
  v_task_completed uuid := gen_random_uuid();
  v_task_unassigned uuid := gen_random_uuid();
  v_test_task uuid := gen_random_uuid();
  v_shop_assigned uuid := gen_random_uuid();
  v_shop_unassigned uuid := gen_random_uuid();
  v_test_context uuid;
  v_sim_mama uuid;
  v_real_actor uuid;
  v_result jsonb;
  v_second jsonb;
  v_request_pending uuid := gen_random_uuid();
  v_request_accepted uuid := gen_random_uuid();
  v_request_declined uuid := gen_random_uuid();
  v_request_cancelled uuid := gen_random_uuid();
  v_request_completed uuid := gen_random_uuid();
  v_issues bigint;
  v_expected_legacy_request_task_gaps bigint;
begin
  -- Generate auth fixture IDs per run so this test can coexist with the full
  -- suite and with reruns in the same local database.
  insert into auth.users (id) values (v_owner), (v_partner);

  v_hh := public.server_tx_create_household(
    v_owner, gen_random_uuid(), 'Canonical Foundation HH ' || v_owner::text,
    'Owner'
  );
  v_hh_id := (v_hh->>'household_id')::uuid;

  insert into public.household_members (household_id, user_id, member_role)
  values (v_hh_id, v_partner, 'adult');

  -- Old-runtime-shaped production tasks: canonical columns intentionally null
  -- until the deterministic helper runs.
  insert into public.task_instances (
    id, household_id, origin, title, category, routine_phase, scheduled_date,
    planned_assignee_id, completion_mode, status, source, created_by
  ) values
    (v_task_assigned, v_hh_id, 'manual', 'Assigned legacy task', 'other', 'anytime', current_date,
      v_owner, 'whole', 'todo', 'test', v_owner),
    (v_task_unassigned, v_hh_id, 'manual', 'Unassigned legacy task', 'other', 'anytime', current_date,
      null, 'whole', 'todo', 'test', v_owner);

  insert into public.task_instances (
    id, household_id, origin, title, category, routine_phase, scheduled_date,
    planned_assignee_id, completion_mode, status, actual_completed_by_id,
    completed_at, source, created_by
  ) values (
    v_task_completed, v_hh_id, 'manual', 'Completed legacy task', 'other', 'anytime', current_date,
    v_owner, 'whole', 'completed', v_owner, now(), 'test', v_owner
  );

  insert into public.task_events (
    household_id, task_instance_id, actor_id, event_type, payload, source
  ) values (
    v_hh_id, v_task_assigned, v_owner, 'reassigned_once', '{}'::jsonb, 'test'
  );

  insert into public.handovers (
    household_id, author_id, shared_text, period, occurred_on
  ) values (v_hh_id, v_owner, 'legacy handover', 'day', current_date);

  insert into public.shopping_items (
    id, household_id, title, purchase_method, status, assignee_id, created_by
  ) values
    (v_shop_assigned, v_hh_id, 'Assigned milk', 'store', 'assigned', v_owner, v_owner),
    (v_shop_unassigned, v_hh_id, 'Unassigned milk', 'store', 'wanted', null, v_owner);

  insert into public.requests (
    id, household_id, requester_id, recipient_id, shared_title, status
  ) values (
    v_request_pending, v_hh_id, v_owner, v_partner,
    'pending legacy request', 'pending'
  );

  insert into public.requests (
    id, household_id, requester_id, recipient_id, shared_title, status, accepted_at
  ) values (
    v_request_accepted, v_hh_id, v_owner, v_partner,
    'accepted legacy request', 'accepted', now()
  );

  insert into public.requests (
    id, household_id, requester_id, recipient_id, shared_title, status, declined_at
  ) values (
    v_request_declined, v_hh_id, v_owner, v_partner,
    'declined legacy request', 'declined', now()
  );

  insert into public.requests (
    id, household_id, requester_id, recipient_id, shared_title, status, cancelled_at
  ) values (
    v_request_cancelled, v_hh_id, v_owner, v_partner,
    'cancelled legacy request', 'cancelled', now()
  );

  insert into public.requests (
    id, household_id, requester_id, recipient_id, shared_title, status, accepted_at, completed_at
  ) values (
    v_request_completed, v_hh_id, v_owner, v_partner,
    'completed legacy request', 'completed', now() - interval '1 minute', now()
  );

  -- Rerun after old-runtime-shaped rows were created. This is required by the
  -- R0/R1 compatibility contract before any future canonical cutover.
  v_result := private.backfill_canonical_foundation_v1();

  select id into v_real_actor
  from public.domain_actor_refs
  where household_id = v_hh_id
    and actor_kind = 'real_user'
    and real_user_id = v_owner;

  if v_real_actor is null then
    raise exception 'FAIL canonical-foundation: real ActorRef missing';
  end if;

  if (select assignment_mode from public.task_instances where id = v_task_assigned) <> 'person'
     or (select planned_assignee_actor_ref_id from public.task_instances where id = v_task_assigned) <> v_real_actor then
    raise exception 'FAIL canonical-foundation: assigned legacy task not mapped to person ActorRef';
  end if;

  if (select assignment_mode from public.task_instances where id = v_task_unassigned) <> 'unassigned'
     or (select planned_assignee_actor_ref_id from public.task_instances where id = v_task_unassigned) is not null then
    raise exception 'FAIL canonical-foundation: null legacy assignment must map to unassigned, never anyone';
  end if;

  if not exists (
    select 1 from public.task_actual_participants
    where task_instance_id = v_task_completed
      and actor_ref_id = v_real_actor
      and compatibility_primary
      and source = 'legacy_backfill'
      and recorded_by_actor_ref_id is null
  ) then
    raise exception 'FAIL canonical-foundation: legacy performer participant missing or recorder was guessed';
  end if;

  if (select actor_ref_id from public.task_events where task_instance_id = v_task_assigned limit 1) <> v_real_actor then
    raise exception 'FAIL canonical-foundation: task event actor not backfilled';
  end if;

  if exists (
    select 1 from public.domain_actor_refs
    where household_id = v_hh_id and actor_kind = 'simulated_member'
  ) then
    raise exception 'FAIL canonical-foundation: production backfill invented simulated actor';
  end if;

  -- Legacy Request lifecycle maps to agreement Attempt without inventing a
  -- Request-execution completion state.
  if (select state from public.request_attempts where request_id = v_request_pending and legacy_backfill) <> 'pending' then
    raise exception 'FAIL canonical-foundation: pending request mapping';
  end if;
  if (select state from public.request_attempts where request_id = v_request_accepted and legacy_backfill) <> 'accepted' then
    raise exception 'FAIL canonical-foundation: accepted request mapping';
  end if;
  if (select state from public.request_attempts where request_id = v_request_completed and legacy_backfill) <> 'accepted' then
    raise exception 'FAIL canonical-foundation: completed legacy request must backfill agreement as accepted';
  end if;
  if (select state from public.request_attempts where request_id = v_request_declined and legacy_backfill) <> 'declined' then
    raise exception 'FAIL canonical-foundation: declined request mapping';
  end if;
  if (select state from public.request_attempts where request_id = v_request_cancelled and legacy_backfill) <> 'cancelled' then
    raise exception 'FAIL canonical-foundation: cancelled request mapping';
  end if;

  if exists (
    select 1 from public.requests
    where household_id = v_hh_id
      and (requester_actor_ref_id is null or recipient_actor_ref_id is null or request_kind is null)
  ) then
    raise exception 'FAIL canonical-foundation: request ActorRef/kind backfill incomplete';
  end if;

  -- R0 convergence: old runtime remains allowed to mutate legacy assignment
  -- columns. The reconciliation report must see the temporary drift and the
  -- helper rerun must converge both Task and Shopping back to unassigned.
  update public.task_instances
  set planned_assignee_id = null
  where id = v_task_assigned;

  update public.shopping_items
  set assignee_id = null, status = 'wanted'
  where id = v_shop_assigned;

  if coalesce((select issue_count from private.canonical_foundation_reconciliation_v1()
               where issue_type = 'task_planned_actor_mismatch'), 0) < 1 then
    raise exception 'FAIL canonical-foundation: R0 task unassignment drift was not detected';
  end if;
  if coalesce((select issue_count from private.canonical_foundation_reconciliation_v1()
               where issue_type = 'shopping_assignee_actor_mismatch'), 0) < 1 then
    raise exception 'FAIL canonical-foundation: R0 shopping unassignment drift was not detected';
  end if;

  v_result := private.backfill_canonical_foundation_v1();

  if (select assignment_mode from public.task_instances where id = v_task_assigned) <> 'unassigned'
     or (select planned_assignee_actor_ref_id from public.task_instances where id = v_task_assigned) is not null
     or (select assignment_source from public.task_instances where id = v_task_assigned) <> 'legacy_snapshot' then
    raise exception 'FAIL canonical-foundation: R0 legacy task unassignment did not converge';
  end if;

  if (select assignment_mode from public.shopping_items where id = v_shop_assigned) <> 'unassigned'
     or (select assignee_actor_ref_id from public.shopping_items where id = v_shop_assigned) is not null then
    raise exception 'FAIL canonical-foundation: R0 legacy shopping unassignment did not converge';
  end if;

  -- Idempotent rerun after convergence: no duplicate identity/Attempt/participant
  -- and no compatibility assignment rewrite is needed.
  v_second := private.backfill_canonical_foundation_v1();
  if coalesce((v_second->>'actor_refs_inserted')::int, -1) <> 0
     or coalesce((v_second->>'request_attempts_inserted')::int, -1) <> 0
     or coalesce((v_second->>'participants_inserted')::int, -1) <> 0
     or coalesce((v_second->>'task_assignment_rows_updated')::int, -1) <> 0
     or coalesce((v_second->>'shopping_rows_updated')::int, -1) <> 0 then
    raise exception 'FAIL canonical-foundation: backfill is not idempotent after R0 convergence: %', v_second;
  end if;

  -- DD1/DD2 inventory reconciliation deliberately reports historical accepted
  -- and completed legacy Requests that still lack an executable linked Task.
  -- R0 backfill must not invent those Tasks: the gap is a pre-P1 migration
  -- prerequisite and is resolved only by an explicitly reviewed later adapter.
  select issue_count into v_expected_legacy_request_task_gaps
  from private.canonical_foundation_reconciliation_v1()
  where issue_type = 'request_accepted_or_completed_missing_linked_task';

  if coalesce(v_expected_legacy_request_task_gaps, 0) <> 2 then
    raise exception 'FAIL canonical-foundation: expected exactly 2 legacy Request→Task pre-P1 gaps, got %',
      coalesce(v_expected_legacy_request_task_gaps, 0);
  end if;

  select sum(issue_count) into v_issues
  from private.canonical_foundation_reconciliation_v1()
  where issue_type <> 'request_accepted_or_completed_missing_linked_task';
  if coalesce(v_issues, 0) <> 0 then
    raise exception 'FAIL canonical-foundation: unexpected reconciliation issues remain: %',
      (select jsonb_object_agg(issue_type, issue_count)
       from private.canonical_foundation_reconciliation_v1()
       where issue_type <> 'request_accepted_or_completed_missing_linked_task');
  end if;

  -- Create a test context + simulated mama. This is schema-only; current
  -- production request/event writers are intentionally not relaxed yet.
  insert into public.test_simulation_contexts (household_id, operator_user_id, label)
  values (v_hh_id, v_owner, 'source-review-test')
  returning id into v_test_context;

  insert into public.domain_actor_refs (
    household_id, actor_kind, test_context_id, simulated_role
  ) values (v_hh_id, 'simulated_member', v_test_context, 'mama')
  returning id into v_sim_mama;

  -- Production rows may never reference a simulated actor.
  begin
    update public.task_instances
    set assignment_mode = 'person', planned_assignee_actor_ref_id = v_sim_mama
    where id = v_task_assigned;
    raise exception 'FAIL canonical-foundation: simulated actor was accepted in production task';
  exception
    when others then
      if sqlerrm <> 'SIMULATED_ACTOR_IN_PRODUCTION_ROW' then
        raise exception 'FAIL canonical-foundation: expected SIMULATED_ACTOR_IN_PRODUCTION_ROW, got %', sqlerrm;
      end if;
  end;

  -- Test-scoped whole completion can keep the legacy real-user performer null.
  insert into public.task_instances (
    id, household_id, origin, title, category, routine_phase, scheduled_date,
    completion_mode, status, actual_completed_by_id, completed_at, source, created_by,
    assignment_mode, test_context_id
  ) values (
    v_test_task, v_hh_id, 'manual', 'Simulated completion', 'other', 'anytime', current_date,
    'whole', 'completed', null, now(), 'test', v_owner,
    'unassigned', v_test_context
  );

  -- A simulated assignee may exist on a test row only with no real-user legacy
  -- compatibility mirror. In particular the operator ID cannot stand in for
  -- simulated mama.
  begin
    update public.task_instances
    set assignment_mode = 'person',
        planned_assignee_actor_ref_id = v_sim_mama,
        planned_assignee_id = v_owner
    where id = v_test_task;
    raise exception 'FAIL canonical-foundation: operator user ID substituted for simulated assignee';
  exception
    when others then
      if sqlerrm <> 'SIMULATED_ACTOR_LEGACY_USER_SUBSTITUTION' then
        raise exception 'FAIL canonical-foundation: expected SIMULATED_ACTOR_LEGACY_USER_SUBSTITUTION, got %', sqlerrm;
      end if;
  end;

  update public.task_instances
  set assignment_mode = 'person',
      planned_assignee_actor_ref_id = v_sim_mama,
      planned_assignee_id = null
  where id = v_test_task;

  if (select planned_assignee_actor_ref_id from public.task_instances where id = v_test_task) <> v_sim_mama
     or (select planned_assignee_id from public.task_instances where id = v_test_task) is not null then
    raise exception 'FAIL canonical-foundation: valid simulated assignee with null legacy mirror was rejected';
  end if;

  -- But production whole completion still requires the CURRENT legacy mirror.
  begin
    insert into public.task_instances (
      household_id, origin, title, category, routine_phase, scheduled_date,
      completion_mode, status, actual_completed_by_id, completed_at, source, created_by,
      assignment_mode
    ) values (
      v_hh_id, 'manual', 'Invalid production completion', 'other', 'anytime', current_date,
      'whole', 'completed', null, now(), 'test', v_owner, 'unassigned'
    );
    raise exception 'FAIL canonical-foundation: production whole completion accepted null legacy performer';
  exception
    when check_violation then null;
  end;

  -- Subtask parent legacy performer remains forbidden even for test rows.
  begin
    insert into public.task_instances (
      household_id, origin, title, category, routine_phase, scheduled_date,
      planned_assignee_id, completion_mode, status, actual_completed_by_id, completed_at,
      source, created_by, assignment_mode, test_context_id
    ) values (
      v_hh_id, 'manual', 'Invalid subtask parent actor', 'other', 'anytime', current_date,
      v_owner, 'subtasks', 'completed', v_owner, now(), 'test',
      v_owner, 'unassigned', v_test_context
    );
    raise exception 'FAIL canonical-foundation: subtask parent accepted legacy actual actor';
  exception
    when check_violation then null;
  end;
end;
$$;

-- New public tables are SELECT-only through RLS; no client DML grants.
do $$
declare
  t text;
  required text[] := array[
    'test_simulation_contexts', 'domain_actor_refs',
    'task_actual_participants', 'task_reconciliation_sessions',
    'task_reconciliation_session_items', 'request_attempts',
    'request_attempt_confirmations', 'info_acknowledgements'
  ];
begin
  foreach t in array required loop
    if not exists (
      select 1 from pg_class c join pg_namespace n on n.oid = c.relnamespace
      where n.nspname = 'public' and c.relname = t and c.relrowsecurity
    ) then
      raise exception 'FAIL canonical-foundation: RLS missing on public.%', t;
    end if;
    if has_table_privilege('authenticated', format('public.%I', t), 'INSERT,UPDATE,DELETE') then
      raise exception 'FAIL canonical-foundation: authenticated has DML on public.%', t;
    end if;
  end loop;
end;
$$;

reset role;
select 'canonical_identity_operational_foundation: PASS' as result;
