-- Batch 1A source-review remediation tests:
-- - R0 legacy Request lifecycle changes must resynchronise the historical
--   legacy-backfill Attempt and be visible to reconciliation before rerun.
-- - test-scoped Task performer identity must never use the legacy real-user
--   actual_completed_by_id mirror, including the operator user ID.
\set ON_ERROR_STOP on

set role service_role;

do $$
declare
  v_owner uuid := gen_random_uuid();
  v_partner uuid := gen_random_uuid();
  v_hh jsonb;
  v_hh_id uuid;
  v_req_accept uuid := gen_random_uuid();
  v_req_decline uuid := gen_random_uuid();
  v_req_cancel uuid := gen_random_uuid();
  v_accept_at timestamptz := clock_timestamp();
  v_decline_at timestamptz := clock_timestamp() + interval '1 millisecond';
  v_cancel_at timestamptz := clock_timestamp() + interval '2 milliseconds';
  v_result jsonb;
  v_issue_count bigint;
  v_test_context uuid;
  v_sim_mama uuid;
  v_test_task uuid := gen_random_uuid();
begin
  insert into auth.users (id) values (v_owner), (v_partner);

  v_hh := public.server_tx_create_household(
    v_owner,
    gen_random_uuid(),
    'Canonical R0 remediation HH ' || v_owner::text,
    'Owner'
  );
  v_hh_id := (v_hh->>'household_id')::uuid;

  insert into public.household_members (household_id, user_id, member_role)
  values (v_hh_id, v_partner, 'adult');

  -- Three old-runtime Requests all start pending so the first backfill creates
  -- pending legacy-backfill Attempts.
  insert into public.requests (
    id, household_id, requester_id, recipient_id, shared_title, status
  ) values
    (v_req_accept, v_hh_id, v_owner, v_partner, 'R0 accept drift', 'pending'),
    (v_req_decline, v_hh_id, v_owner, v_partner, 'R0 decline drift', 'pending'),
    (v_req_cancel, v_hh_id, v_owner, v_partner, 'R0 cancel drift', 'pending');

  v_result := private.backfill_canonical_foundation_v1();

  if exists (
    select 1
    from public.request_attempts
    where request_id in (v_req_accept, v_req_decline, v_req_cancel)
      and legacy_backfill
      and state <> 'pending'
  ) then
    raise exception 'FAIL canonical-r0-remediation: initial Request attempts were not pending';
  end if;

  -- Simulate normal CURRENT old-runtime lifecycle writes after the initial
  -- backfill. The legacy Request tuple remains authoritative during R0/R1.
  update public.requests
  set status = 'accepted',
      accepted_at = v_accept_at,
      declined_at = null,
      cancelled_at = null,
      completed_at = null
  where id = v_req_accept;

  update public.requests
  set status = 'declined',
      accepted_at = null,
      declined_at = v_decline_at,
      cancelled_at = null,
      completed_at = null
  where id = v_req_decline;

  update public.requests
  set status = 'cancelled',
      accepted_at = null,
      declined_at = null,
      cancelled_at = v_cancel_at,
      completed_at = null
  where id = v_req_cancel;

  select issue_count into v_issue_count
  from private.canonical_foundation_reconciliation_v1()
  where issue_type = 'legacy_request_backfill_attempt_mismatch';

  if coalesce(v_issue_count, 0) <> 3 then
    raise exception 'FAIL canonical-r0-remediation: expected 3 Request drift issues before rerun, got %', v_issue_count;
  end if;

  v_result := private.backfill_canonical_foundation_v1();
  if coalesce((v_result->>'request_attempts_resynced')::int, -1) <> 3 then
    raise exception 'FAIL canonical-r0-remediation: expected 3 Request attempts resynced, got %', v_result;
  end if;

  if not exists (
    select 1
    from public.request_attempts a
    join public.requests r on r.id = a.request_id and r.household_id = a.household_id
    where a.request_id = v_req_accept
      and a.legacy_backfill
      and a.state = 'accepted'
      and a.accepted_at = r.accepted_at
      and a.declined_at is null
      and a.expired_at is null
      and a.cancelled_at is null
      and a.terms = jsonb_build_object('legacy_status', 'accepted')
  ) then
    raise exception 'FAIL canonical-r0-remediation: accepted Request did not converge';
  end if;

  if not exists (
    select 1
    from public.request_attempts a
    join public.requests r on r.id = a.request_id and r.household_id = a.household_id
    where a.request_id = v_req_decline
      and a.legacy_backfill
      and a.state = 'declined'
      and a.accepted_at is null
      and a.declined_at = r.declined_at
      and a.expired_at is null
      and a.cancelled_at is null
      and a.terms = jsonb_build_object('legacy_status', 'declined')
  ) then
    raise exception 'FAIL canonical-r0-remediation: declined Request did not converge';
  end if;

  if not exists (
    select 1
    from public.request_attempts a
    join public.requests r on r.id = a.request_id and r.household_id = a.household_id
    where a.request_id = v_req_cancel
      and a.legacy_backfill
      and a.state = 'cancelled'
      and a.accepted_at is null
      and a.declined_at is null
      and a.expired_at is null
      and a.cancelled_at = r.cancelled_at
      and a.terms = jsonb_build_object('legacy_status', 'cancelled')
  ) then
    raise exception 'FAIL canonical-r0-remediation: cancelled Request did not converge';
  end if;

  select issue_count into v_issue_count
  from private.canonical_foundation_reconciliation_v1()
  where issue_type = 'legacy_request_backfill_attempt_mismatch';
  if coalesce(v_issue_count, 0) <> 0 then
    raise exception 'FAIL canonical-r0-remediation: Request drift remains after rerun: %', v_issue_count;
  end if;

  -- A further rerun must be stable, not continuously rewrite the Attempt.
  v_result := private.backfill_canonical_foundation_v1();
  if coalesce((v_result->>'request_attempts_resynced')::int, -1) <> 0 then
    raise exception 'FAIL canonical-r0-remediation: Request resync is not idempotent: %', v_result;
  end if;

  -- One-user test identity: simulated mama is a domain actor, never a fake
  -- legacy real-user performer. Canonical participant insertion is valid.
  insert into public.test_simulation_contexts (household_id, operator_user_id, label)
  values (v_hh_id, v_owner, 'performer-isolation')
  returning id into v_test_context;

  insert into public.domain_actor_refs (
    household_id, actor_kind, test_context_id, simulated_role
  ) values (
    v_hh_id, 'simulated_member', v_test_context, 'mama'
  ) returning id into v_sim_mama;

  insert into public.task_instances (
    id, household_id, origin, title, category, routine_phase, scheduled_date,
    completion_mode, status, actual_completed_by_id, completed_at,
    source, created_by, assignment_mode, test_context_id
  ) values (
    v_test_task, v_hh_id, 'manual', 'Simulated mama performer', 'other', 'anytime', current_date,
    'whole', 'completed', null, now(),
    'test', v_owner, 'unassigned', v_test_context
  );

  insert into public.task_actual_participants (
    household_id, task_instance_id, actor_ref_id, participation_kind,
    compatibility_primary, source, test_context_id
  ) values (
    v_hh_id, v_test_task, v_sim_mama, 'performed', false, 'canonical', v_test_context
  );

  -- This is the exact forbidden substitution: the canonical performer is
  -- simulated mama, but the legacy actual performer is the operator papa UUID.
  begin
    update public.task_instances
    set actual_completed_by_id = v_owner
    where id = v_test_task;
    raise exception 'FAIL canonical-r0-remediation: test Task accepted operator legacy actual performer';
  exception
    when check_violation then null;
  end;

  if (select actual_completed_by_id from public.task_instances where id = v_test_task) is not null then
    raise exception 'FAIL canonical-r0-remediation: forbidden legacy actual performer persisted';
  end if;
end;
$$;

reset role;
select 'canonical_r0_request_and_test_actual_guards: PASS' as result;
