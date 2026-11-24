-- The LINE Today formatter may show shared transport, but only when its
-- actual assignee has agreed. Ordinary partner tasks remain unlisted.
-- Keep the service-only reader's scope and all existing display fields.
create or replace function public.server_read_line_tasks_display(p_actor_id uuid,p_local_date date)
returns jsonb language plpgsql stable security invoker set search_path = '' as $$
declare h uuid; items jsonb;
begin
  if p_actor_id is null or p_local_date is null then raise exception 'INVALID_INPUT'; end if;
  select household_id into h from public.household_members where user_id=p_actor_id;
  if h is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('task_id',t.id,'title',t.title,
    'status',t.status,'outcome_reason',t.outcome_reason,'routine_phase',t.routine_phase,
    'expectation',t.expectation,'task_kind',t.task_kind,
    'assignment_confirmed',coalesce(private.fn_task_assignment_consent_v1(h,t.planned_assignee_id,t.id),false))
    order by t.due_at nulls last,t.title,t.id),'[]'::jsonb)
  into items from public.task_instances t where t.household_id=h and t.scheduled_date=p_local_date
    and t.test_context_id is null and t.status in ('todo','in_progress','completed','skipped');
  return private.fn_task_display_items_v1(h,items);
end $$;
revoke all on function public.server_read_line_tasks_display(uuid,date) from public,anon,authenticated;
grant execute on function public.server_read_line_tasks_display(uuid,date) to service_role;
