-- Canonical detailed-design implementation Batch 1A source-review tests.
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('f1000000-0000-0000-0000-000000000001'),
  ('f1000000-0000-0000-0000-000000000002');

set role service_role;

do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_task_assigned uuid := gen_random_uuid();
  v_task_completed uuid := gen_random_uuid();
  v_task_unassigned uuid := gen_random_uuid();
  v_test_task uuid := gen_random_uuid();
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
begin
  v_hh := public.server_tx_create_household(
    'f1000000-0000-0000-0000-000000000001', gen_random_uuid(),
    'Canonical Foundation HH', 'Owner'
  );
  v_hh_id := (v_hh->>'household_id')::uuid;

  insert into public.household_members (household_id, user_id, member_role)
  values (v_hh_id, 'f1000000-0000-0000-0000-000000000002', 'adult');

  -- Old-runtime-shaped production tasks: canonical columns intentionally null
  -- until the deterministic helper runs.
  insert into public.task_instances (
    id, household_id, origin, title, category, routine_phase, scheduled_date,
    planned_assignee_id, completion_mode, status, source, created_by
  ) values
    (v_task_assigned, v_hh_id, 'manual', 'Assigned legacy task', 'other', 'anytime', current_date,
      'f1000000-0000-0000-0000-000000000001', 'whole', 'todo', 'test', 'f1000000-0000-0000-0000-000000000001'),
    (v_task_unassigned, v_hh_id, 'manual', 'Unassigned legacy task', 'other', 'anytime', current_date,
      null, 'whole', 'todo', 'test', 'f1000000-0000-0000-0000-000000000001');

  insert into public.task_instances (
    id, household_id, origin, title, category, routine_phase, scheduled_date,
    planned_assignee_id, completion_mode, status, actual_completed_by_id,
    completed_at, source, created_by
  ) values (
    v_task_completed, v_hh_id, 'manual', 'Completed legacy task', 'other', 'anytime', current_date,
    'f1000000-0000-0000-0000-000000000001', 'whole', 'completed',
    'f1000000-0000-0000-0000-000000000001', now(), 'test',
    'f1000000-0000-0000-0000-000000000001'
  );

  insert into public.task_events (
    household_id, task_instance_id, actor_id, event_type, payload, source
  ) values (
    v_hh_id, v_task_assigned, 'f1000000-0000-0000-0000-000000000001',
    'reassigned_once', '{}'::jsonb, 'test'
  );

  insert into public.handovers (
    household_id, author_id, shared_text, period, occurred_on
  ) values (
    v_hh_id, 'f1000000-0000-0000-0000-000000000001',
    'legacy handover', 'day', current_date
  );

  insert into public.shopping_items (
    household_id, title, purchase_method, status, assignee_id, created_by
  ) values
    (v_hh_id, 'Assigned milk', 'store', 'assigned', 'f1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000001'),
    (v_hh_id, 'Unassigned milk', 'store', 'wanted', null, 'f1000000-0000-0000-0000-000000000001');

  insert into public.requests (
    id, household_id, requester_id, recipient_id, shared_title, status
  ) values (
    v_request_pending, v_hh_id,
    'f1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000002',
    'pending legacy request', 'pending'
  );

  insert into public.requests (
    id, household_id, requester_id, recipient_id, shared_title, status, accepted_at
  ) values (
    v_request_accepted, v_hh_id,
    'f1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000002',
    'accepted legacy request', 'accepted', now()
  );

  insert into public.requests (
    id, household_id, requester_id, recipient_id, shared_title, status, declined_at
  ) values (
    v_request_declined, v_hh_id,
    'f1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000002',
    'declined legacy request', 'declined', now()
  );

  insert into public.requests (
    id, household_id, requester_id, recipient_id, shared_title, status, cancelled_at
  ) values (
    v_request_cancelled, v_hh_id,
    'f1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000002',
    'cancelled legacy request', 'cancelled', now()
  );

  insert into public.requests (
    id, household_id, requester_id, recipient_id, shared_title, status, accepted_at, completed_at
  ) values (
    v_request_completed, v_hh_id,
    'f1000000-0000-0000-0000-000000000001', 'f1000000-0000-0000-0000-000000000002',
    'completed legacy request', 'completed', now() - interval '1 minute', now()
  );

  -- Rerun after old-runtime-shaped rows were created. This is required by the
  -- R0/R1 compatibility contract before any future canonical cutover.
  v_result := private.backfill_canonical_foundation_v1();

  select id into v_real_actor
  from public.domain_actor_refs
  where household_id = v_hh_id
    and actor_kind = 'real_user'
    and real_user_id = 'f1000000-0000-0000-0000-000000000001';

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

  -- Idempotent rerun: no duplicate identity/Attempt/participant and no second
  -- compatibility rewrite is needed for our fixture.
  v_second := private.backfill_canonical_foundation_v1();
  if coalesce((v_second->>'actor_refs_inserted')::int, -1) <> 0
     or coalesce((v_second->>'request_attempts_inserted')::int, -1) <> 0
     or coalesce((v_second->>'participants_inserted')::int, -1) <> 0 then
    raise exception 'FAIL canonical-foundation: backfill is not idempotent: %', v_second;
  end if;

  select sum(issue_count) into v_issues
  from private.canonical_foundation_reconciliation_v1();
  if coalesce(v_issues, 0) <> 0 then
    raise exception 'FAIL canonical-foundation: reconciliation issues remain: %',
      (select jsonb_object_agg(issue_type, issue_count) from private.canonical_foundation_reconciliation_v1());
  end if;

  -- Create a test context + simulated mama. This is schema-only; current
  -- production request/event writers are intentionally not relaxed yet.
  insert into public.test_simulation_contexts (household_id, operator_user_id, label)
  values (v_hh_id, 'f1000000-0000-0000-0000-000000000001', 'source-review-test')
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
    'whole', 'completed', null, now(), 'test', 'f1000000-0000-0000-0000-000000000001',
    'unassigned', v_test_context
  );

  -- But production whole completion still requires the CURRENT legacy mirror.
  begin
    insert into public.task_instances (
      household_id, origin, title, category, routine_phase, scheduled_date,
      completion_mode, status, actual_completed_by_id, completed_at, source, created_by,
      assignment_mode
    ) values (
      v_hh_id, 'manual', 'Invalid production completion', 'other', 'anytime', current_date,
      'whole', 'completed', null, now(), 'test', 'f1000000-0000-0000-0000-000000000001',
      'unassigned'
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
      'f1000000-0000-0000-0000-000000000001', 'subtasks', 'completed',
      'f1000000-0000-0000-0000-000000000001', now(), 'test',
      'f1000000-0000-0000-0000-000000000001', 'unassigned', v_test_context
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
