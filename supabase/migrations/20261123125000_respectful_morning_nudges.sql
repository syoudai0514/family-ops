-- #235: an unanswered LINE is not a record, and an unclaimed shared chore
-- must not be assigned to both adults. This helper is shared by enqueue and
-- revalidation; it performs no writes and works at a supplied clock instant.
create function private.fn_morning_nudge_lines_v2(p_household uuid,p_recipient uuid,p_day date,p_at timestamptz)
returns text language plpgsql stable security definer set search_path='' as $$
declare items jsonb; noon_at timestamptz; dropoff_assignee uuid;
begin
  if p_household is null or p_recipient is null or p_day is null or p_at is null then return null; end if;
  if not exists(select 1 from public.task_events e where e.household_id=p_household and e.actor_id=p_recipient
    and e.test_context_id is null and e.source in ('pwa','line','routine_editor')
    and e.event_type in ('completed','skipped','subtask_completed','subtask_completion_reverted','work_progress_recorded','completion_reverted')
    and e.created_at>=p_at-interval '7 days' and e.created_at<=p_at) then return null; end if;
  -- Only a single, genuinely agreed and person-assigned dropoff is definite.
  select case when count(*)=1 and bool_and(t.assignment_mode='person' and t.planned_assignee_id is not null
      and private.fn_task_assignment_consent_v1(p_household,t.planned_assignee_id,t.id))
    then (array_agg(t.planned_assignee_id))[1] end
    into dropoff_assignee from public.task_instances t
    join public.task_definitions d on d.household_id=t.household_id and d.id=t.task_definition_id
    where t.household_id=p_household and t.scheduled_date=p_day and t.test_context_id is null
      and d.code='dropoff' and t.status in ('todo','in_progress','completed');
  noon_at:=(p_day::timestamp+time '12:00') at time zone 'Asia/Tokyo';
  select coalesce(jsonb_agg(jsonb_build_object('task_id',t.id,'title',t.title) order by t.due_at nulls last,t.title,t.id),'[]'::jsonb)
    into items from public.task_instances t
    left join public.task_definitions d on d.household_id=t.household_id and d.id=t.task_definition_id
    left join public.domain_actor_refs ar on ar.household_id=t.household_id and ar.id=t.active_claimant_actor_ref_id
      and ar.actor_kind='real_user' and ar.test_context_id is null
    where t.household_id=p_household and t.scheduled_date=p_day and t.test_context_id is null
      and t.status in ('todo','in_progress') and coalesce(t.expectation,'normal')<>'optional'
      and (t.routine_phase='morning' or t.due_at<noon_at) and coalesce(d.code,'') not like 'codmon%'
      and ((t.assignment_mode='anyone' and (ar.real_user_id=p_recipient
            or (ar.real_user_id is null and dropoff_assignee is not null and dropoff_assignee<>p_recipient)))
        or (t.assignment_mode<>'anyone' and t.planned_assignee_id=p_recipient
            and private.fn_task_assignment_consent_v1(p_household,p_recipient,t.id)));
  if jsonb_array_length(items)=0 then return null; end if;
  return private.fn_line_task_timeline_v1(private.fn_task_display_items_v1(p_household,items),p_recipient::text);
end $$;
revoke all on function private.fn_morning_nudge_lines_v2(uuid,uuid,date,timestamptz) from public,anon,authenticated,service_role;
