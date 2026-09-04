-- Independent PR #44 source-review remediation regression coverage.
\set ON_ERROR_STOP on

set role service_role;
do $$
declare
  v_owner constant uuid := '44000000-0000-0000-0000-000000000001';
  v_partner constant uuid := '44000000-0000-0000-0000-000000000002';
  v_hh jsonb;
  v_hh_id uuid;
  v_owner_ref uuid;
  v_partner_ref uuid;
  v_test_context uuid;
  v_test_task uuid := gen_random_uuid();
  v_system_ref uuid;
  v_correct_task uuid := gen_random_uuid();
  v_request_task uuid := gen_random_uuid();
  v_request uuid := gen_random_uuid();
  v_assignment_task uuid := gen_random_uuid();
  v_result jsonb;
  v_before bigint;
  v_after bigint;
begin
  insert into auth.users(id) values (v_owner), (v_partner);

  v_hh := public.server_tx_create_household(
    v_owner, gen_random_uuid(), 'Foundation source-review remediation', 'Owner'
  );
  v_hh_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members(household_id, user_id, member_role)
  values (v_hh_id, v_partner, 'adult');

  select id into v_owner_ref
  from public.domain_actor_refs
  where household_id = v_hh_id and actor_kind = 'real_user' and real_user_id = v_owner;
  select id into v_partner_ref
  from public.domain_actor_refs
  where household_id = v_hh_id and actor_kind = 'real_user' and real_user_id = v_partner;
  if v_owner_ref is null or v_partner_ref is null then
    raise exception 'FAIL foundation remediation: member ActorRefs missing';
  end if;

  insert into public.test_simulation_contexts(household_id, operator_user_id, label)
  values (v_hh_id, v_owner, 'foundation-rls-regression')
  returning id into v_test_context;

  insert into public.task_instances(
    id, household_id, origin, title, category, routine_phase, scheduled_date,
    completion_mode, status, source, created_by, assignment_mode, test_context_id
  ) values (
    v_test_task, v_hh_id, 'manual', 'FOUNDATION TEST SUBTASK PARENT', 'other',
    'anytime', current_date, 'subtasks', 'todo', 'test', v_owner,
    'unassigned', v_test_context
  );
  insert into public.task_subtask_instances(
    household_id, task_instance_id, title, required, sort_order, test_context_id
  ) values (
    v_hh_id, v_test_task, 'FOUNDATION-RLS-SECRET-44', true, 1, v_test_context
  );

  -- A system ActorRef may exist only in production scope.  The malformed form
  -- reported by the review is structurally impossible now.
  begin
    insert into public.domain_actor_refs(
      household_id, actor_kind, test_context_id
    ) values (v_hh_id, 'system', v_test_context);
    raise exception 'FAIL foundation remediation: test-scoped system ActorRef persisted';
  exception
    when check_violation then null;
  end;

  insert into public.domain_actor_refs(household_id, actor_kind)
  values (v_hh_id, 'system') returning id into v_system_ref;

  -- The correction path must enforce the same human/simulated performer kinds
  -- as initial completion, including subtasks-mode where there is no legacy
  -- compatibility performer requirement to hide the defect.
  insert into public.task_instances(
    id, household_id, origin, title, category, routine_phase, scheduled_date,
    completion_mode, status, actual_completed_by_id, completed_at, source,
    created_by, assignment_mode, assignment_source
  ) values (
    v_correct_task, v_hh_id, 'manual', 'Correct actual performer guard', 'other',
    'anytime', current_date, 'subtasks', 'completed', null, now(), 'test',
    v_owner, 'unassigned', 'manual'
  );
  begin
    perform private.fn_command_correct_task_actual_v1(
      v_hh_id, v_owner, v_owner_ref, null, v_correct_task,
      array[v_system_ref], 1, gen_random_uuid(), 'pwa'
    );
    raise exception 'FAIL foundation remediation: system performer accepted by correction';
  exception
    when others then
      if sqlerrm <> 'TASK_PERFORMER_ACTOR_KIND_INVALID' then raise; end if;
  end;
  if (select revision from public.task_instances where id = v_correct_task) <> 1
     or exists (
       select 1 from public.task_actual_participants
       where task_instance_id = v_correct_task and actor_ref_id = v_system_ref
     ) then
    raise exception 'FAIL foundation remediation: failed correction left durable mutation';
  end if;

  -- Canonical Task completion must project the CURRENT accepted Request tuple
  -- to completed without inventing a second lifecycle source.
  insert into public.task_instances(
    id, household_id, origin, title, category, routine_phase, scheduled_date,
    planned_assignee_id, completion_mode, status, source, created_by,
    assignment_mode, assignment_source, planned_assignee_actor_ref_id
  ) values (
    v_request_task, v_hh_id, 'request', 'Canonical linked request task', 'other',
    'anytime', current_date, v_partner, 'whole', 'todo', 'canonical_request',
    v_owner, 'person', 'agreement', v_partner_ref
  );
  insert into public.requests(
    id, household_id, requester_id, recipient_id, shared_title, status,
    linked_task_instance_id, accepted_at, requester_actor_ref_id,
    recipient_actor_ref_id, request_kind
  ) values (
    v_request, v_hh_id, v_owner, v_partner, 'Canonical completion mirror',
    'accepted', v_request_task, now(), v_owner_ref, v_partner_ref, 'light'
  );
  insert into public.request_attempts(
    household_id, request_id, attempt_kind, state, terms,
    created_by_actor_ref_id, accepted_at, legacy_backfill
  ) values (
    v_hh_id, v_request, 'initial', 'accepted', '{}'::jsonb,
    v_owner_ref, now(), false
  );

  v_result := private.fn_command_complete_task_v1(
    v_hh_id, v_owner, v_owner_ref, null, v_request_task,
    array[v_partner_ref], 1, gen_random_uuid(), 'pwa'
  );
  if v_result->>'status' <> 'completed'
     or not exists (
       select 1 from public.requests
       where id = v_request and status = 'completed' and completed_at is not null
     )
     or not exists (
       select 1 from public.task_actual_participants
       where task_instance_id = v_request_task
         and actor_ref_id = v_partner_ref and removed_at is null
     ) then
    raise exception 'FAIL foundation remediation: Task completion did not preserve Request/actual truth';
  end if;

  -- Canonical assignment_source values are authoritative, not legacy drift.
  -- Reconciliation must keep detecting malformed legacy snapshots while not
  -- reporting valid manual/agreement commands as permanent blockers.
  insert into public.task_instances(
    id, household_id, origin, title, category, routine_phase, scheduled_date,
    completion_mode, status, source, created_by, assignment_mode,
    assignment_source
  ) values (
    v_assignment_task, v_hh_id, 'manual', 'Canonical assignment reconciliation',
    'other', 'anytime', current_date, 'whole', 'todo', 'test', v_owner,
    'unassigned', 'legacy_snapshot'
  );

  select issue_count into v_before
  from private.canonical_foundation_reconciliation_v1()
  where issue_type = 'task_planned_actor_mismatch';

  perform private.fn_command_change_task_assignment_v1(
    v_hh_id, v_owner, v_owner_ref, null, v_assignment_task,
    'person', v_owner_ref, false, 1, gen_random_uuid(), 'pwa'
  );
  perform private.fn_command_change_task_assignment_v1(
    v_hh_id, v_owner, v_owner_ref, null, v_assignment_task,
    'person', v_owner_ref, true, 2, gen_random_uuid(), 'pwa'
  );

  select issue_count into v_after
  from private.canonical_foundation_reconciliation_v1()
  where issue_type = 'task_planned_actor_mismatch';
  if coalesce(v_after, 0) <> coalesce(v_before, 0) then
    raise exception 'FAIL foundation remediation: canonical assignment created reconciliation drift before=% after=%',
      v_before, v_after;
  end if;
  if not exists (
    select 1 from public.task_instances
    where id = v_assignment_task
      and assignment_source = 'agreement'
      and assignment_mode = 'person'
      and planned_assignee_actor_ref_id = v_owner_ref
      and planned_assignee_id = v_owner
  ) then
    raise exception 'FAIL foundation remediation: canonical agreement assignment tuple invalid';
  end if;

  perform private.backfill_canonical_foundation_v1();
  if (select assignment_source from public.task_instances where id = v_assignment_task) <> 'agreement' then
    raise exception 'FAIL foundation remediation: R0 backfill overwrote canonical assignment authority';
  end if;
end;
$$;
reset role;

-- HIGH-1 must be demonstrated through the actual authenticated RLS boundary,
-- not merely by checking a production read-model filter.
set role authenticated;
set request.jwt.claim.sub = '44000000-0000-0000-0000-000000000001';
set request.jwt.claim.role = 'authenticated';
do $$
declare v_count int;
begin
  select count(*) into v_count
  from public.task_subtask_instances
  where title = 'FOUNDATION-RLS-SECRET-44';
  if v_count <> 0 then
    raise exception 'FAIL foundation remediation: test subtask leaked through production RLS';
  end if;
end;
$$;
reset role;
reset request.jwt.claim.sub;
reset request.jwt.claim.role;

select '44_foundation_source_review_remediation: PASS' as result;
