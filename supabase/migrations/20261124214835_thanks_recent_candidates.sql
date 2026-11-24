-- Today's card is a reminder for recent activity. The LINE sender still
-- requests one exact local day for the next morning's note.
create or replace function public.server_read_thanks_candidates(p_actor_id uuid,p_local_date date default null)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare
  ctx jsonb;
  hh uuid;
  result jsonb;
  today date := (now() at time zone 'Asia/Tokyo')::date;
  first_day date := coalesce(p_local_date, today - 1);
  last_day date := coalesce(p_local_date, today);
  period_start timestamptz := first_day::timestamp at time zone 'Asia/Tokyo';
  period_end timestamptz := (last_day + 1)::timestamp at time zone 'Asia/Tokyo';
begin
  ctx:=private.fn_require_production_actor_context_v1(p_actor_id);
  hh:=(ctx->>'household_id')::uuid;
  select coalesce(jsonb_agg(jsonb_build_object('kind',x.kind,'id',x.id,'title',x.title,'recipient_id',x.recipient_id,
    'activity_date',(x.happened_at at time zone 'Asia/Tokyo')::date,'target_date',x.target_date)
    order by x.happened_at desc,x.id),'[]'::jsonb) into result
  from (
    select c.* from (
      select 'task'::text kind,t.id,t.title,
        coalesce(case when t.actual_completed_by_id<>p_actor_id then t.actual_completed_by_id end, performer.real_user_id) recipient_id,
        t.completed_at happened_at,t.scheduled_date target_date
      from public.task_instances t
      left join lateral (
        select a.real_user_id from public.task_actual_participants p
        join public.domain_actor_refs a on a.household_id=p.household_id and a.id=p.actor_ref_id
        where p.household_id=t.household_id and p.task_instance_id=t.id and p.removed_at is null
          and p.test_context_id is null and a.actor_kind='real_user' and a.real_user_id<>p_actor_id
        order by p.recorded_at,a.id limit 1
      ) performer on true
      where t.household_id=hh and t.test_context_id is null and t.status='completed'
        and t.planned_assignee_id=p_actor_id and t.completed_at>=period_start and t.completed_at<period_end
        and (t.actual_completed_by_id<>p_actor_id or performer.real_user_id is not null)
      union all
      select 'request',r.id,r.shared_title,r.recipient_id,r.accepted_at,task.scheduled_date
      from public.requests r
      left join public.task_instances task on task.household_id=r.household_id and task.test_context_id is null
        and task.id=coalesce(r.assignment_task_instance_id,r.linked_task_instance_id)
      where r.household_id=hh and r.test_context_id is null and r.requester_id=p_actor_id
        and r.recipient_id<>p_actor_id and r.status in ('accepted','completed')
        and r.accepted_at>=period_start and r.accepted_at<period_end
    ) c
    where not exists(select 1 from private.sent_thanks s where s.household_id=hh and s.sender_id=p_actor_id
      and s.source_kind=c.kind and s.source_id=c.id)
      -- The same accepted request and its linked completed task are one act.
      and not (c.kind='task' and exists (
        select 1 from public.requests r join private.sent_thanks s
          on s.household_id=r.household_id and s.sender_id=p_actor_id
          and s.source_kind='request' and s.source_id=r.id and s.recipient_id=c.recipient_id
        where r.household_id=hh and r.requester_id=p_actor_id and r.recipient_id=c.recipient_id
          and r.linked_task_instance_id=c.id and r.test_context_id is null
      ))
      and not (c.kind='request' and exists (
        select 1 from public.requests r
        join public.task_instances t on t.household_id=r.household_id and t.id=r.linked_task_instance_id
        where r.household_id=hh and r.id=c.id and r.test_context_id is null and t.test_context_id is null
          and (exists (select 1 from private.sent_thanks s where s.household_id=hh and s.sender_id=p_actor_id
                and s.source_kind='task' and s.source_id=t.id and s.recipient_id=c.recipient_id)
            or (t.status='completed' and t.planned_assignee_id=p_actor_id and
              coalesce(case when t.actual_completed_by_id<>p_actor_id then t.actual_completed_by_id end,
                (select a.real_user_id from public.task_actual_participants p
                 join public.domain_actor_refs a on a.household_id=p.household_id and a.id=p.actor_ref_id
                 where p.household_id=t.household_id and p.task_instance_id=t.id and p.removed_at is null
                   and p.test_context_id is null and a.actor_kind='real_user' and a.real_user_id<>p_actor_id
                 order by p.recorded_at,a.id limit 1))=c.recipient_id))
      ))
    order by c.happened_at desc nulls last,c.id limit 5
  ) x;
  return result;
end $$;
revoke all on function public.server_read_thanks_candidates(uuid,date) from public,anon,authenticated;
grant execute on function public.server_read_thanks_candidates(uuid,date) to service_role;
