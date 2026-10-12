-- Removed participants describe an earlier completion, not the task's current
-- legacy performer. Preserve that history during typed recovery while keeping
-- real-user and current-primary compatibility checks enforced.
create or replace function private.fn_enforce_participant_compatibility_primary_identity()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_kind text;
  v_real_user_id uuid;
  v_legacy_actual_user_id uuid;
begin
  if not new.compatibility_primary then
    return new;
  end if;

  select actor_kind, real_user_id
    into v_kind, v_real_user_id
  from public.domain_actor_refs
  where household_id = new.household_id and id = new.actor_ref_id;

  if not found then
    raise exception 'ACTOR_REF_NOT_IN_HOUSEHOLD';
  end if;

  if v_kind <> 'real_user' then
    raise exception 'SIMULATED_ACTOR_LEGACY_USER_SUBSTITUTION';
  end if;

  if new.removed_at is not null then
    return new;
  end if;

  select actual_completed_by_id
    into v_legacy_actual_user_id
  from public.task_instances
  where household_id = new.household_id and id = new.task_instance_id;

  if not found then
    raise exception 'CANONICAL_PARENT_NOT_FOUND';
  end if;

  if v_legacy_actual_user_id is null
     or v_legacy_actual_user_id is distinct from v_real_user_id then
    raise exception 'COMPATIBILITY_PRIMARY_LEGACY_USER_MISMATCH';
  end if;

  return new;
end;
$$;

revoke all on function private.fn_enforce_participant_compatibility_primary_identity()
  from public, anon, authenticated;
grant execute on function private.fn_enforce_participant_compatibility_primary_identity()
  to service_role;

-- Reactivating a removed primary must pass the same checks as a new primary.
drop trigger task_actual_participants_compat_primary_identity_guard
  on public.task_actual_participants;
create trigger task_actual_participants_compat_primary_identity_guard
  before insert or update of actor_ref_id, task_instance_id, compatibility_primary,
    test_context_id, removed_at
  on public.task_actual_participants
  for each row execute function private.fn_enforce_participant_compatibility_primary_identity();
