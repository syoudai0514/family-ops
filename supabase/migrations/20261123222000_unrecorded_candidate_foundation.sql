-- #198: identify candidates without changing any task or triggering external
-- projections. Actual closure is deliberately not enabled by this foundation.
-- Open check-in sessions and every kind of request-linked task remain intact.
create function private.fn_unrecorded_routine_candidates_v1(p_before date)
returns table(household_id uuid,task_id uuid) language sql stable security definer set search_path='' as $$
  select t.household_id,t.id
  from public.task_instances t
  where p_before is not null and t.test_context_id is null and t.origin='recurring'
    -- A started task or any evidence of partial work is already a record.
    -- Leave it for explicit follow-up instead of calling it wholly unrecorded.
    and t.status='todo' and t.scheduled_date<least(p_before,(now() at time zone 'Asia/Tokyo')::date)
    and t.calendar_visibility<>'special' and t.task_kind<>'special' and t.event_id is null
    and t.attention_state='active' and coalesce(t.carryover_policy,'occurrence_ends') not in ('until_done','until_deadline')
    and coalesce(t.duplicate_sensitivity,'normal')<>'safety_critical'
    and coalesce(t.category,'') not in ('shopping','purchase')
    and not exists(select 1 from public.requests r where r.household_id=t.household_id
      and (r.linked_task_instance_id=t.id or r.assignment_task_instance_id=t.id))
    and not exists(select 1 from public.assignment_change_request_tasks x
      where x.household_id=t.household_id and x.task_instance_id=t.id)
    and not exists(select 1 from public.routine_checkin_session_items i
      join public.routine_checkin_sessions s on s.household_id=i.household_id and s.id=i.session_id
      where i.household_id=t.household_id and i.task_instance_id=t.id and s.status='open')
    and not exists(select 1 from public.task_subtask_instances s
      where s.household_id=t.household_id and s.task_instance_id=t.id and s.is_completed)
    and not exists(select 1 from public.task_actual_participants p
      where p.household_id=t.household_id and p.task_instance_id=t.id and p.removed_at is null)
    and not exists(select 1 from public.task_events e where e.household_id=t.household_id and e.task_instance_id=t.id
      and e.test_context_id is null and e.event_type in ('completed','skipped','subtask_completed','work_progress_recorded'))
    and not exists(select 1 from public.handovers h where h.household_id=t.household_id and h.related_task_id=t.id
      and h.status='active' and (h.valid_until is null or h.valid_until>now()))
  order by t.household_id,t.id;
$$;
revoke all on function private.fn_unrecorded_routine_candidates_v1(date) from public,anon,authenticated,service_role;
