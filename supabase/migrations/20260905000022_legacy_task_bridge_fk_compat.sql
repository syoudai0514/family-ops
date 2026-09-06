-- Issue #48 closeout: the R0 legacy/canonical bridge must enrich valid
-- household-local legacy writes without pre-empting the established composite
-- household FKs. Cross-household negative paths must still fail as FK
-- violations, not as bridge-specific errors.

create or replace function private.fn_bridge_legacy_task_assignment_v1()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_actor_ref uuid;
begin
  if new.test_context_id is not null then return new; end if;
  if new.assignment_source is not null and new.assignment_source <> 'legacy_snapshot' then
    return new;
  end if;

  if new.planned_assignee_id is null then
    new.planned_assignee_actor_ref_id := null;
    new.assignment_mode := 'unassigned';
    new.assignment_source := 'legacy_snapshot';
    return new;
  end if;

  -- Only enrich a legacy assignee that is actually a member of this same
  -- household. If it is not, leave the row untouched so the pre-existing
  -- household-scoped FK remains the authoritative rejection boundary.
  if not exists (
    select 1 from public.household_members m
    where m.household_id = new.household_id
      and m.user_id = new.planned_assignee_id
  ) then
    return new;
  end if;

  select a.id into v_actor_ref
  from public.domain_actor_refs a
  where a.household_id = new.household_id
    and a.actor_kind = 'real_user'
    and a.real_user_id = new.planned_assignee_id;

  -- household_members_ensure_real_actor_ref_v1 keeps this invariant for valid
  -- members. Fail closed if privileged maintenance ever violates it.
  if v_actor_ref is null then
    raise exception 'LEGACY_TASK_ASSIGNEE_ACTOR_REF_NOT_FOUND';
  end if;

  new.planned_assignee_actor_ref_id := v_actor_ref;
  new.assignment_mode := 'person';
  new.assignment_source := 'legacy_snapshot';
  return new;
end;
$$;

create or replace function private.fn_bridge_legacy_task_event_actor_v1()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.test_context_id is null and new.actor_id is not null and new.actor_ref_id is null then
    -- As with task assignment, do not replace the established household FK
    -- error for a cross-household legacy actor with a bridge-specific error.
    if not exists (
      select 1 from public.household_members m
      where m.household_id = new.household_id and m.user_id = new.actor_id
    ) then
      return new;
    end if;

    select a.id into new.actor_ref_id
    from public.domain_actor_refs a
    where a.household_id = new.household_id
      and a.actor_kind = 'real_user'
      and a.real_user_id = new.actor_id;
    if new.actor_ref_id is null then
      raise exception 'LEGACY_TASK_EVENT_ACTOR_REF_NOT_FOUND';
    end if;
  end if;
  return new;
end;
$$;

revoke all on function private.fn_bridge_legacy_task_assignment_v1() from public, anon, authenticated;
revoke all on function private.fn_bridge_legacy_task_event_actor_v1() from public, anon, authenticated;
grant execute on function private.fn_bridge_legacy_task_assignment_v1() to service_role;
grant execute on function private.fn_bridge_legacy_task_event_actor_v1() to service_role;
