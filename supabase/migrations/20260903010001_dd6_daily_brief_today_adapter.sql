-- WP-DD6: converge the existing Today/PWA and LINE "今日" schedule readers on
-- the shared server DailyBrief without enabling any new mutation state.
--
-- Both current consumers already call server_tx_get_today_schedule.  Replacing
-- that READ function behind the stable signature gives us one read cutover:
-- Google occurrences now come from server_read_daily_brief, including all-day
-- entries represented as dates + NULL timestamps.  Assignment conflict data is
-- still computed by the accepted single timed-conflict predicate.

create or replace function public.server_read_today_schedule_from_daily_brief(
  p_actor_id uuid
) returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_today date := (now() at time zone 'Asia/Tokyo')::date;
  v_brief jsonb;
  v_calendar_connected boolean;
  v_calendar_stale boolean;
  v_occurrences jsonb;
  v_assignments jsonb;
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

  v_brief := public.server_read_daily_brief(p_actor_id, v_today);

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
    'occurrence_key', e->>'occurrence_key',
    'title', e->'title',
    'starts_at', e->'starts_at',
    'ends_at', e->'ends_at',
    'is_all_day', coalesce((e->>'is_all_day')::boolean, false),
    'all_day_start', e->'all_day_start',
    'all_day_end_exclusive', e->'all_day_end_exclusive',
    'busy_user_ids', coalesce(e->'busy_user_ids', '[]'::jsonb)
  ) order by
    case when coalesce((e->>'is_all_day')::boolean, false) then 0 else 1 end,
    e->>'starts_at',
    e->>'title'
  ), '[]'::jsonb)
  into v_occurrences
  from jsonb_array_elements(v_brief->'schedule') e
  where e->>'kind' = 'google_occurrence';

  select coalesce(jsonb_agg(jsonb_build_object(
    'task_instance_id', ti.id,
    'title', ti.title,
    'category', ti.category,
    'due_at', ti.due_at,
    'planned_assignee_id', ti.planned_assignee_id,
    'has_conflict', private.fn_calendar_conflict_exists(
      ti.household_id,
      ti.planned_assignee_id,
      ti.due_at,
      coalesce(rr.conflict_window_minutes, 60)
    )
  ) order by ti.due_at), '[]'::jsonb)
  into v_assignments
  from public.task_instances ti
  left join public.recurrence_rules rr
    on rr.household_id = ti.household_id and rr.id = ti.recurrence_rule_id
  where ti.household_id = v_household_id
    and ti.test_context_id is null
    and ti.scheduled_date = v_today
    and ti.status in ('todo', 'in_progress')
    and ti.due_at is not null
    and ti.planned_assignee_id is not null;

  return jsonb_build_object(
    'household_id', v_household_id,
    'local_date', v_today,
    'calendar_connected', coalesce(v_calendar_connected, false),
    'calendar_stale', coalesce(v_calendar_stale, false),
    'occurrences', v_occurrences,
    'assignments', v_assignments,
    'brief_generated_at', v_brief->'generated_at'
  );
end;
$$;

revoke all on function public.server_read_today_schedule_from_daily_brief(uuid)
  from public, anon, authenticated;
grant execute on function public.server_read_today_schedule_from_daily_brief(uuid)
  to service_role;

create or replace function public.server_tx_get_today_schedule(
  p_actor_id uuid
) returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select public.server_read_today_schedule_from_daily_brief(p_actor_id);
$$;

revoke all on function public.server_tx_get_today_schedule(uuid)
  from public, anon, authenticated;
grant execute on function public.server_tx_get_today_schedule(uuid) to service_role;

-- Authenticated PWA consumers that need the full shared read model can use a
-- caller-bound wrapper.  The actor is always auth.uid(); body/query parameters
-- can never select the partner or a simulated ActorRef.
create or replace function public.get_my_daily_brief(
  p_local_date date default null
) returns jsonb
language plpgsql
stable
security definer
set search_path = ''
as $$
declare
  v_actor_id uuid := auth.uid();
begin
  if v_actor_id is null then
    raise exception 'AUTH_REQUIRED';
  end if;
  return public.server_read_daily_brief(v_actor_id, p_local_date);
end;
$$;

revoke all on function public.get_my_daily_brief(date) from public, anon;
grant execute on function public.get_my_daily_brief(date) to authenticated;
