-- WP-DD5B / WP-DD6 inactive read models.
--
-- Shopping remains partial until a formal canonical Shopping command layer
-- exists. No Shopping writer is introduced here. DailyBrief is read-only and
-- uses the official WP-DD3 foundation schedule names/override table.

create or replace function public.server_read_shopping_workspace(
  p_actor_id uuid
) returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_actor_ref_id uuid;
  v_active jsonb;
  v_history jsonb;
begin
  if p_actor_id is null then raise exception 'INVALID_INPUT'; end if;
  select household_id into v_household_id
  from public.household_members where user_id = p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;

  select id into v_actor_ref_id
  from public.domain_actor_refs
  where household_id = v_household_id
    and actor_kind = 'real_user' and real_user_id = p_actor_id;

  with shaped as (
    select si.*,
      jsonb_build_object(
        'shopping_item_id', si.id,
        'title', si.title,
        'purchase_method', si.purchase_method,
        'status', si.status,
        'due_at', si.due_at,
        'assignment_mode', coalesce(si.assignment_mode,
          case when si.assignee_id is null then 'unassigned' else 'person' end),
        'assignee_actor_ref_id', si.assignee_actor_ref_id,
        'active_claimant_actor_ref_id', si.active_claimant_actor_ref_id,
        'claimed_at', si.claimed_at,
        'duplicate_sensitivity', coalesce(si.duplicate_sensitivity, 'normal'),
        'performer_count', coalesce(actuals.performer_count, 0),
        'performers', coalesce(actuals.performers, '[]'::jsonb),
        'household_completion_units', case when si.status in ('purchased', 'arrived') then 1 else 0 end,
        'revision', si.revision,
        'action_target', jsonb_build_object(
          'kind', 'shopping', 'shopping_item_id', si.id, 'revision', si.revision
        )
      ) as item
    from public.shopping_items si
    left join lateral (
      select count(*)::int as performer_count,
        jsonb_agg(jsonb_build_object(
          'actor_ref_id', sap.actor_ref_id,
          'real_user_id', ar.real_user_id,
          'actor_kind', ar.actor_kind,
          'simulated_role', ar.simulated_role,
          'recorded_at', sap.created_at,
          'recorded_by_actor_ref_id', sap.recorded_by_actor_ref_id
        ) order by sap.created_at, sap.id) as performers
      from public.shopping_actual_participants sap
      join public.domain_actor_refs ar
        on ar.household_id = sap.household_id and ar.id = sap.actor_ref_id
      where sap.household_id = si.household_id
        and sap.shopping_item_id = si.id
        and sap.test_context_id is null
        and sap.removed_at is null
    ) actuals on true
    where si.household_id = v_household_id and si.test_context_id is null
  )
  select
    coalesce(jsonb_agg(item order by due_at nulls last, created_at)
      filter (where status in ('wanted', 'assigned', 'ordered')), '[]'::jsonb),
    coalesce(jsonb_agg(item order by coalesce(arrived_at, purchased_at, ordered_at, created_at) desc)
      filter (where status in ('purchased', 'arrived', 'cancelled')), '[]'::jsonb)
  into v_active, v_history from shaped;

  return jsonb_build_object(
    'generated_at', now(), 'household_id', v_household_id,
    'actor_ref_id', v_actor_ref_id, 'active', v_active, 'history', v_history,
    'writer_state', 'dependency_gap'
  );
end;
$$;
revoke all on function public.server_read_shopping_workspace(uuid)
  from public, anon, authenticated;
grant execute on function public.server_read_shopping_workspace(uuid) to service_role;

create or replace function private.is_jp_nonworkday(p_local_date date)
returns boolean
language sql stable security invoker set search_path = ''
as $$
  select extract(isodow from p_local_date)::int in (6, 7)
    or exists (select 1 from private.jp_holidays h where h.local_date = p_local_date);
$$;
revoke all on function private.is_jp_nonworkday(date) from public, anon, authenticated;
grant execute on function private.is_jp_nonworkday(date) to service_role;

create or replace function private.resolve_daily_brief_schedule(
  p_household_id uuid,
  p_local_date date,
  p_brief_kind text
) returns table(enabled boolean, local_time time, source text)
language sql stable security invoker set search_path = ''
as $$
  with defaults as (
    select case p_brief_kind
      when 'weekday_morning_brief' then time '06:30'
      when 'nonworkday_morning_brief' then time '09:00'
      when 'evening_brief' then time '20:30'
      else null::time
    end as local_time
  ), base as (
    select hrs.enabled, hrs.local_time
    from public.household_routine_schedules hrs
    where hrs.household_id = p_household_id and hrs.schedule_kind = p_brief_kind
      and p_brief_kind in ('weekday_morning_brief','nonworkday_morning_brief','evening_brief')
  ), override_row as (
    select o.enabled, o.local_time
    from public.household_routine_schedule_overrides o
    where o.household_id = p_household_id and o.local_date = p_local_date
      and o.brief_kind = p_brief_kind
  )
  select
    coalesce(o.enabled, b.enabled, true) as enabled,
    case when o.enabled is false then null::time
      else coalesce(o.local_time, b.local_time, d.local_time) end as local_time,
    case when o.enabled is not null then 'date_override'
      when b.enabled is not null then 'base_schedule' else 'accepted_default' end as source
  from defaults d left join base b on true left join override_row o on true
  where d.local_time is not null;
