-- #198: identify candidates without changing any task or triggering external
-- projections. Actual closure is deliberately not enabled by this foundation.
-- Open check-in sessions and every kind of request-linked task remain intact.
create function private.fn_unrecorded_routine_candidates_v1(p_before date)
returns table(household_id uuid,task_id uuid) language sql stable security definer set search_path='' as $$
  select t.household_id,t.id
  from public.task_instances t
  where p_before is not null and t.test_context_id is null and t.origin='recurring'
    and t.status in ('todo','in_progress') and t.scheduled_date<p_before
    and t.calendar_visibility<>'special' and coalesce(t.category,'') not in ('shopping','purchase')
    and not exists(select 1 from public.requests r where r.household_id=t.household_id
      and (r.linked_task_instance_id=t.id or r.assignment_task_instance_id=t.id))
    and not exists(select 1 from public.assignment_change_request_tasks x
      where x.household_id=t.household_id and x.task_instance_id=t.id)
    and not exists(select 1 from public.routine_checkin_session_items i
      join public.routine_checkin_sessions s on s.household_id=i.household_id and s.id=i.session_id
      where i.household_id=t.household_id and i.task_instance_id=t.id and s.status='open')
  order by t.household_id,t.id;
$$;
revoke all on function private.fn_unrecorded_routine_candidates_v1(date) from public,anon,authenticated,service_role;
