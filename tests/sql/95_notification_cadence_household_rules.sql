-- Owner decision 2026-09-29: weekends/holidays get exactly one message (the
-- morning brief); Sunday's carries next week's schedule; public holidays are
-- real (production's jp_holidays was empty, so 9/21-9/23 behaved as workdays).
\set ON_ERROR_STOP on

begin;
insert into auth.users(id) values ('95000000-0000-0000-0000-000000000001');
set role service_role;

do $$
declare
  v_owner uuid := '95000000-0000-0000-0000-000000000001';
  v_hh uuid;
  v_slots jsonb;
  v_kinds text[];
  v_preview text;
  v_notif record;
  v_dispatch jsonb;
begin
  v_hh := (public.server_tx_create_household(v_owner, gen_random_uuid(), 'Cadence HH', 'Owner')->>'household_id')::uuid;

  -- The migration itself must carry the holidays: production never ran the CI seed.
  if not exists (select 1 from private.jp_holidays where local_date = date '2026-09-21')
     or not exists (select 1 from private.jp_holidays where local_date = date '2027-01-01') then
    raise exception 'FAIL cadence: jp_holidays not seeded by the migration';
  end if;

  -- Workday (Tue 2026-09-29) after 20:30: morning + evening.
  v_slots := public.server_read_due_daily_brief_slots(timestamptz '2026-09-29 21:00:00+09');
  select array_agg(distinct e->>'schedule_kind' order by e->>'schedule_kind') into v_kinds
  from jsonb_array_elements(v_slots) e where e->>'household_id' = v_hh::text;
  if v_kinds is distinct from array['evening_brief','weekday_morning_brief'] then
    raise exception 'FAIL cadence: workday slots wrong: %', v_kinds;
  end if;

  -- Saturday, Sunday and a public holiday (Mon 2026-09-21, 敬老の日) after 20:30:
  -- the nonworkday morning brief only.
  foreach v_slots in array array[
    public.server_read_due_daily_brief_slots(timestamptz '2026-10-03 21:00:00+09'),
    public.server_read_due_daily_brief_slots(timestamptz '2026-10-04 21:00:00+09'),
    public.server_read_due_daily_brief_slots(timestamptz '2026-09-21 21:00:00+09')
  ] loop
    select array_agg(distinct e->>'schedule_kind' order by e->>'schedule_kind') into v_kinds
    from jsonb_array_elements(v_slots) e where e->>'household_id' = v_hh::text;
    if v_kinds is distinct from array['nonworkday_morning_brief'] then
      raise exception 'FAIL cadence: nonworkday must send the morning brief only, got %', v_kinds;
    end if;
  end loop;

  -- Weekly preview renders a day with transport for next week.
  insert into public.task_instances(household_id, origin, title, category, routine_phase,
    scheduled_date, calendar_visibility, status, source, created_by, completion_mode, assignment_mode)
  values (v_hh, 'manual', '運動会', 'other', 'anytime', date '2026-10-07', 'special',
    'todo', 'test', v_owner, 'whole', 'unassigned');
  v_preview := private.fn_render_weekly_preview_v1(v_hh, date '2026-10-05');
  if v_preview is null or v_preview not like '%10/7(水)%' or v_preview not like '%運動会%' then
    raise exception 'FAIL cadence: weekly preview missing special event: %', v_preview;
  end if;

  -- Sunday dispatch: one message, and it carries 来週の予定.
  update private.canonical_capability_gates
  set release_stage='P1', reader_enabled=true, writer_enabled=true, mutation_paused=false,
      p1_crossed_at=coalesce(p1_crossed_at, now()), updated_at=now()
  where capability='daily_brief_v2';

  v_dispatch := public.server_tx_dispatch_daily_briefs(timestamptz '2026-10-04 21:00:00+09');
  select * into v_notif from public.user_notifications
  where household_id = v_hh and type = 'daily_brief.v2'
    and payload->>'schedule_kind' = 'nonworkday_morning_brief' limit 1;
  if v_notif.id is null then
    raise exception 'FAIL cadence: Sunday morning brief not dispatched: %', v_dispatch;
  end if;
  if v_notif.body not like '%📅 来週の予定%' or v_notif.body not like '%運動会%' then
    raise exception 'FAIL cadence: Sunday brief lacks next week: %', v_notif.body;
  end if;
  if exists (select 1 from public.user_notifications
    where household_id = v_hh and type = 'daily_brief.v2'
      and payload->>'schedule_kind' = 'evening_brief') then
    raise exception 'FAIL cadence: Sunday evening brief dispatched';
  end if;
  if length(v_notif.body) > 5000 then
    raise exception 'FAIL cadence: brief exceeds LINE 5000-char limit';
  end if;
end $$;

rollback;
select 'notification_cadence_household_rules: PASS' as result;
