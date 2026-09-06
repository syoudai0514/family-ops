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
  v_request_accepted_task uuid := gen_random_uuid();
  v_request_completed_task uuid := gen_random_uuid();
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
begin
  insert into auth.users (id) values (v_owner), (v_partner);

  v_hh := public.server_tx_create_household(
    v_owner, gen_random_uuid(), 'Canonical Foundation HH ' || v_owner::text, 'Owner'
  );
  v_hh_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role)
  values (v_hh_id, v_partner, 'adult');

  -- Old-runtime-shaped production Tasks: canonical columns intentionally null
  -- until deterministic backfill runs.
  insert into public.task_instances (
    id, household_id, origin, title, category, routine_phase, scheduled_date,
    planned_assignee_id, completion_mode, status, source, created_by
  ) values
    (v_task_assigned, v_hh_id, 'manual', 'Assigned legacy task', 'other', 'anytime', current_date,
      v_owner, 'whole', 'todo', 'test', v_owner),
    (v_task_unassigned, v_hh_id, 'manual', 'Unassigned legacy task', 'other', 'anytime', current_date,
      null, 'whole', 'todo', 'test', v_owner),
    -- Accepted Request fixture must represent a CURRENT-valid accepted execution
    -- relationship instead of intentionally manufacturing a migration anomaly.
    (v_request_accepted_task, v_hh_id, 'request', 'Accepted request task', 'other', 'anytime', current_date,
      v_partner, 'whole', 'todo', 'request', v_owner);

  insert into public.task_instances (
    id, household_id, origin, title, category, routine_phase, scheduled_date,
    planned_assignee_id, completion_mode, status, actual_completed_by_id,
    completed_at, source, created_by
  ) values
    (v_task_completed, v_hh_id, 'manual', 'Completed legacy task', 'other', 'anytime', current_date,
      v_owner, 'whole', 'completed', v_owner, now(), 'test', v_owner),
    -- Historical completed Request fixture keeps completed execution truth on
    -- its linked Task as required by CURRENT/canonical reconciliation.
    (v_request_completed_task, v_hh_id, 'request', 'Completed request task', 'other', 'anytime', current_date,
      v_partner, 'whole', 'completed', v_partner, now(), 'request', v_owner);

  insert into public.task_events (
    household_id, task_instance_id, actor_id, event_type, payload, source
  ) values (v_hh_id, v_task_assigned, v_owner, 'reassigned_once', '{}'::jsonb, 'test');

  insert into public.handovers (household_id, author_id, shared_text, period, occurred_on)
  values (v_hh_id, v_owner, 'legacy handover', 'day', current_date);

  insert into public.shopping_items (
    id, household_id, title, purchase_method, status, assignee_id, created_by
  ) values
    (v_shop_assigned, v_hh_id, 'Assigned milk', 'store', 'assigned', v_owner, v_owner),
    (v_shop_unassigned, v_hh_id, 'Unassigned milk', 'store', 'wanted', null, v_owner);

  insert into public.requests (
    id, household_id, requester_id, recipient_id, shared_title, status
  ) values (v_request_pending, v_hh_id, v_owner, v_partner, 'pending legacy request', 'pending');

  insert into public.requests (
    id, household_id, requester_id, recipient_id, shared_title, status,
    accepted_at, linked_task_instance_id
  ) values (
    v_request_accepted, v_hh_id, v_owner, v_partner,
    'accepted legacy request', 'accepted', now(), v_request_accepted_task
  );

  insert into public.requests (
    id, household_id, requester_id, recipient_id, shared_title, status, declined_at
  ) values (v_request_declined, v_hh_id, v_owner, v_partner, 'declined legacy request', 'declined', now());

  insert into public.requests (
    id, household_id, requester_id, recipient_id, shared_title, status, cancelled_at
  ) values (v_request_cancelled, v_hh_id, v_owner, v_partner, 'cancelled legacy request', 'cancelled', now());

  insert into public.requests (
    id, household_id, requester_id, recipient_id, shared_title, status,
    accepted_at, completed_at, linked_task_instance_id
  ) values (
    v_request_completed, v_hh_id, v_owner, v_partner,
    'completed legacy request', 'completed', now() - interval '1 minute', now(),
    v_request_completed_task
  );

  v_result := private.backfill_canonical_foundation_v1();

  select id into v_real_actor
  from public.domain_actor_refs
  where household_id = v_hh_id and actor_kind = 'real_user' and real_user_id = v_owner;
  if v_real_actor is null then
    raise exception 'FAIL canonical-foundation: real ActorRef missing';
  end if;

  if (select assignment_mode from public.task_instances where id = v_task_assigned) <> 'person'
     or (select planned_assignee_actor_ref_id from public.task_instances where id = v_task_assigned) <> v_real_actor then
    raise exception 'FAIL canonical-foundation: assigned legacy task not mapped to person ActorRef';
  end if;
  if (select assignment_mode from public.task_instances where id = v_task_unassigned) <> 'unassigned'
     or (select planned_assignee_actor_ref_id from public.task_instances where id = v_task_unassigned) is not null then
    raise exception 'FAIL canonical-foundation: null legacy assignment must map to unassigned';
  end if;

  if not exists (
    select 1 from public.task_actual_participants
    where task_instance_id = v_task_completed and actor_ref_id = v_real_actor
      and compatibility_primary and source = 'legacy_backfill'
      and recorded_by_actor_ref_id is null
  ) then
    raise exception 'FAIL canonical-foundation: legacy performer participant missing or recorder guessed';
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

  if (select state from public.request_attempts where request_id = v_request_pending and legacy_backfill) <> 'pending'
     or (select state from public.request_attempts where request_id = v_request_accepted and legacy_backfill) <> 'accepted'
     or (select state from public.request_attempts where request_id = v_request_completed and legacy_backfill) <> 'accepted'
     or (select state from public.request_attempts where request_id = v_request_declined and legacy_backfill) <> 'declined'
     or (select state from public.request_attempts where request_id = v_request_cancelled and legacy_backfill) <> 'cancelled' then
    raise exception 'FAIL canonical-foundation: Request lifecycle backfill mapping';
  end if;

  if exists (
    select 1 from public.requests
    where household_id = v_hh_id
      and (requester_actor_ref_id is null or recipient_actor_ref_id is null or request_kind is null)
  ) then
    raise exception 'FAIL canonical-foundation: request ActorRef/kind backfill incomplete';
  end if;

  -- R0 coexistence: legacy Task assignment writes are now normalized by the
  -- compatibility trigger in the same transaction. Shopping still exercises
  -- the older reconciliation/backfill path, so both safety mechanisms remain
  -- covered without requiring Task rows to become inconsistent first.
  update public.task_instances set planned_assignee_id = null where id = v_task_assigned;
  update public.shopping_items set assignee_id = null, status = 'wanted' where id = v_shop_assigned;

  if coalesce((select issue_count from private.canonical_foundation_reconciliation_v1()
               where issue_type = 'task_planned_actor_mismatch'), 0) <> 0 then
    raise exception 'FAIL canonical-foundation: legacy Task bridge must prevent unassignment drift';
  end if;
  if (select assignment_mode from public.task_instances where id = v_task_assigned) <> 'unassigned'
     or (select planned_assignee_actor_ref_id from public.task_instances where id = v_task_assigned) is not null
     or (select assignment_source from public.task_instances where id = v_task_assigned) <> 'legacy_snapshot' then
    raise exception 'FAIL canonical-foundation: legacy Task bridge did not converge immediately';
  end if;
  if coalesce((select issue_count from private.canonical_foundation_reconciliation_v1()
               where issue_type = 'shopping_assignee_actor_mismatch'), 0) < 1 then
    raise exception 'FAIL canonical-foundation: shopping unassignment drift not detected';
  end if;

  v_result := private.backfill_canonical_foundation_v1();
  if (select assignment_mode from public.task_instances where id = v_task_assigned) <> 'unassigned'
     or (select planned_assignee_actor_ref_id from public.task_instances where id = v_task_assigned) is not null
     or (select assignment_source from public.task_instances where id = v_task_assigned) <> 'legacy_snapshot' then
    raise exception 'FAIL canonical-foundation: legacy Task bridge/backfill state changed unexpectedly';
  end if;
  if (select assignment_mode from public.shopping_items where id = v_shop_assigned) <> 'unassigned'
     or (select assignee_actor_ref_id from public.shopping_items where id = v_shop_assigned) is not null then
    raise exception 'FAIL canonical-foundation: legacy shopping unassignment did not converge';
  end if;

  v_second := private.backfill_canonical_foundation_v1();
  if coalesce((v_second->>'actor_refs_inserted')::int, -1) <> 0
     or coalesce((v_second->>'request_attempts_inserted')::int, -1) <> 0
     or coalesce((v_second->>'participants_inserted')::int, -1) <> 0
     or coalesce((v_second->>'task_assignment_rows_updated')::int, -1) <> 0
     or coalesce((v_second->>'shopping_rows_updated')::int, -1) <> 0 then
    raise exception 'FAIL canonical-foundation: backfill not idempotent: %', v_second;
  end if;

  -- The fixture itself is valid. Keep anomaly detection strict and require zero
  -- rather than teaching the test to tolerate invalid accepted/completed rows.
  select sum(issue_count) into v_issues
  from private.canonical_foundation_reconciliation_v1();
  if coalesce(v_issues, 0) <> 0 then
    raise exception 'FAIL canonical-foundation: reconciliation issues remain: %',
      (select jsonb_object_agg(issue_type, issue_count)
       from private.canonical_foundation_reconciliation_v1());
  end if;

  insert into public.test_simulation_contexts (household_id, operator_user_id, label)
  values (v_hh_id, v_owner, 'source-review-test') returning id into v_test_context;
  insert into public.domain_actor_refs (household_id, actor_kind, test_context_id, simulated_role)
  values (v_hh_id, 'simulated_member', v_test_context, 'mama') returning id into v_sim_mama;

  begin
    update public.task_instances
    set assignment_mode = 'person', planned_assignee_actor_ref_id = v_sim_mama
    where id = v_task_assigned;
    raise exception 'FAIL canonical-foundation: simulated actor accepted in production task';
  exception when others then
    if sqlerrm <> 'SIMULATED_ACTOR_IN_PRODUCTION_ROW' then raise; end if;
  end;

  insert into public.task_instances (
    id, household_id, origin, title, category, routine_phase, scheduled_date,
    completion_mode, status, actual_completed_by_id, completed_at, source, created_by,
    assignment_mode, test_context_id
  ) values (
    v_test_task, v_hh_id, 'manual', 'Simulated completion', 'other', 'anytime', current_date,
    'whole', 'completed', null, now(), 'test', v_owner, 'unassigned', v_test_context
  );

  begin
    update public.task_instances
    set assignment_mode = 'person', planned_assignee_actor_ref_id = v_sim_mama,
        planned_assignee_id = v_owner
    where id = v_test_task;
    raise exception 'FAIL canonical-foundation: operator substituted for simulated assignee';
  exception when others then
    if sqlerrm <> 'SIMULATED_ACTOR_LEGACY_USER_SUBSTITUTION' then raise; end if;
  end;

  update public.task_instances
  set assignment_mode = 'person', planned_assignee_actor_ref_id = v_sim_mama,
      planned_assignee_id = null
  where id = v_test_task;

  if (select planned_assignee_actor_ref_id from public.task_instances where id = v_test_task) <> v_sim_mama
     or (select planned_assignee_id from public.task_instances where id = v_test_task) is not null then
    raise exception 'FAIL canonical-foundation: valid simulated assignee rejected';
  end if;

  begin
    insert into public.task_instances (
      household_id, origin, title, category, routine_phase, scheduled_date,
      completion_mode, status, actual_completed_by_id, completed_at, source, created_by,
      assignment_mode
    ) values (
      v_hh_id, 'manual', 'Invalid production completion', 'other', 'anytime', current_date,
      'whole', 'completed', null, now(), 'test', v_owner, 'unassigned'
    );
    raise exception 'FAIL canonical-foundation: production completion accepted null legacy performer';
  exception when check_violation then null;
  end;

  begin
    insert into public.task_instances (
      household_id, origin, title, category, routine_phase, scheduled_date,
      planned_assignee_id, completion_mode, status, actual_completed_by_id, completed_at,
      source, created_by, assignment_mode, test_context_id
    ) values (
      v_hh_id, 'manual', 'Invalid subtask parent actor', 'other', 'anytime', current_date,
      v_owner, 'subtasks', 'completed', v_owner, now(), 'test', v_owner,
      'unassigned', v_test_context
    );
    raise exception 'FAIL canonical-foundation: subtask parent accepted legacy actual actor';
  exception when check_violation then null;
  end;
end;
$$;

-- New canonical public tables remain SELECT-only through RLS.
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