$$;
revoke all on function private.resolve_daily_brief_schedule(uuid,date,text)
  from public, anon, authenticated;
grant execute on function private.resolve_daily_brief_schedule(uuid,date,text) to service_role;

create or replace function public.server_read_due_daily_brief_slots(
  p_now timestamptz default now()
) returns jsonb
language plpgsql stable security invoker set search_path = ''
as $$
declare
  v_date date := (p_now at time zone 'Asia/Tokyo')::date;
  v_nonworkday boolean := private.is_jp_nonworkday((p_now at time zone 'Asia/Tokyo')::date);
  v_result jsonb;
begin
  with candidate as (
    select h.id household_id, k.brief_kind, r.enabled, r.local_time, r.source
    from public.households h
    cross join lateral (values
      ('weekday_morning_brief'::text),
      ('nonworkday_morning_brief'::text),
      ('evening_brief'::text)
    ) k(brief_kind)
    cross join lateral private.resolve_daily_brief_schedule(h.id,v_date,k.brief_kind) r
    where (k.brief_kind='evening_brief'
      or (not v_nonworkday and k.brief_kind='weekday_morning_brief')
      or (v_nonworkday and k.brief_kind='nonworkday_morning_brief'))
      and r.enabled and r.local_time is not null
  ), due as (
    select c.*, hm.user_id recipient_user_id,
      ((v_date+c.local_time)::timestamp at time zone 'Asia/Tokyo') scheduled_at,
      v_date::text||':'||c.brief_kind||':'||hm.user_id::text dispatch_slot_key
    from candidate c join public.household_members hm on hm.household_id=c.household_id
    where ((v_date+c.local_time)::timestamp at time zone 'Asia/Tokyo') <= p_now
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'household_id',d.household_id,'recipient_user_id',d.recipient_user_id,
    'schedule_kind',d.brief_kind,'local_date',v_date,'local_time',d.local_time,
    'scheduled_at',d.scheduled_at,'schedule_source',d.source,
    'dispatch_slot_key',d.dispatch_slot_key
  ) order by d.scheduled_at,d.household_id,d.recipient_user_id),'[]'::jsonb)
  into v_result from due d
  where not exists (
    select 1 from private.scheduled_dispatch_receipts s
    where s.household_id=d.household_id and s.schedule_kind=d.brief_kind
      and s.scheduled_local_date=v_date and s.recipient_user_id=d.recipient_user_id
  );
  return v_result;
end;
$$;
revoke all on function public.server_read_due_daily_brief_slots(timestamptz)
  from public, anon, authenticated;
grant execute on function public.server_read_due_daily_brief_slots(timestamptz) to service_role;

create or replace function public.server_read_daily_brief(
  p_actor_id uuid,
  p_local_date date default null
) returns jsonb
language plpgsql stable security invoker set search_path = ''
as $$
declare
  v_household_id uuid;
  v_actor_ref_id uuid;
  v_date date := coalesce(p_local_date,(now() at time zone 'Asia/Tokyo')::date);
  v_tasks jsonb;
  v_requests jsonb;
  v_waiting jsonb;
  v_handled jsonb;
  v_schedule jsonb;
  v_shopping jsonb;
