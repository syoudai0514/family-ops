-- Canonical detailed-design implementation, Batch 1A source-review remediation.
-- Prevent a simulated ActorRef from being paired with a real-user legacy mirror
-- (including the operator user ID) while preserving R0 old-runtime compatibility.
--
-- Important R0 rule:
-- production old-runtime writes are still allowed to change legacy real-user
-- columns without simultaneously updating canonical snapshots. Those temporary
-- real-user drifts are repaired/detected by backfill/reconciliation. What is
-- never valid, even in R0, is using any real-user UUID to stand in for a
-- simulated domain actor.

create or replace function private.fn_assert_no_simulated_legacy_user_substitution(
  p_household_id uuid,
  p_actor_ref_id uuid,
  p_legacy_user_id uuid
) returns void
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_kind text;
  v_real_user_id uuid;
begin
  if p_actor_ref_id is null then
    return;
  end if;

  select actor_kind, real_user_id
    into v_kind, v_real_user_id
  from public.domain_actor_refs
  where household_id = p_household_id
    and id = p_actor_ref_id;

  if not found then
    raise exception 'ACTOR_REF_NOT_IN_HOUSEHOLD';
  end if;

  if v_kind in ('simulated_member', 'system') and p_legacy_user_id is not null then
    raise exception 'SIMULATED_ACTOR_LEGACY_USER_SUBSTITUTION';
  end if;

  -- For test-scoped rows, a real ActorRef may use a legacy mirror only for that
  -- same real household member. Production R0 real-user drift is intentionally
  -- handled by the rerunnable compatibility backfill instead of being rejected
  -- here, so this helper does not reject real-user mismatch by itself.
end;
$$;

revoke all on function private.fn_assert_no_simulated_legacy_user_substitution(uuid, uuid, uuid)
  from public, anon, authenticated;
grant execute on function private.fn_assert_no_simulated_legacy_user_substitution(uuid, uuid, uuid)
  to service_role;

create or replace function private.fn_enforce_task_legacy_actor_compatibility()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform private.fn_assert_no_simulated_legacy_user_substitution(
    new.household_id,
    new.planned_assignee_actor_ref_id,
    new.planned_assignee_id
  );
  return new;
end;
$$;
revoke all on function private.fn_enforce_task_legacy_actor_compatibility() from public, anon, authenticated;
grant execute on function private.fn_enforce_task_legacy_actor_compatibility() to service_role;

create trigger task_instances_legacy_actor_compat_guard
  before insert or update of planned_assignee_actor_ref_id, planned_assignee_id, test_context_id
  on public.task_instances
  for each row execute function private.fn_enforce_task_legacy_actor_compatibility();

create or replace function private.fn_enforce_task_event_legacy_actor_compatibility()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform private.fn_assert_no_simulated_legacy_user_substitution(
    new.household_id,
    new.actor_ref_id,
    new.actor_id
  );
  return new;
end;
$$;
revoke all on function private.fn_enforce_task_event_legacy_actor_compatibility() from public, anon, authenticated;
grant execute on function private.fn_enforce_task_event_legacy_actor_compatibility() to service_role;

create trigger task_events_legacy_actor_compat_guard
  before insert or update of actor_ref_id, actor_id, test_context_id
  on public.task_events
  for each row execute function private.fn_enforce_task_event_legacy_actor_compatibility();

create or replace function private.fn_enforce_request_legacy_actor_compatibility()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform private.fn_assert_no_simulated_legacy_user_substitution(
    new.household_id,
    new.requester_actor_ref_id,
    new.requester_id
  );
  perform private.fn_assert_no_simulated_legacy_user_substitution(
    new.household_id,
    new.recipient_actor_ref_id,
    new.recipient_id
  );
  return new;
end;
$$;
revoke all on function private.fn_enforce_request_legacy_actor_compatibility() from public, anon, authenticated;
grant execute on function private.fn_enforce_request_legacy_actor_compatibility() to service_role;

create trigger requests_legacy_actor_compat_guard
  before insert or update of requester_actor_ref_id, recipient_actor_ref_id, requester_id, recipient_id, test_context_id
  on public.requests
  for each row execute function private.fn_enforce_request_legacy_actor_compatibility();

create or replace function private.fn_enforce_handover_legacy_actor_compatibility()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform private.fn_assert_no_simulated_legacy_user_substitution(
    new.household_id,
    new.author_actor_ref_id,
    new.author_id
  );
  return new;
end;
$$;
revoke all on function private.fn_enforce_handover_legacy_actor_compatibility() from public, anon, authenticated;
grant execute on function private.fn_enforce_handover_legacy_actor_compatibility() to service_role;

create trigger handovers_legacy_actor_compat_guard
  before insert or update of author_actor_ref_id, author_id, test_context_id
  on public.handovers
  for each row execute function private.fn_enforce_handover_legacy_actor_compatibility();

create or replace function private.fn_enforce_shopping_legacy_actor_compatibility()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  perform private.fn_assert_no_simulated_legacy_user_substitution(
    new.household_id,
    new.assignee_actor_ref_id,
    new.assignee_id
  );
  return new;
end;
$$;
revoke all on function private.fn_enforce_shopping_legacy_actor_compatibility() from public, anon, authenticated;
grant execute on function private.fn_enforce_shopping_legacy_actor_compatibility() to service_role;

create trigger shopping_items_legacy_actor_compat_guard
  before insert or update of assignee_actor_ref_id, assignee_id, test_context_id
  on public.shopping_items
  for each row execute function private.fn_enforce_shopping_legacy_actor_compatibility();

-- compatibility_primary is a technical mirror of legacy
-- task_instances.actual_completed_by_id. A simulated participant can never be
-- that mirror. This keeps future test performers from acquiring a fake real-user
-- identity through the compatibility path.
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
revoke all on function private.fn_enforce_participant_compatibility_primary_identity() from public, anon, authenticated;
grant execute on function private.fn_enforce_participant_compatibility_primary_identity() to service_role;

create trigger task_actual_participants_compat_primary_identity_guard
  before insert or update of actor_ref_id, task_instance_id, compatibility_primary, test_context_id
  on public.task_actual_participants
  for each row execute function private.fn_enforce_participant_compatibility_primary_identity();
