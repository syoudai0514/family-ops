-- WP-DD3A hard boundary + backward-compatible legacy insert defaults.
--
-- A simulated row must never reach the existing Family Ops -> Google projection
-- queue, even if an older reconciliation RPC calls the enqueue function
-- directly. Keep the legacy implementation for production semantics, but make
-- it unreachable to application roles except through this scope-aware wrapper.

-- Legacy handover writers do not know valid_from. Canonical semantics want a
-- non-null start, so use creation time as the compatibility default rather than
-- forcing every pre-cutover writer to change in this R0/R1 batch.
alter table public.handovers
  alter column valid_from set default now();

-- Freeze the existing production implementation behind a private legacy name.
alter function private.enqueue_family_ops_calendar_projection(uuid, uuid, date, uuid)
  rename to enqueue_family_ops_calendar_projection_legacy_v1;

revoke all on function private.enqueue_family_ops_calendar_projection_legacy_v1(uuid, uuid, date, uuid)
  from public, anon, authenticated, service_role;

create or replace function private.enqueue_family_ops_calendar_projection(
  p_household_id uuid,
  p_task_definition_id uuid,
  p_local_date date,
  p_task_instance_id uuid
) returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  -- All current trigger/reconciliation callers pass a concrete task instance.
  -- Fail closed for a synthetic row before consulting any production calendar
  -- connection or touching private.family_ops_calendar_mirrors.
  if p_task_instance_id is not null and exists (
    select 1
    from public.task_instances ti
    where ti.household_id = p_household_id
      and ti.id = p_task_instance_id
      and ti.test_context_id is not null
  ) then
    return;
  end if;

  perform private.enqueue_family_ops_calendar_projection_legacy_v1(
    p_household_id,
    p_task_definition_id,
    p_local_date,
    p_task_instance_id
  );
end;
$$;

revoke all on function private.enqueue_family_ops_calendar_projection(uuid, uuid, date, uuid)
  from public, anon, authenticated;
grant execute on function private.enqueue_family_ops_calendar_projection(uuid, uuid, date, uuid)
  to service_role;

-- Test scope is immutable for a Task aggregate. A synthetic Task is created as
-- a synthetic Task and can never be converted into a production Task (or vice
-- versa) by clearing/adding the discriminator after the fact.
create or replace function private.fn_guard_task_test_context_immutable_v1()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if old.test_context_id is distinct from new.test_context_id then
    raise exception 'TASK_TEST_CONTEXT_IMMUTABLE';
  end if;
  return new;
end;
$$;

revoke all on function private.fn_guard_task_test_context_immutable_v1()
  from public, anon, authenticated;
grant execute on function private.fn_guard_task_test_context_immutable_v1()
  to service_role;

create trigger task_instances_test_context_immutable_v1
  before update of test_context_id on public.task_instances
  for each row execute function private.fn_guard_task_test_context_immutable_v1();
