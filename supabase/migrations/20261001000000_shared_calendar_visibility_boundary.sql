-- Household-visible Google Calendar boundary.
-- Product decision 2026-09-30: only the explicitly selected family calendar may
-- expose event details to household-facing PWA/LINE surfaces. Other connected
-- calendars may still participate in server-side busy/conflict detection.

-- Direct browser reads must not rely on React filtering alone.
drop policy if exists calendar_events_cache_select on public.calendar_events_cache;
create policy calendar_events_cache_select
on public.calendar_events_cache
for select to authenticated
using (
  public.is_household_member(household_id)
  and exists (
    select 1
    from public.calendar_connections cc
    where cc.household_id = calendar_events_cache.household_id
      and cc.id = calendar_events_cache.calendar_connection_id
      and cc.active
      and cc.is_family_write_target
  )
);

drop policy if exists calendar_event_occurrences_select on public.calendar_event_occurrences;
create policy calendar_event_occurrences_select
on public.calendar_event_occurrences
for select to authenticated
using (
  public.is_household_member(household_id)
  and exists (
    select 1
    from public.calendar_connections cc
    where cc.household_id = calendar_event_occurrences.household_id
      and cc.id = calendar_event_occurrences.calendar_connection_id
      and cc.active
      and cc.is_family_write_target
  )
);

-- Today schedule: display details from the selected family calendar only.
-- Conflict flags intentionally keep using private.fn_calendar_conflict_exists,
-- which can use every active calendar's busy attribution.
create or replace function public.server_tx_get_today_schedule(
  p_actor_id uuid
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_today date := (now() at time zone 'Asia/Tokyo')::date;
  v_calendar_connected boolean;
  v_calendar_stale boolean;
  v_occurrences jsonb;
  v_assignments jsonb;
  v_result jsonb;
begin
  if p_actor_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  select household_id into v_household_id
  from public.household_members
  where user_id = p_actor_id;

  if v_household_id is null then
    raise exception 'NOT_HOUSEHOLD_MEMBER';
  end if;

  select
    bool_or(cc.active),
    bool_or(cc.active and (
      cc.reauth_required
      or cc.last_incremental_sync_at is null
      or cc.last_incremental_sync_at < now() - interval '60 minutes'
    ))
  into v_calendar_connected, v_calendar_stale
  from public.calendar_connections cc
  where cc.household_id = v_household_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'occurrence_key', occ.occurrence_key,
    'title', occ.title,
    'starts_at', occ.starts_at,
    'ends_at', occ.ends_at,
    'busy_user_ids', (
      select coalesce(jsonb_agg(bm.user_id), '[]'::jsonb)
      from public.calendar_occurrence_busy_members bm
      where bm.household_id = occ.household_id
        and bm.calendar_connection_id = occ.calendar_connection_id
        and bm.occurrence_key = occ.occurrence_key
    )
  ) order by occ.starts_at), '[]'::jsonb)
  into v_occurrences
  from public.calendar_event_occurrences occ
  join public.calendar_connections cc
    on cc.household_id = occ.household_id and cc.id = occ.calendar_connection_id
  where occ.household_id = v_household_id
    and cc.active
    and cc.is_family_write_target
    and occ.status <> 'cancelled'
    and occ.all_day_start is null
    and occ.starts_at is not null
    and coalesce(occ.transparency, 'opaque') <> 'transparent'
    and (occ.starts_at at time zone 'Asia/Tokyo')::date = v_today;

  select coalesce(jsonb_agg(jsonb_build_object(
    'task_instance_id', ti.id,
    'title', ti.title,
    'category', ti.category,
    'due_at', ti.due_at,
    'planned_assignee_id', ti.planned_assignee_id,
    'has_conflict', private.fn_calendar_conflict_exists(
      ti.household_id, ti.planned_assignee_id, ti.due_at, coalesce(rr.conflict_window_minutes, 60)
    )
  ) order by ti.due_at), '[]'::jsonb)
  into v_assignments
  from public.task_instances ti
  left join public.recurrence_rules rr
    on rr.household_id = ti.household_id and rr.id = ti.recurrence_rule_id
  where ti.household_id = v_household_id
    and ti.scheduled_date = v_today
    and ti.status in ('todo', 'in_progress')
    and ti.due_at is not null
    and ti.planned_assignee_id is not null;

  v_result := jsonb_build_object(
    'household_id', v_household_id,
    'local_date', v_today,
    'calendar_connected', coalesce(v_calendar_connected, false),
    'calendar_stale', coalesce(v_calendar_stale, false),
    'occurrences', v_occurrences,
    'assignments', v_assignments
  );

  return v_result;