begin
  if p_actor_id is null then raise exception 'INVALID_INPUT'; end if;
  select household_id into v_household_id from public.household_members where user_id=p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  select id into v_actor_ref_id from public.domain_actor_refs
  where household_id=v_household_id and actor_kind='real_user' and real_user_id=p_actor_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'task_id',ti.id,'title',ti.title,'status',ti.status,'routine_phase',ti.routine_phase,
    'due_at',ti.due_at,'expectation',coalesce(ti.expectation,'normal'),
    'assignment_mode',coalesce(ti.assignment_mode,case when ti.planned_assignee_id is null then 'unassigned' else 'person' end),
    'revision',ti.revision,'action_target',jsonb_build_object('kind','task','task_id',ti.id,'revision',ti.revision)
  ) order by ti.due_at nulls last,ti.title),'[]'::jsonb) into v_tasks
  from public.task_instances ti
  where ti.household_id=v_household_id and ti.test_context_id is null
    and ti.scheduled_date=v_date and ti.status in ('todo','in_progress')
    and ti.attention_state='active'
    and ((v_actor_ref_id is not null and ti.planned_assignee_actor_ref_id=v_actor_ref_id)
      or (ti.planned_assignee_actor_ref_id is null and ti.planned_assignee_id=p_actor_id)
      or (v_actor_ref_id is not null and ti.active_claimant_actor_ref_id=v_actor_ref_id));

  select coalesce(jsonb_agg(jsonb_build_object(
    'request_id',r.id,'attempt_id',a.id,'state',coalesce(a.state,r.status),
    'title',r.shared_title,'reply_due_at',coalesce(a.reply_due_at,r.due_at),
    'action_target',jsonb_build_object('kind','request','request_id',r.id,'attempt_id',a.id,'revision',coalesce(a.revision,r.revision))
  ) order by coalesce(a.reply_due_at,r.due_at) nulls last),'[]'::jsonb) into v_requests
  from public.requests r
  left join lateral (
    select ra.id,ra.state,ra.reply_due_at,ra.revision from public.request_attempts ra
    where ra.household_id=r.household_id and ra.request_id=r.id and ra.test_context_id is null
      and ra.state in ('pending','checking','consulting','awaiting_confirmation')
    order by ra.created_at desc limit 1
  ) a on true
  where r.household_id=v_household_id and r.test_context_id is null
    and ((v_actor_ref_id is not null and r.recipient_actor_ref_id=v_actor_ref_id)
      or (r.recipient_actor_ref_id is null and r.recipient_id=p_actor_id))
    and (a.id is not null or r.status='pending');

  select coalesce(jsonb_agg(jsonb_build_object(
    'task_id',ti.id,'title',ti.title,'waiting_note',ti.waiting_note,
    'next_check_at',ti.next_check_at,'due_at',ti.due_at,'revision',ti.revision
  ) order by ti.next_check_at nulls last),'[]'::jsonb) into v_waiting
  from public.task_instances ti
  where ti.household_id=v_household_id and ti.test_context_id is null
    and ti.status in ('todo','in_progress') and ti.attention_state='waiting'
    and ((v_actor_ref_id is not null and ti.planned_assignee_actor_ref_id=v_actor_ref_id)
      or (ti.planned_assignee_actor_ref_id is null and ti.planned_assignee_id=p_actor_id)
      or (v_actor_ref_id is not null and ti.active_claimant_actor_ref_id=v_actor_ref_id));

  select coalesce(jsonb_agg(jsonb_build_object(
    'task_id',ti.id,'title',ti.title,'completed_at',ti.completed_at,
    'duplicate_sensitivity',ti.duplicate_sensitivity,'revision',ti.revision
  ) order by ti.completed_at desc),'[]'::jsonb) into v_handled
  from public.task_instances ti
  where ti.household_id=v_household_id and ti.test_context_id is null
    and ti.scheduled_date=v_date and ti.status='completed'
    and ti.duplicate_sensitivity in ('avoid_duplicate','safety_critical');

  select coalesce(jsonb_agg(x.item order by x.sort_key,x.title),'[]'::jsonb) into v_schedule
  from (
    select case when occ.all_day_start is not null then 0 else 1 end sort_key,
      coalesce(occ.title,'') title,
      jsonb_build_object(
        'kind','google_occurrence','occurrence_key',occ.occurrence_key,'title',occ.title,
        'is_all_day',occ.all_day_start is not null,
        'starts_at',case when occ.all_day_start is null then to_jsonb(occ.starts_at) else 'null'::jsonb end,
        'ends_at',case when occ.all_day_start is null then to_jsonb(occ.ends_at) else 'null'::jsonb end,
        'all_day_start',occ.all_day_start,'all_day_end_exclusive',occ.all_day_end_exclusive
      ) item
    from public.calendar_event_occurrences occ
    join public.calendar_connections cc on cc.household_id=occ.household_id and cc.id=occ.calendar_connection_id
    where occ.household_id=v_household_id and cc.active and occ.status<>'cancelled'
      and coalesce(occ.transparency,'opaque')<>'transparent'
      and ((occ.all_day_start is not null and occ.all_day_start<=v_date
             and coalesce(occ.all_day_end_exclusive,occ.all_day_start+1)>v_date)
        or (occ.all_day_start is null and occ.starts_at is not null
             and (occ.starts_at at time zone 'Asia/Tokyo')::date=v_date))
  ) x;

  v_shopping := public.server_read_shopping_workspace(p_actor_id)->'active';
  return jsonb_build_object(
    'generated_at',now(),'household_id',v_household_id,'local_date',v_date,
    'urgent_actions',v_requests,'tasks',v_tasks,'waiting_checks',v_waiting,
    'already_handled',v_handled,'schedule',v_schedule,'shopping',v_shopping
  );
end;
$$;
revoke all on function public.server_read_daily_brief(uuid,date)
  from public, anon, authenticated;
grant execute on function public.server_read_daily_brief(uuid,date) to service_role;

create or replace function public.get_my_daily_brief(p_local_date date default null)
returns jsonb
language plpgsql stable security definer set search_path = ''
as $$
declare v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null then raise exception 'AUTH_REQUIRED'; end if;
  return public.server_read_daily_brief(v_actor_id,p_local_date);
end;
$$;
revoke all on function public.get_my_daily_brief(date) from public,anon;
grant execute on function public.get_my_daily_brief(date) to authenticated;
