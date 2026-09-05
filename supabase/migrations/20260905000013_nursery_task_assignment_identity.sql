-- Q104/Q105 closeout: Nursery-confirmed Todo rows are ordinary canonical
-- manual Tasks.  The legacy create-task wrapper still fills the compatibility
-- user id but predates the ActorRef assignment columns, so normalize only the
-- Nursery-created manual Task at the row boundary.  This does not auto-assign:
-- a missing user remains explicitly unassigned.

create or replace function private.fn_normalize_nursery_task_assignment_identity_v1()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  v_actor_ref uuid;
begin
  if new.origin <> 'manual' or new.category <> 'nursery' or new.test_context_id is not null then
    return new;
  end if;

  new.assignment_source := 'manual';
  if new.planned_assignee_id is null then
    new.assignment_mode := 'unassigned';
    new.planned_assignee_actor_ref_id := null;
    return new;
  end if;

  select a.id into v_actor_ref
  from public.domain_actor_refs a
  where a.household_id = new.household_id
    and a.actor_kind = 'real_user'
    and a.real_user_id = new.planned_assignee_id;
  if v_actor_ref is null then
    raise exception 'NURSERY_TASK_ASSIGNEE_ACTOR_REF_NOT_FOUND';
  end if;
  new.assignment_mode := 'person';
  new.planned_assignee_actor_ref_id := v_actor_ref;
  return new;
end;
$$;
revoke all on function private.fn_normalize_nursery_task_assignment_identity_v1()
  from public,anon,authenticated;
grant execute on function private.fn_normalize_nursery_task_assignment_identity_v1()
  to service_role;

create trigger task_instances_nursery_assignment_identity_guard
before insert or update of planned_assignee_id,category,origin,test_context_id
on public.task_instances
for each row execute function private.fn_normalize_nursery_task_assignment_identity_v1();

-- Forward-safe normalization for any rows created between the orchestration
-- migration and this repair on a non-fresh environment.  No provider state is
-- touched and no assignment is inferred.
update public.task_instances t
set assignment_source='manual',
    assignment_mode=case when t.planned_assignee_id is null then 'unassigned' else 'person' end,
    planned_assignee_actor_ref_id=case
      when t.planned_assignee_id is null then null
      else (
        select a.id from public.domain_actor_refs a
        where a.household_id=t.household_id and a.actor_kind='real_user'
          and a.real_user_id=t.planned_assignee_id
        limit 1
      )
    end
where t.origin='manual' and t.category='nursery' and t.test_context_id is null;

-- Fail migration rather than leave a compatibility user without canonical
-- ActorRef identity.
do $$
begin
  if exists (
    select 1 from public.task_instances t
    where t.origin='manual' and t.category='nursery' and t.test_context_id is null
      and t.planned_assignee_id is not null
      and t.planned_assignee_actor_ref_id is null
  ) then
    raise exception 'NURSERY_TASK_ASSIGNMENT_IDENTITY_BACKFILL_FAILED';
  end if;
end $$;