end;
$$;

revoke all on function public.server_tx_get_today_schedule(uuid) from public, anon, authenticated;
grant execute on function public.server_tx_get_today_schedule(uuid) to service_role;

-- Week schedule follows the same detail-visibility rule.
create or replace function public.server_tx_get_week_schedule(
  p_actor_id uuid, p_start_date date, p_end_date date
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_connected boolean;
  v_stale boolean;
  v_occurrences jsonb;
  v_assignments jsonb;
begin
  if p_actor_id is null or p_start_date is null or p_end_date is null
     or p_end_date < p_start_date or p_end_date > p_start_date + 6 then
    raise exception 'INVALID_INPUT';
  end if;

  select household_id into v_household_id
  from public.household_members
  where user_id = p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;

  select
    bool_or(active),
    bool_or(active and (
      reauth_required
      or last_incremental_sync_at is null
      or last_incremental_sync_at < now() - interval '60 minutes'
    ))
  into v_connected, v_stale
  from public.calendar_connections
  where household_id = v_household_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'occurrence_key', occ.occurrence_key,
    'title', occ.title,
    'starts_at', occ.starts_at,
    'ends_at', occ.ends_at,
    'busy_user_ids', (
      select coalesce(jsonb_agg(bm.user_id), '[]'::jsonb)
      from public.calendar_occurrence_busy_members bm
      where bm.household_id = occ.household_id
        and bm.calendar_connection_id = occ.calendar_connection_id
        and bm.occurrence_key = occ.occurrence_key
    )
  ) order by occ.starts_at), '[]'::jsonb)
  into v_occurrences
  from public.calendar_event_occurrences occ
  join public.calendar_connections cc
    on cc.household_id = occ.household_id and cc.id = occ.calendar_connection_id
  where occ.household_id = v_household_id
    and cc.active
    and cc.is_family_write_target
    and occ.status <> 'cancelled'
    and occ.all_day_start is null
    and occ.starts_at is not null
    and coalesce(occ.transparency, 'opaque') <> 'transparent'
    and (occ.starts_at at time zone 'Asia/Tokyo')::date between p_start_date and p_end_date;

  select coalesce(jsonb_agg(jsonb_build_object(
    'task_instance_id', ti.id,
    'title', ti.title,
    'category', ti.category,
    'due_at', ti.due_at,
    'planned_assignee_id', ti.planned_assignee_id,
    'has_conflict', private.fn_calendar_conflict_exists(
      ti.household_id, ti.planned_assignee_id, ti.due_at, coalesce(rr.conflict_window_minutes, 60)
    )
  ) order by ti.due_at), '[]'::jsonb)
  into v_assignments
  from public.task_instances ti
  left join public.recurrence_rules rr
    on rr.household_id = ti.household_id and rr.id = ti.recurrence_rule_id
  where ti.household_id = v_household_id
    and ti.scheduled_date between p_start_date and p_end_date
    and ti.status in ('todo', 'in_progress')
    and ti.due_at is not null
    and ti.planned_assignee_id is not null;

  return jsonb_build_object(
    'household_id', v_household_id,
    'start_date', p_start_date,
    'end_date', p_end_date,
    'calendar_connected', coalesce(v_connected, false),
    'calendar_stale', coalesce(v_stale, false),
    'occurrences', v_occurrences,
    'assignments', v_assignments
  );
end;
$$;

revoke all on function public.server_tx_get_week_schedule(uuid,date,date) from public, anon, authenticated;
grant execute on function public.server_tx_get_week_schedule(uuid,date,date) to service_role;

