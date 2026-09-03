-- DD3A source-review completion: the task trigger already preserves OLD/NEW
-- scope, but the projection helper itself must also reject a still-existing
-- test Task.  Keep DELETE working: after a production DELETE the row is gone,
-- so the helper delegates to the legacy implementation only in that case.

create or replace function private.enqueue_family_ops_calendar_projection(
  p_household_id uuid,
  p_task_definition_id uuid,
  p_local_date date,
  p_task_instance_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
begin
  if p_task_instance_id is not null and exists (
    select 1
    from public.task_instances t
    where t.household_id = p_household_id
      and t.id = p_task_instance_id
      and t.test_context_id is not null
  ) then
    return;
  end if;

  perform private.enqueue_family_ops_calendar_projection_legacy_v1(
    p_household_id, p_task_definition_id, p_local_date, p_task_instance_id
  );
end;
$$;

revoke all on function private.enqueue_family_ops_calendar_projection(uuid, uuid, date, uuid)
  from public, anon, authenticated;
grant execute on function private.enqueue_family_ops_calendar_projection(uuid, uuid, date, uuid)
  to service_role;
