-- Independent source-review remediation for PR #44.
-- Forward-only: preserve the accepted canonical foundation while closing
-- test-scope read isolation, Task/Request lifecycle compatibility, canonical
-- assignment reconciliation, and performer/system ActorRef scope gaps.

-- ---------------------------------------------------------------------------
-- HIGH-1: production authenticated readers must never see test subtasks.
-- ---------------------------------------------------------------------------

drop policy if exists task_subtask_instances_select
  on public.task_subtask_instances;
create policy task_subtask_instances_select
  on public.task_subtask_instances
  for select to authenticated
  using (
    test_context_id is null
    and public.is_household_member(household_id)
  );

-- ---------------------------------------------------------------------------
-- MEDIUM-2: system ActorRefs are production-only identities.  Simulation uses
-- immutable simulated_member ActorRefs; attaching a system ActorRef to a test
-- context would create an avoidable scope escape hatch.
-- ---------------------------------------------------------------------------

alter table public.domain_actor_refs
  add constraint domain_actor_refs_system_production_only_v2_chk
  check (actor_kind <> 'system' or test_context_id is null);

-- Defense in depth at execution/row validation boundaries.  The table CHECK
-- prevents new invalid identities; these guards also fail closed if a malformed
-- row is ever introduced by privileged maintenance.
create or replace function private.fn_assert_actor_ref_scope(
  p_household_id uuid, p_actor_ref_id uuid, p_test_context_id uuid
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_kind text;
  v_actor_test_context_id uuid;
begin
  if p_actor_ref_id is null then return; end if;

  select actor_kind, test_context_id into v_kind, v_actor_test_context_id
  from public.domain_actor_refs
  where household_id = p_household_id and id = p_actor_ref_id;
  if not found then raise exception 'ACTOR_REF_NOT_IN_HOUSEHOLD'; end if;

  if v_kind = 'system'
     and (v_actor_test_context_id is not null or p_test_context_id is not null) then
    raise exception 'SYSTEM_ACTOR_TEST_SCOPE_FORBIDDEN';
  end if;
  if p_test_context_id is null and v_kind = 'simulated_member' then
    raise exception 'SIMULATED_ACTOR_IN_PRODUCTION_ROW';
  end if;
  if p_test_context_id is not null and v_kind = 'simulated_member'
     and v_actor_test_context_id is distinct from p_test_context_id then
    raise exception 'SIMULATED_ACTOR_TEST_CONTEXT_MISMATCH';
  end if;
end;
$$;
revoke all on function private.fn_assert_actor_ref_scope(uuid, uuid, uuid)
  from public, anon, authenticated;
grant execute on function private.fn_assert_actor_ref_scope(uuid, uuid, uuid)
  to service_role;

create or replace function private.fn_validate_execution_context_v1(
  p_household_id uuid,
  p_operator_user_id uuid,
  p_actor_ref_id uuid,
  p_test_context_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_actor_kind text;
  v_actor_test_context_id uuid;
  v_context_operator uuid;
  v_context_status text;
begin
  if not exists (
    select 1 from public.household_members m
    where m.household_id = p_household_id and m.user_id = p_operator_user_id
  ) then
    raise exception 'EXECUTION_OPERATOR_NOT_IN_HOUSEHOLD';
  end if;

  select a.actor_kind, a.test_context_id
    into v_actor_kind, v_actor_test_context_id
  from public.domain_actor_refs a
  where a.household_id = p_household_id and a.id = p_actor_ref_id;
  if not found then
    raise exception 'EXECUTION_ACTOR_REF_NOT_IN_HOUSEHOLD';
  end if;

  if v_actor_kind = 'system'
     and (v_actor_test_context_id is not null or p_test_context_id is not null) then
    raise exception 'SYSTEM_ACTOR_TEST_SCOPE_FORBIDDEN';
  end if;

  if p_test_context_id is null then
    if v_actor_kind = 'simulated_member' then
      raise exception 'SIMULATED_ACTOR_IN_PRODUCTION_EXECUTION';
    end if;
    return jsonb_build_object(
      'mode', 'production',
      'household_id', p_household_id,
      'operator_user_id', p_operator_user_id,
      'actor_ref_id', p_actor_ref_id
    );
  end if;

  select c.operator_user_id, c.status
    into v_context_operator, v_context_status
  from public.test_simulation_contexts c
  where c.household_id = p_household_id and c.id = p_test_context_id;
  if not found then
    raise exception 'TEST_CONTEXT_NOT_FOUND';
  end if;
  if v_context_status <> 'active' then
    raise exception 'TEST_CONTEXT_NOT_ACTIVE';
  end if;
  if v_context_operator is distinct from p_operator_user_id then
    raise exception 'TEST_CONTEXT_OPERATOR_MISMATCH';
  end if;
  if v_actor_kind = 'simulated_member'
     and v_actor_test_context_id is distinct from p_test_context_id then
    raise exception 'SIMULATED_ACTOR_TEST_CONTEXT_MISMATCH';
  end if;

  return jsonb_build_object(
    'mode', 'test_simulation',
    'household_id', p_household_id,
    'operator_user_id', p_operator_user_id,
    'actor_ref_id', p_actor_ref_id,
    'test_context_id', p_test_context_id
  );
end;
$$;
revoke all on function private.fn_validate_execution_context_v1(uuid, uuid, uuid, uuid)
  from public, anon, authenticated;
grant execute on function private.fn_validate_execution_context_v1(uuid, uuid, uuid, uuid)
  to service_role;

-- ---------------------------------------------------------------------------
-- MEDIUM-3: actual participants are people, never system actors.  Put the
-- invariant at the durable table boundary so completion, correction, backfill,
-- and future adapters all share the same rule.
-- ---------------------------------------------------------------------------

create or replace function private.fn_guard_task_actual_performer_kind_v1()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_kind text;
begin
  select a.actor_kind into v_kind
  from public.domain_actor_refs a
  where a.household_id = new.household_id and a.id = new.actor_ref_id;
  if not found then
    raise exception 'ACTOR_REF_NOT_IN_HOUSEHOLD';
  end if;
  if v_kind not in ('real_user', 'simulated_member') then
    raise exception 'TASK_PERFORMER_ACTOR_KIND_INVALID';
  end if;
  return new;
end;
$$;
revoke all on function private.fn_guard_task_actual_performer_kind_v1()
  from public, anon, authenticated;
grant execute on function private.fn_guard_task_actual_performer_kind_v1()
  to service_role;

drop trigger if exists task_actual_participants_performer_kind_v1
  on public.task_actual_participants;
create trigger task_actual_participants_performer_kind_v1
  before insert or update of actor_ref_id
  on public.task_actual_participants
  for each row execute function private.fn_guard_task_actual_performer_kind_v1();

-- ---------------------------------------------------------------------------
-- MEDIUM-1: Task execution is the execution truth for an accepted linked
-- Request.  Preserve the CURRENT compatibility lifecycle when canonical Task
-- completion becomes authoritative.  This is deliberately one-way: declined,
-- cancelled, or unrelated Requests are never resurrected.
-- ---------------------------------------------------------------------------

create or replace function private.fn_sync_request_completion_from_task_v1()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.status = 'completed' and old.status is distinct from 'completed' then
    update public.requests r
    set status = 'completed',
        completed_at = coalesce(new.completed_at, now()),
        revision = r.revision + 1
    where r.household_id = new.household_id
      and r.linked_task_instance_id = new.id
      and r.test_context_id is not distinct from new.test_context_id
      and r.status = 'accepted';
  end if;
  return new;
end;
$$;
revoke all on function private.fn_sync_request_completion_from_task_v1()
  from public, anon, authenticated;
grant execute on function private.fn_sync_request_completion_from_task_v1()
  to service_role;

drop trigger if exists task_instances_sync_request_completion_v1
  on public.task_instances;
create trigger task_instances_sync_request_completion_v1
  after update of status, completed_at
  on public.task_instances
  for each row execute function private.fn_sync_request_completion_from_task_v1();

-- ---------------------------------------------------------------------------
-- HIGH-2: R0 reconciliation must distinguish canonical assignment authority
-- from legacy-snapshot compatibility.  Canonical manual/agreement assignments
-- are valid when ActorRef and compatibility user point to the same real actor;
-- legacy rows continue to require legacy_snapshot exactly as before.
-- ---------------------------------------------------------------------------

alter function private.canonical_foundation_reconciliation_v1()
  rename to canonical_recon_v1_pre_task_assign_fix;

create or replace function private.canonical_foundation_reconciliation_v1()
returns table(issue_type text, issue_count bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select r.issue_type, r.issue_count
  from private.canonical_recon_v1_pre_task_assign_fix() r
  where r.issue_type <> 'task_planned_actor_mismatch'

  union all

  select 'task_planned_actor_mismatch'::text, count(*)
  from public.task_instances t
  left join public.domain_actor_refs a
    on a.id = t.planned_assignee_actor_ref_id
   and a.household_id = t.household_id
  where t.test_context_id is null
    and case
      when t.assignment_source in ('manual', 'agreement') then
        case
          when t.assignment_mode = 'person' then
            t.planned_assignee_actor_ref_id is null
            or a.id is null
            or a.actor_kind <> 'real_user'
            or a.real_user_id is distinct from t.planned_assignee_id
          when t.assignment_mode in ('unassigned', 'anyone') then
            t.planned_assignee_actor_ref_id is not null
            or t.planned_assignee_id is not null
          else true
        end
      else
        (
          (t.planned_assignee_id is null
           and (t.assignment_mode is distinct from 'unassigned'
                or t.planned_assignee_actor_ref_id is not null
                or t.assignment_source is distinct from 'legacy_snapshot'))
          or
          (t.planned_assignee_id is not null
           and (t.assignment_mode is distinct from 'person'
                or a.id is null
                or a.real_user_id is distinct from t.planned_assignee_id
                or t.assignment_source is distinct from 'legacy_snapshot'))
        )
    end;
$$;
revoke all on function private.canonical_foundation_reconciliation_v1()
  from public, anon, authenticated;
grant execute on function private.canonical_foundation_reconciliation_v1()
  to service_role;
