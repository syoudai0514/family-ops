-- Lane D compatibility correction.
--
-- 20260909122000 temporarily repurposed the historical
-- public.server_tx_get_today_schedule(uuid) RPC as a LINE DailyBrief adapter.
-- That changed an established read contract used by compatibility callers and
-- by the SQL suite. Restore the original schedule semantics verbatim, and give
-- LINE `今日` its own presentation-only DailyBrief reader instead.
--
-- DailyBrief remains the canonical semantic read model for PWA Today / LINE
-- Today / morning / evening. The schedule RPC below is retained only as the
-- legacy detailed schedule contract and is no longer the LINE Today boundary.

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
      ti.household_id, ti.planned_assignee_id, ti.due_at,
      coalesce(rr.conflict_window_minutes, 60)
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

create or replace function public.server_read_line_today_daily_brief(
  p_actor_id uuid
) returns text
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_date date := (now() at time zone 'Asia/Tokyo')::date;
begin
  if p_actor_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  -- Authorization and household membership are enforced by the canonical
  -- DailyBrief reader reached by this renderer.
  return public.server_render_daily_brief_text(p_actor_id, v_date);
end;
$$;

revoke all on function public.server_read_line_today_daily_brief(uuid)
  from public, anon, authenticated;
grant execute on function public.server_read_line_today_daily_brief(uuid)
  to service_role;