-- Legacy digest display helper may still be reached by a fallback lane.
create or replace function private.fn_calendar_day_lines(
  p_household_id uuid,
  p_day date
) returns text
language sql
stable
security invoker
set search_path = ''
as $$
  select string_agg(line, E'\n' order by sort_key, line)
  from (
    select
      case when occ.all_day_start is not null
        then '・' || coalesce(occ.title, '(無題の予定)')
        else '・' || to_char(occ.starts_at at time zone 'Asia/Tokyo', 'HH24:MI') || ' ' || coalesce(occ.title, '(無題の予定)')
      end as line,
      case when occ.all_day_start is not null
        then '00:00'
        else to_char(occ.starts_at at time zone 'Asia/Tokyo', 'HH24:MI')
      end as sort_key
    from public.calendar_event_occurrences occ
    join public.calendar_connections cc
      on cc.household_id = occ.household_id and cc.id = occ.calendar_connection_id
    where occ.household_id = p_household_id
      and cc.active
      and cc.is_family_write_target
      and occ.status <> 'cancelled'
      and (
        (occ.all_day_start is not null
          and p_day >= occ.all_day_start and p_day < occ.all_day_end_exclusive)
        or (occ.all_day_start is null and occ.starts_at is not null
          and p_day between (occ.starts_at at time zone 'Asia/Tokyo')::date
                         and (coalesce(occ.ends_at, occ.starts_at) at time zone 'Asia/Tokyo')::date)
      )
  ) lines;
$$;

revoke all on function private.fn_calendar_day_lines(uuid,date) from public, anon, authenticated;
grant execute on function private.fn_calendar_day_lines(uuid,date) to service_role;

-- DailyBrief compatibility core. Keep every existing non-calendar semantic
-- unchanged; only Google schedule details are restricted to the family target.
create or replace function public.server_read_daily_brief_base_v1(
  p_actor_id uuid, p_local_date date default null
) returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_household_id uuid; v_actor_ref_id uuid;
  v_date date:=coalesce(p_local_date,(now() at time zone 'Asia/Tokyo')::date);
  v_day_end timestamptz:=((coalesce(p_local_date,(now() at time zone 'Asia/Tokyo')::date)+1)::timestamp at time zone 'Asia/Tokyo');
  v_tasks jsonb; v_requests jsonb; v_waiting jsonb; v_carryover jsonb;
  v_handovers jsonb; v_handled jsonb; v_schedule jsonb; v_shopping jsonb; v_partner jsonb;
