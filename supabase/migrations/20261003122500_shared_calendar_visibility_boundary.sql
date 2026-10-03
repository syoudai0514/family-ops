-- Owner decision 2026-10-03:
-- only the explicitly selected family calendar is household-visible.
-- Other connected Google calendars may still participate in server-side
-- busy/conflict detection, but their event details must not reach PWA/LINE
-- shared schedule surfaces or direct browser reads.

-- Browser reads are an independent privacy boundary. Existing household
-- membership policies are permissive, so add restrictive SELECT policies.
drop policy if exists calendar_event_occurrences_family_target_only
  on public.calendar_event_occurrences;
create policy calendar_event_occurrences_family_target_only
  on public.calendar_event_occurrences
  as restrictive
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.calendar_connections cc
      where cc.household_id = calendar_event_occurrences.household_id
        and cc.id = calendar_event_occurrences.calendar_connection_id
        and cc.active
        and cc.is_family_write_target is true
    )
  );

drop policy if exists calendar_events_cache_family_target_only
  on public.calendar_events_cache;
create policy calendar_events_cache_family_target_only
  on public.calendar_events_cache
  as restrictive
  for select
  to authenticated
  using (
    exists (
      select 1
      from public.calendar_connections cc
      where cc.household_id = calendar_events_cache.household_id
        and cc.id = calendar_events_cache.calendar_connection_id
        and cc.active
        and cc.is_family_write_target is true
    )
  );

-- One canonical shared-schedule projection for DailyBrief/Today/LINE.
-- Family Events remain visible; Google details come only from the selected target.
create or replace function private.fn_household_visible_schedule_v1(
  p_household_id uuid,
  p_local_date date
) returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(x.item order by x.sort_key, x.title), '[]'::jsonb)
  from (
    select
      case when e.all_day then 0 else 1 end as sort_key,
      e.title,
      jsonb_build_object(
        'kind', 'family_event',
        'family_event_id', e.id,
        'title', e.title,
        'is_all_day', e.all_day,
        'starts_at', case when e.all_day then 'null'::jsonb else to_jsonb(e.starts_at) end,
        'ends_at', case when e.all_day then 'null'::jsonb else to_jsonb(e.ends_at) end,
        'all_day_start', e.starts_on,
        'all_day_end_exclusive', case when e.all_day then e.ends_on + 1 else null end,
        'revision', e.revision
      ) as item
    from public.family_events e
    where e.household_id = p_household_id
      and e.test_context_id is null
      and e.status <> 'cancelled'
      and (
        (e.all_day and e.starts_on <= p_local_date and e.ends_on >= p_local_date)
        or (not e.all_day and (e.starts_at at time zone 'Asia/Tokyo')::date = p_local_date)
      )

    union all

    select
      case when o.all_day_start is not null then 0 else 1 end as sort_key,
      coalesce(o.title, '') as title,
      jsonb_build_object(
        'kind', 'google_occurrence',
        'occurrence_key', o.occurrence_key,
        'title', o.title,
        'is_all_day', o.all_day_start is not null,
        'starts_at', case when o.all_day_start is null then to_jsonb(o.starts_at) else 'null'::jsonb end,
        'ends_at', case when o.all_day_start is null then to_jsonb(o.ends_at) else 'null'::jsonb end,
        'all_day_start', o.all_day_start,
        'all_day_end_exclusive', o.all_day_end_exclusive
      ) as item
    from public.calendar_event_occurrences o
    join public.calendar_connections c
      on c.household_id = o.household_id
     and c.id = o.calendar_connection_id
    where o.household_id = p_household_id
      and c.active
      and c.is_family_write_target is true
      and o.status <> 'cancelled'
      and coalesce(o.transparency, 'opaque') <> 'transparent'
      and (
        (o.all_day_start is not null
          and o.all_day_start <= p_local_date
          and coalesce(o.all_day_end_exclusive, o.all_day_start + 1) > p_local_date)
        or
        (o.all_day_start is null
          and o.starts_at is not null
          and (o.starts_at at time zone 'Asia/Tokyo')::date = p_local_date)
      )
      and not exists (
        select 1
        from public.family_event_external_links l
        where l.household_id = p_household_id
          and l.calendar_connection_id = o.calendar_connection_id
          and l.google_event_id = o.google_event_id
          and l.test_context_id is null
      )
  ) x;
$$;

revoke all on function private.fn_household_visible_schedule_v1(uuid, date)
  from public, anon, authenticated;
grant execute on function private.fn_household_visible_schedule_v1(uuid, date)
  to service_role;

-- Keep the CURRENT purpose-first/Codmon wrapper, but replace its shared
-- schedule arrays with the canonical target-only projection.
create or replace function public.server_read_daily_brief(
  p_actor_id uuid,
  p_local_date date default null
) returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_brief jsonb;
  v_household_id uuid;
  v_date date;
  v_schedule jsonb;
  v_tomorrow jsonb;
  v_tomorrow_schedule jsonb;
  v_sections jsonb;
  v_tomorrow_task_count integer;
  v_tomorrow_carryover_count integer;
