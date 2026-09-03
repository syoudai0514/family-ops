-- WP-DD6: side-effect-free DailyBrief cadence resolution.
--
-- This migration does not enqueue or send anything. It makes the accepted
-- 06:30 weekday / 09:00 weekend-holiday / 20:30 evening cadence and one-day
-- override semantics executable so the later dispatcher can consume one
-- deterministic source instead of reimplementing calendar rules in Edge code.

create or replace function private.resolve_daily_brief_schedule(
  p_household_id uuid,
  p_local_date date,
  p_schedule_kind text
) returns table(
  enabled boolean,
  local_time time,
  source text
)
language sql
stable
security invoker
set search_path = ''
as $$
  with base as (
    select hrs.enabled, hrs.local_time
    from public.household_routine_schedules hrs
    where hrs.household_id = p_household_id
      and hrs.schedule_kind = p_schedule_kind
      and p_schedule_kind in (
        'daily_brief_weekday_morning',
        'daily_brief_nonworkday_morning',
        'daily_brief_evening'
      )
  ), override_row as (
    select dbo.enabled, dbo.local_time
    from public.daily_brief_schedule_overrides dbo
    where dbo.household_id = p_household_id
      and dbo.local_date = p_local_date
      and dbo.schedule_kind = p_schedule_kind
  )
  select
    coalesce(o.enabled, b.enabled) as enabled,
    case
      when o.enabled is false then null::time
      when o.enabled is true then o.local_time
      else b.local_time
    end as local_time,
    case when o.enabled is not null then 'date_override' else 'base_schedule' end as source
  from base b
  left join override_row o on true;
$$;

revoke all on function private.resolve_daily_brief_schedule(uuid, date, text)
  from public, anon, authenticated;
grant execute on function private.resolve_daily_brief_schedule(uuid, date, text)
  to service_role;

create or replace function private.is_jp_nonworkday(
  p_local_date date
) returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select extract(isodow from p_local_date)::int in (6, 7)
    or exists (
      select 1
      from private.jp_holidays h
      where h.local_date = p_local_date
    );
$$;

revoke all on function private.is_jp_nonworkday(date)
  from public, anon, authenticated;
grant execute on function private.is_jp_nonworkday(date) to service_role;

create or replace function public.server_read_due_daily_brief_slots(
  p_now timestamptz default now()
) returns jsonb
language plpgsql
stable
security invoker
set search_path = ''
as $$
declare
  v_local_date date := (p_now at time zone 'Asia/Tokyo')::date;
  v_nonworkday boolean := private.is_jp_nonworkday((p_now at time zone 'Asia/Tokyo')::date);
  v_result jsonb;
begin
  with candidate_schedules as (
    select
      h.id as household_id,
      k.schedule_kind,
      resolved.enabled,
      resolved.local_time,
      resolved.source
    from public.households h
    cross join lateral (
      values
        ('daily_brief_weekday_morning'::text),
        ('daily_brief_nonworkday_morning'::text),
        ('daily_brief_evening'::text)
    ) k(schedule_kind)
    cross join lateral private.resolve_daily_brief_schedule(
      h.id,
      v_local_date,
      k.schedule_kind
    ) resolved
    where (
      k.schedule_kind = 'daily_brief_evening'
      or (not v_nonworkday and k.schedule_kind = 'daily_brief_weekday_morning')
      or (v_nonworkday and k.schedule_kind = 'daily_brief_nonworkday_morning')
    )
      and resolved.enabled
      and resolved.local_time is not null
  ), due as (
    select
      cs.*,
      hm.user_id as recipient_user_id,
      (
        (v_local_date + cs.local_time)::timestamp at time zone 'Asia/Tokyo'
      ) as scheduled_at,
      v_local_date::text || ':' || cs.schedule_kind || ':' || hm.user_id::text as dispatch_slot_key
    from candidate_schedules cs
    join public.household_members hm
      on hm.household_id = cs.household_id
    where (
      (v_local_date + cs.local_time)::timestamp at time zone 'Asia/Tokyo'
    ) <= p_now
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'household_id', d.household_id,
    'recipient_user_id', d.recipient_user_id,
    'schedule_kind', d.schedule_kind,
    'local_date', v_local_date,
    'local_time', d.local_time,
    'scheduled_at', d.scheduled_at,
    'schedule_source', d.source,
    'dispatch_slot_key', d.dispatch_slot_key
  ) order by d.scheduled_at, d.household_id, d.recipient_user_id), '[]'::jsonb)
  into v_result
  from due d
  where not exists (
    select 1
    from private.scheduled_dispatch_receipts sdr
    where sdr.household_id = d.household_id
      and sdr.schedule_kind = d.schedule_kind
      and sdr.scheduled_local_date = v_local_date
      and sdr.recipient_user_id = d.recipient_user_id
  );

  return v_result;
end;
$$;

revoke all on function public.server_read_due_daily_brief_slots(timestamptz)
  from public, anon, authenticated;
grant execute on function public.server_read_due_daily_brief_slots(timestamptz)
  to service_role;

-- Cutover audit helper only. It intentionally does not disable legacy rows.
-- A phase-4 activation transaction can require this inventory to be empty
-- after it atomically disables the old nine-kind normal-day push schedules.
create or replace function public.server_read_enabled_legacy_routine_schedules()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(jsonb_agg(jsonb_build_object(
    'household_id', hrs.household_id,
    'schedule_kind', hrs.schedule_kind,
    'local_time', hrs.local_time,
    'schedule_version', hrs.schedule_version
  ) order by hrs.household_id, hrs.schedule_kind), '[]'::jsonb)
  from public.household_routine_schedules hrs
  where hrs.enabled
    and hrs.schedule_kind in (
      'daily_assignment',
      'dropoff_checklist', 'dropoff_checkin',
      'pickup_checklist', 'pickup_checkin',
      'nonpickup_evening_checklist', 'nonpickup_evening_checkin',
      'nonworkday_morning_digest', 'nonworkday_checkin'
    );
$$;

revoke all on function public.server_read_enabled_legacy_routine_schedules()
  from public, anon, authenticated;
grant execute on function public.server_read_enabled_legacy_routine_schedules()
  to service_role;