begin
  if p_actor_id is null then raise exception 'INVALID_INPUT'; end if;
  select household_id into v_household_id from public.household_members where user_id=p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  select id into v_actor_ref_id from public.domain_actor_refs
    where household_id=v_household_id and actor_kind='real_user' and real_user_id=p_actor_id;

  select coalesce(jsonb_agg(jsonb_build_object(
    'task_id',t.id,'title',t.title,'status',t.status,'task_kind',t.task_kind,
    'category',t.category,'routine_phase',t.routine_phase,'scheduled_date',t.scheduled_date,
    'due_at',t.due_at,'planned_assignee_id',t.planned_assignee_id,
    'planned_assignee_actor_ref_id',t.planned_assignee_actor_ref_id,
    'assignment_mode',coalesce(t.assignment_mode,case when t.planned_assignee_id is null then 'unassigned' else 'person' end),
    'completion_mode',t.completion_mode,'expectation',coalesce(t.expectation,'normal'),
    'duplicate_sensitivity',coalesce(t.duplicate_sensitivity,'normal'),'revision',t.revision,
    'action_target',jsonb_build_object('kind','task','task_id',t.id,'revision',t.revision)
  ) order by t.due_at nulls last,t.title),'[]'::jsonb) into v_tasks
  from public.task_instances t where t.household_id=v_household_id and t.test_context_id is null
    and t.scheduled_date=v_date and t.status in ('todo','in_progress') and t.attention_state='active'
    and ((t.planned_assignee_actor_ref_id=v_actor_ref_id)
      or (t.planned_assignee_actor_ref_id is null and t.planned_assignee_id=p_actor_id)
      or t.active_claimant_actor_ref_id=v_actor_ref_id);

  select coalesce(jsonb_agg(jsonb_build_object(
    'task_id',t.id,'title',t.title,'scheduled_date',t.scheduled_date,'due_at',t.due_at,
    'carryover_policy',t.carryover_policy,'result_certainty','unknown','semantic_result','result_unconfirmed',
    'revision',t.revision
  ) order by t.due_at nulls last,t.scheduled_date),'[]'::jsonb) into v_carryover
  from public.task_instances t where t.household_id=v_household_id and t.test_context_id is null
    and t.scheduled_date<v_date and t.status in ('todo','in_progress')
    and t.attention_state='active' and t.carryover_policy in ('until_done','until_deadline')
    and (t.carryover_policy<>'until_deadline' or t.due_at is null or t.due_at>=((v_date)::timestamp at time zone 'Asia/Tokyo'))
    and ((t.planned_assignee_actor_ref_id=v_actor_ref_id)
      or (t.planned_assignee_actor_ref_id is null and t.planned_assignee_id=p_actor_id)
      or t.active_claimant_actor_ref_id=v_actor_ref_id);

  select coalesce(jsonb_agg(jsonb_build_object(
    'request_id',r.id,'attempt_id',a.id,'attempt_kind',a.attempt_kind,'state',a.state,
    'title',r.shared_title,'message',r.shared_message,'reply_due_at',a.reply_due_at,
    'agreement_established',agreement.id is not null,'request_revision',r.revision,
    'revision',a.revision,'terms_revision',a.terms_revision,
    'action_target',jsonb_build_object('kind','request','request_id',r.id,
      'attempt_id',a.id,'revision',a.revision,'terms_revision',a.terms_revision)
  ) order by a.reply_due_at nulls last,a.created_at),'[]'::jsonb) into v_requests
  from public.requests r
  join lateral (
    select x.* from public.request_attempts x
    where x.household_id=r.household_id and x.request_id=r.id and x.test_context_id is null
      and x.state in ('pending','checking','consulting','awaiting_confirmation')
    order by x.created_at desc limit 1
  ) a on true
  left join lateral (
    select x.id from public.request_attempts x
    where x.request_id=r.id and x.attempt_kind in ('initial','reproposal') and x.state='accepted'
    limit 1
  ) agreement on true
  where r.household_id=v_household_id and r.test_context_id is null
    and v_actor_ref_id in (r.requester_actor_ref_id,r.recipient_actor_ref_id)
    and not exists (select 1 from public.request_attempt_confirmations c
      where c.attempt_id=a.id and c.terms_revision=a.terms_revision and c.actor_ref_id=v_actor_ref_id)
    and (
      (a.attempt_kind in ('initial','reproposal') and r.recipient_actor_ref_id=v_actor_ref_id)
      or (a.attempt_kind in ('change','cancel') and a.created_by_actor_ref_id<>v_actor_ref_id)
    );

  select coalesce(jsonb_agg(jsonb_build_object(
    'task_id',t.id,'title',t.title,'waiting_note',t.waiting_note,'next_check_at',t.next_check_at,
    'due_at',t.due_at,'hard_due_risk',t.due_at is not null and t.due_at<v_day_end,'revision',t.revision
  ) order by t.next_check_at nulls last,t.due_at nulls last),'[]'::jsonb) into v_waiting
  from public.task_instances t where t.household_id=v_household_id and t.test_context_id is null
    and t.status in ('todo','in_progress') and t.attention_state='waiting'
    and (t.next_check_at is not null and t.next_check_at<v_day_end
      or t.due_at is not null and t.due_at<v_day_end)
    and ((t.planned_assignee_actor_ref_id=v_actor_ref_id)
      or (t.planned_assignee_actor_ref_id is null and t.planned_assignee_id=p_actor_id)
      or t.active_claimant_actor_ref_id=v_actor_ref_id);

  select coalesce(jsonb_agg(jsonb_build_object(
    'handover_id',h.id,'shared_text',h.shared_text,'period',h.period,'categories',h.categories,
    'valid_until',h.valid_until,'ack_policy',h.ack_policy,'revision',h.revision
  ) order by h.created_at desc),'[]'::jsonb) into v_handovers
  from public.handovers h where h.household_id=v_household_id and h.test_context_id is null
    and h.status='active' and h.visibility='household'
    and h.valid_from<v_day_end and (h.valid_until is null or h.valid_until>=((v_date)::timestamp at time zone 'Asia/Tokyo'))
    and not exists (select 1 from public.info_acknowledgements a
      where a.handover_id=h.id and a.actor_ref_id=v_actor_ref_id and a.test_context_id is null);

  select coalesce(jsonb_agg(jsonb_build_object(
    'kind','task','task_id',t.id,'title',t.title,'completed_at',t.completed_at,
    'duplicate_sensitivity',t.duplicate_sensitivity,'revision',t.revision
  ) order by t.completed_at desc),'[]'::jsonb) into v_handled
  from public.task_instances t where t.household_id=v_household_id and t.test_context_id is null
    and t.scheduled_date=v_date and t.status='completed'
    and t.duplicate_sensitivity in ('avoid_duplicate','safety_critical');

  select coalesce(jsonb_agg(x.item order by x.sort_key,x.title),'[]'::jsonb) into v_schedule
  from (
    select case when e.all_day then 0 else 1 end sort_key,e.title,
      jsonb_build_object('kind','family_event','family_event_id',e.id,'title',e.title,
        'is_all_day',e.all_day,
        'starts_at',case when e.all_day then 'null'::jsonb else to_jsonb(e.starts_at) end,
        'ends_at',case when e.all_day then 'null'::jsonb else to_jsonb(e.ends_at) end,
        'all_day_start',e.starts_on,'all_day_end_exclusive',case when e.all_day then e.ends_on+1 else null end,
        'revision',e.revision) item
    from public.family_events e where e.household_id=v_household_id and e.test_context_id is null
      and e.status<>'cancelled' and ((e.all_day and e.starts_on<=v_date and e.ends_on>=v_date)
        or (not e.all_day and (e.starts_at at time zone 'Asia/Tokyo')::date=v_date))
    union all
    select case when o.all_day_start is not null then 0 else 1 end,coalesce(o.title,''),
      jsonb_build_object('kind','google_occurrence','occurrence_key',o.occurrence_key,'title',o.title,
        'is_all_day',o.all_day_start is not null,
        'starts_at',case when o.all_day_start is null then to_jsonb(o.starts_at) else 'null'::jsonb end,
        'ends_at',case when o.all_day_start is null then to_jsonb(o.ends_at) else 'null'::jsonb end,
        'all_day_start',o.all_day_start,'all_day_end_exclusive',o.all_day_end_exclusive)
    from public.calendar_event_occurrences o
    join public.calendar_connections c on c.household_id=o.household_id and c.id=o.calendar_connection_id
    where o.household_id=v_household_id
      and c.active
      and c.is_family_write_target
      and o.status<>'cancelled'
      and coalesce(o.transparency,'opaque')<>'transparent'
      and ((o.all_day_start is not null and o.all_day_start<=v_date
          and coalesce(o.all_day_end_exclusive,o.all_day_start+1)>v_date)
        or (o.all_day_start is null and o.starts_at is not null
          and (o.starts_at at time zone 'Asia/Tokyo')::date=v_date))
      and not exists (select 1 from public.family_event_external_links l
        where l.household_id=v_household_id and l.calendar_connection_id=o.calendar_connection_id
          and l.google_event_id=o.google_event_id and l.test_context_id is null)
  ) x;

  v_shopping:=public.server_read_shopping_workspace(p_actor_id)->'active';
  select jsonb_build_object(
    'open_assigned',count(*) filter(where t.status in ('todo','in_progress')),
    'completed_today',count(*) filter(where t.status='completed' and t.scheduled_date=v_date)
  ) into v_partner from public.task_instances t
  where t.household_id=v_household_id and t.test_context_id is null
    and t.planned_assignee_actor_ref_id is distinct from v_actor_ref_id
    and t.planned_assignee_actor_ref_id is not null
    and (
      (t.status in ('todo','in_progress') and t.scheduled_date=v_date)
      or (t.status='completed' and t.scheduled_date=v_date)
    );

  return jsonb_build_object(
    'generated_at',now(),'household_id',v_household_id,'local_date',v_date,
    'urgent_actions',v_requests,'exceptions',v_waiting||v_carryover,
    'waiting_checks',v_waiting,'carryover',v_carryover,'handovers',v_handovers,
    'already_handled',v_handled,'tasks',v_tasks,'schedule',v_schedule,
    'shopping',v_shopping,'partner_summary',coalesce(v_partner,'{}'::jsonb),
    'sections',jsonb_build_object(
      'confirm_first',v_requests,'unusual',v_waiting||v_carryover,
      'handover',v_handovers,'already_handled',v_handled,
      'today_tasks',v_tasks,'shopping',v_shopping,'schedule',v_schedule
    )
  );
end;
$$;

revoke all on function public.server_read_daily_brief_base_v1(uuid,date)
  from public, anon, authenticated;
grant execute on function public.server_read_daily_brief_base_v1(uuid,date)
  to service_role;