begin
  if p_actor_id is null then raise exception 'INVALID_INPUT'; end if;

  select hm.household_id into v_household_id
  from public.household_members hm
  where hm.user_id = p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;

  v_brief := public.server_read_daily_brief_pre_codmon_readiness_v1(
    p_actor_id, p_local_date
  );
  v_date := coalesce(
    p_local_date,
    nullif(v_brief->>'local_date', '')::date,
    (now() at time zone 'Asia/Tokyo')::date
  );

  v_schedule := private.fn_household_visible_schedule_v1(v_household_id, v_date);
  v_tomorrow_schedule := private.fn_household_visible_schedule_v1(v_household_id, v_date + 1);

  v_tomorrow := coalesce(v_brief->'tomorrow_impact', '{}'::jsonb);
  v_tomorrow_task_count := coalesce((v_tomorrow->>'task_count')::integer, 0);
  v_tomorrow_carryover_count := coalesce((v_tomorrow->>'carryover_count')::integer, 0);
  v_tomorrow := v_tomorrow || jsonb_build_object(
    'schedule', v_tomorrow_schedule,
    'schedule_count', jsonb_array_length(v_tomorrow_schedule),
    'impact_count',
      v_tomorrow_task_count
      + jsonb_array_length(v_tomorrow_schedule)
      + v_tomorrow_carryover_count
  );

  v_sections := coalesce(v_brief->'sections', '{}'::jsonb)
    || jsonb_build_object(
      'schedule', v_schedule,
      'tomorrow_impact', v_tomorrow
    );

  return v_brief || jsonb_build_object(
    'schedule', v_schedule,
    'tomorrow_impact', v_tomorrow,
    'sections', v_sections,
    'codmon', private.fn_codmon_readiness_v1(
      v_household_id, v_date, null
    )
  );
end;
$$;

revoke all on function public.server_read_daily_brief(uuid, date)
  from public, anon, authenticated;
grant execute on function public.server_read_daily_brief(uuid, date)
  to service_role;

-- Today detail: visible occurrences are target-only. Conflict detection below
-- deliberately keeps using private.fn_calendar_conflict_exists, which may
-- consult non-target calendars server-side.
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
    bool_or(cc.active and cc.is_family_write_target is true),
    bool_or(cc.active and cc.is_family_write_target is true and (
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
    and cc.is_family_write_target is true
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

revoke all on function public.server_tx_get_today_schedule(uuid)
  from public, anon, authenticated;
grant execute on function public.server_tx_get_today_schedule(uuid)
  to service_role;

create or replace function public.server_tx_get_week_schedule(
  p_actor_id uuid,
  p_start_date date,
  p_end_date date
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
  if p_actor_id is null
     or p_start_date is null
     or p_end_date is null
     or p_end_date < p_start_date
     or p_end_date > p_start_date + 6 then
    raise exception 'INVALID_INPUT';
  end if;

  select household_id into v_household_id
  from public.household_members
  where user_id = p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;

  select
    bool_or(active and is_family_write_target is true),
    bool_or(active and is_family_write_target is true and (
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
    and cc.is_family_write_target is true
    and occ.status <> 'cancelled'
    and occ.all_day_start is null
    and occ.starts_at is not null
    and coalesce(occ.transparency, 'opaque') <> 'transparent'
    and (occ.starts_at at time zone 'Asia/Tokyo')::date
      between p_start_date and p_end_date;

  select coalesce(jsonb_agg(jsonb_build_object(
    'task_instance_id', ti.id,
    'title', ti.title,
    'category', ti.category,
    'due_at', ti.due_at,
    'planned_assignee_id', ti.planned_assignee_id,
    'has_conflict', private.fn_calendar_conflict_exists(
      ti.household_id, ti.planned_assignee_id, ti.due_at,
      coalesce(rr.conflict_window_minutes, 60)
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

revoke all on function public.server_tx_get_week_schedule(uuid, date, date)
  from public, anon, authenticated;
grant execute on function public.server_tx_get_week_schedule(uuid, date, date)
  to service_role;

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
        else '・' || to_char(occ.starts_at at time zone 'Asia/Tokyo', 'HH24:MI')
          || ' ' || coalesce(occ.title, '(無題の予定)')
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
      and cc.is_family_write_target is true
      and occ.status <> 'cancelled'
      and (
        (occ.all_day_start is not null
          and p_day >= occ.all_day_start
          and p_day < occ.all_day_end_exclusive)
        or
        (occ.all_day_start is null
          and occ.starts_at is not null
          and p_day between
            (occ.starts_at at time zone 'Asia/Tokyo')::date
            and (coalesce(occ.ends_at, occ.starts_at) at time zone 'Asia/Tokyo')::date)
      )
  ) lines;
$$;

revoke all on function private.fn_calendar_day_lines(uuid, date)
  from public, anon, authenticated;
grant execute on function private.fn_calendar_day_lines(uuid, date)
  to service_role;
