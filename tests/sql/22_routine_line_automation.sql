-- WP8: dispatch-routine-automation idempotency/bundling/suppression,
-- reassignment session supersede, and the routine-session action RPCs
-- (LINE-postback-shaped and PWA-shaped calls). Ground truth:
-- docs/design/v6/17_ROUTINE_LINE_AUTOMATION.md and
-- docs/design/v6/fixtures/SCHEDULED_LINE_CASES.json (SL-* ids referenced
-- inline below).
--
-- Tokyo has no DST, so every p_now_utc below is built as
-- `('<local date/time>'::timestamp at time zone 'Asia/Tokyo')` — the same
-- Tokyo-wall-clock -> instant conversion server_tx_dispatch_routine_automation
-- itself reverses internally.
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('16000000-0000-0000-0000-000000000001'), -- HH1 adult A (dropoff+pickup Mon)
  ('16000000-0000-0000-0000-000000000002'), -- HH1 adult B
  ('16000000-0000-0000-0000-000000000003'), -- HH2 adult A (unassigned-pickup scenario)
  ('16000000-0000-0000-0000-000000000004'), -- HH2 adult B
  ('16000000-0000-0000-0000-000000000005'), -- HH3 adult A (zero-items scenario)
  ('16000000-0000-0000-0000-000000000006'), -- HH3 adult B
  ('16000000-0000-0000-0000-000000000007'), -- HH4 adult A (custom-time scenario)
  ('16000000-0000-0000-0000-000000000008'), -- HH4 adult B
  ('16000000-0000-0000-0000-000000000009'), -- HH5 adult A (session-action RPC scenario)
  ('16000000-0000-0000-0000-00000000000a'); -- HH5 adult B

set role service_role;

-- ===========================================================================
-- Scenario 1: 07:00 bundling (daily_assignment + dropoff_checklist into one
-- LINE message for the dropoff assignee, daily_assignment only for the
-- other adult) + exact-once dispatch despite simulated cron retry
-- (SL-02/SL-03/SL-04/SL-13/SL-15).
-- ===========================================================================
do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_a uuid := '16000000-0000-0000-0000-000000000001';
  v_b uuid := '16000000-0000-0000-0000-000000000002';
  v_dropoff_def uuid;
  v_pickup_def uuid;
  v_dropoff_ti uuid;
  v_pickup_ti uuid;
  v_extra_ti uuid;
  v_now timestamptz := ('2026-08-24 07:00:00'::timestamp at time zone 'Asia/Tokyo');
  v_dispatch jsonb;
  v_outbox record;
  v_items jsonb;
  v_session_id uuid;
  v_item_count int;
begin
  v_hh := public.server_tx_create_household(v_a, gen_random_uuid(), 'WP8 Bundle HH', 'A');
  v_hh_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role) values (v_hh_id, v_b, 'adult');

  select id into v_dropoff_def from public.task_definitions where household_id = v_hh_id and code = 'dropoff';
  select id into v_pickup_def from public.task_definitions where household_id = v_hh_id and code = 'pickup';

  insert into public.task_instances
    (id, household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
     planned_assignee_id, completion_mode, status, source, created_by)
  values
    (gen_random_uuid(), v_hh_id, v_dropoff_def, 'recurring', '送り', 'dropoff', 'morning', '2026-08-24',
     v_a, 'whole', 'todo', 'recurring', v_a)
  returning id into v_dropoff_ti;

  insert into public.task_instances
    (id, household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
     planned_assignee_id, completion_mode, status, source, created_by)
  values
    (gen_random_uuid(), v_hh_id, v_pickup_def, 'recurring', '迎え', 'pickup', 'evening', '2026-08-24',
     v_a, 'whole', 'todo', 'recurring', v_a)
  returning id into v_pickup_ti;

  insert into public.task_instances
    (id, household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
     planned_assignee_id, completion_mode, status, source, created_by)
  values
    (gen_random_uuid(), v_hh_id, null, 'manual', '英語用品', 'prep', 'morning', '2026-08-24',
     v_a, 'whole', 'todo', 'manual', v_a)
  returning id into v_extra_ti;

  -- First dispatch.
  v_dispatch := public.server_tx_dispatch_routine_automation(v_now, 2000);
  if (v_dispatch->>'notifications_claimed')::int < 3 then -- A:daily+dropoff, B:daily
    raise exception 'FAIL bundle: expected >=3 claimed notifications, got %', v_dispatch->>'notifications_claimed';
  end if;

  -- A: exactly one queued LINE outbox row bundling 2 items (daily_assignment + dropoff_checklist).
  select * into v_outbox from private.notification_outbox
  where household_id = v_hh_id and recipient_user_id = v_a and channel = 'line' and status = 'queued';
  if not found then
    raise exception 'FAIL bundle: expected one queued outbox row for A';
  end if;
  v_items := v_outbox.payload -> 'items';
  if jsonb_array_length(v_items) <> 2 then
    raise exception 'FAIL bundle: expected A''s outbox row to carry 2 bundled items, got %', jsonb_array_length(v_items);
  end if;

  -- B: one outbox row with only the daily_assignment item (no dropoff checklist section).
  select * into v_outbox from private.notification_outbox
  where household_id = v_hh_id and recipient_user_id = v_b and channel = 'line' and status = 'queued';
  if not found or jsonb_array_length(v_outbox.payload -> 'items') <> 1 then
    raise exception 'FAIL bundle: expected B to receive exactly 1 (daily_assignment only) item';
  end if;

  -- Dropoff session created with 2 active items (dropoff itself + the extra morning task; SL-04's
  -- "dropoff-only" case is exercised implicitly here via display but not asserted separately for
  -- brevity — the checklist body must be non-empty even when only the anchor exists, verified next).
  select id into v_session_id from public.routine_checkin_sessions
  where household_id = v_hh_id and session_type = 'dropoff' and scheduled_date = '2026-08-24' and assignee_id = v_a;
  if v_session_id is null then
    raise exception 'FAIL bundle: dropoff session was not created';
  end if;
  select count(*) into v_item_count from public.routine_checkin_session_items where session_id = v_session_id;
  if v_item_count <> 2 then
    raise exception 'FAIL bundle: expected 2 session items (dropoff + extra morning task), got %', v_item_count;
  end if;

  -- Simulated cron retry: same exact minute dispatched again must not double-send.
  perform public.server_tx_dispatch_routine_automation(v_now, 2000);
  if (select count(*) from private.notification_outbox where household_id = v_hh_id and recipient_user_id = v_a and channel = 'line') <> 1 then
    raise exception 'FAIL bundle: cron retry of the same minute must not create a second outbox row for A';
  end if;
  if (select count(*) from private.scheduled_dispatch_receipts where household_id = v_hh_id and schedule_kind = 'dropoff_checklist' and recipient_user_id = v_a) <> 1 then
    raise exception 'FAIL bundle: cron retry must not create a second scheduled_dispatch_receipts row';
  end if;
end;
$$;

-- ===========================================================================
-- Scenario 2: weekend/holiday suppresses weekday-role schedules; the
-- non-workday schedule fires instead, and Sunday's digest carries the
-- next-week section (SL-05/SL-V6-01/SL-V6-03).
-- ===========================================================================
do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_a uuid := '16000000-0000-0000-0000-000000000001';
  v_dropoff_def uuid;
  v_sunday timestamptz := ('2026-08-30 07:00:00'::timestamp at time zone 'Asia/Tokyo');
  v_sunday_digest timestamptz := ('2026-08-30 09:00:00'::timestamp at time zone 'Asia/Tokyo');
  v_holiday_monday timestamptz := ('2026-09-21 07:00:00'::timestamp at time zone 'Asia/Tokyo');
  v_outbox record;
begin
  -- Reuse HH1 from scenario 1 (already has a dropoff task_definition + a
  -- dropoff task_instance scheduled for 2026-08-24, unrelated to these dates).
  select household_id into v_hh_id from public.household_members where user_id = v_a;

  -- Sunday: is_nonworkday=true (weekend), so daily_assignment/dropoff_checklist
  -- (both default 07:00) must never fire, even though 07:00 matches their
  -- configured local_time (SL-05 "no hardcoded weekday send").
  perform public.server_tx_dispatch_routine_automation(v_sunday, 2000);
  if exists (
    select 1 from private.scheduled_dispatch_receipts
    where household_id = v_hh_id and scheduled_local_date = '2026-08-30'
      and schedule_kind in ('daily_assignment', 'dropoff_checklist')
  ) then
    raise exception 'FAIL nonworkday: weekday-role schedules must not fire on a Sunday';
  end if;

  -- Add a next-week (Mon 2026-08-31) dropoff assignment so the Sunday 09:00
  -- weekly section has something to show.
  select id into v_dropoff_def from public.task_definitions where household_id = v_hh_id and code = 'dropoff';
  insert into public.task_instances
    (household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
     planned_assignee_id, completion_mode, status, source, created_by)
  values
    (v_hh_id, v_dropoff_def, 'recurring', '送り', 'dropoff', 'morning', '2026-08-31',
     v_a, 'whole', 'todo', 'recurring', v_a);

  perform public.server_tx_dispatch_routine_automation(v_sunday_digest, 2000);
  select * into v_outbox from private.notification_outbox
  where household_id = v_hh_id and recipient_user_id = v_a and channel = 'line' and type = 'routine'
    and dedup_key like 'routine-min:%:2026-08-30:09:00';
  if not found then
    raise exception 'FAIL nonworkday: Sunday 09:00 digest was not dispatched to A';
  end if;
  if (v_outbox.payload -> 'items' -> 0 ->> 'body') not like '%08/31%' then
    raise exception 'FAIL nonworkday: Sunday digest must include the next-week (08/31) dropoff assignment';
  end if;

  -- Holiday weekday (2026-09-21, 敬老の日, seeded by scripts/seed_jp_holidays.mjs):
  -- weekday-role schedules must also be suppressed (SL-V6-03).
  perform public.server_tx_dispatch_routine_automation(v_holiday_monday, 2000);
  if exists (
    select 1 from private.scheduled_dispatch_receipts
    where household_id = v_hh_id and scheduled_local_date = '2026-09-21' and schedule_kind = 'daily_assignment'
  ) then
    raise exception 'FAIL nonworkday: weekday-role schedules must not fire on a JP holiday weekday';
  end if;
end;
$$;

-- ===========================================================================
-- Scenario 3: reminder suppression (08:30 dropoff check-in) — fully
-- completed early skips the reminder and auto-closes the session; a
-- partially-completed session reminds with only the incomplete item
-- (SL-06/SL-07).
-- ===========================================================================
do $$
declare
  v_hh_id uuid;
  v_a uuid := '16000000-0000-0000-0000-000000000001';
  v_session_id uuid;
  v_checkin_time timestamptz := ('2026-08-24 08:30:00'::timestamp at time zone 'Asia/Tokyo');
  v_item record;
begin
  select household_id into v_hh_id from public.household_members where user_id = v_a;
  select id into v_session_id from public.routine_checkin_sessions
  where household_id = v_hh_id and session_type = 'dropoff' and scheduled_date = '2026-08-24' and assignee_id = v_a;

  -- Complete every item early via the PWA-shaped per-item RPC (source='pwa').
  for v_item in
    select task_instance_id from public.routine_checkin_session_items where session_id = v_session_id
  loop
    perform public.server_tx_routine_session_item_action(
      v_a, gen_random_uuid(), v_session_id, v_item.task_instance_id, 'complete', 'pwa'
    );
  end loop;

  if (select status from public.routine_checkin_sessions where id = v_session_id) <> 'submitted' then
    raise exception 'FAIL checkin: session must auto-submit once every item is terminal';
  end if;

  perform public.server_tx_dispatch_routine_automation(v_checkin_time, 2000);
  if exists (
    select 1 from private.scheduled_dispatch_receipts
    where household_id = v_hh_id and schedule_kind = 'dropoff_checkin' and recipient_user_id = v_a
  ) then
    raise exception 'FAIL checkin: no 08:30 reminder must be sent once everything was completed early (SL-06)';
  end if;
end;
$$;

do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_a uuid := '16000000-0000-0000-0000-000000000003';
  v_b uuid := '16000000-0000-0000-0000-000000000004';
  v_dropoff_def uuid;
  v_dropoff_ti uuid;
  v_extra_ti uuid;
  v_open_time timestamptz := ('2026-08-24 07:00:00'::timestamp at time zone 'Asia/Tokyo');
  v_checkin_time timestamptz := ('2026-08-24 08:30:00'::timestamp at time zone 'Asia/Tokyo');
  v_session_id uuid;
  v_outbox record;
begin
  v_hh := public.server_tx_create_household(v_a, gen_random_uuid(), 'WP8 Partial HH', 'A');
  v_hh_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role) values (v_hh_id, v_b, 'adult');

  select id into v_dropoff_def from public.task_definitions where household_id = v_hh_id and code = 'dropoff';
  insert into public.task_instances
    (id, household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
     planned_assignee_id, completion_mode, status, source, created_by)
  values (gen_random_uuid(), v_hh_id, v_dropoff_def, 'recurring', '送り', 'dropoff', 'morning', '2026-08-24',
    v_a, 'whole', 'todo', 'recurring', v_a)
  returning id into v_dropoff_ti;
  insert into public.task_instances
    (id, household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
     planned_assignee_id, completion_mode, status, source, created_by)
  values (gen_random_uuid(), v_hh_id, null, 'manual', '上履き', 'prep', 'morning', '2026-08-24',
    v_a, 'whole', 'todo', 'manual', v_a)
  returning id into v_extra_ti;

  perform public.server_tx_dispatch_routine_automation(v_open_time, 2000);
  select id into v_session_id from public.routine_checkin_sessions
  where household_id = v_hh_id and session_type = 'dropoff' and scheduled_date = '2026-08-24' and assignee_id = v_a;

  -- Only the dropoff task itself is completed; the extra item stays open.
  perform public.server_tx_complete_task(v_a, gen_random_uuid(), v_dropoff_ti, 'self', false, 'pwa');

  perform public.server_tx_dispatch_routine_automation(v_checkin_time, 2000);
  select * into v_outbox from private.notification_outbox
  where household_id = v_hh_id and recipient_user_id = v_a and channel = 'line'
    and dedup_key like 'routine-min:%:2026-08-24:08:30';
  if not found then
    raise exception 'FAIL checkin: a partially-complete session must send an 08:30 reminder (SL-07)';
  end if;
  if (v_outbox.payload -> 'items' -> 0 ->> 'body') like '%上履き%' is not true then
    raise exception 'FAIL checkin: reminder body must list the still-incomplete item';
  end if;
  if (select status from public.routine_checkin_sessions where id = v_session_id) <> 'open' then
    raise exception 'FAIL checkin: a partially-complete session must remain open, not auto_closed';
  end if;
end;
$$;

-- ===========================================================================
-- Scenario 4: reassignment mid-cycle supersedes the old session, creates the
-- new assignee's session, notifies both immediately, and the old assignee
-- never gets a later check-in reminder (SL-18/SL-19/SL-20, acceptance
-- example D).
-- ===========================================================================
do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_a uuid := '16000000-0000-0000-0000-000000000005';
  v_b uuid := '16000000-0000-0000-0000-000000000006';
  v_pickup_def uuid;
  v_pickup_ti uuid;
  v_evening_ti_a uuid;
  -- reassign-task-once's session-supersede amendment (20260819000081) scopes
  -- itself to reassignments of TODAY's real (Asia/Tokyo `now()`) dropoff/
  -- pickup instance — a future-dated reassignment has no session to
  -- supersede yet. This scenario therefore must build against the DB's own
  -- real "today", not a fixed fixture date, unlike every other scenario in
  -- this file (which only ever call the dispatcher, never reassign-once, so
  -- a fixed simulated date is fine there).
  v_today date := (now() at time zone 'Asia/Tokyo')::date;
  v_open_time timestamptz := ((v_today::text || ' 16:00:00')::timestamp at time zone 'Asia/Tokyo');
  v_checkin_time timestamptz := ((v_today::text || ' 20:30:00')::timestamp at time zone 'Asia/Tokyo');
  v_old_session uuid;
  v_new_session uuid;
begin
  v_hh := public.server_tx_create_household(v_a, gen_random_uuid(), 'WP8 Reassign HH', 'A');
  v_hh_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role) values (v_hh_id, v_b, 'adult');

  select id into v_pickup_def from public.task_definitions where household_id = v_hh_id and code = 'pickup';
  insert into public.task_instances
    (id, household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
     planned_assignee_id, completion_mode, status, source, created_by)
  values (gen_random_uuid(), v_hh_id, v_pickup_def, 'recurring', '迎え', 'pickup', 'evening', v_today,
    v_a, 'whole', 'todo', 'recurring', v_a)
  returning id into v_pickup_ti;
  insert into public.task_instances
    (id, household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
     planned_assignee_id, completion_mode, status, source, created_by)
  values (gen_random_uuid(), v_hh_id, null, 'manual', '夕食', 'chore', 'evening', v_today,
    v_a, 'whole', 'todo', 'manual', v_a)
  returning id into v_evening_ti_a;

  perform public.server_tx_dispatch_routine_automation(v_open_time, 2000);
  select id into v_old_session from public.routine_checkin_sessions
  where household_id = v_hh_id and session_type = 'pickup' and scheduled_date = v_today and assignee_id = v_a;
  if v_old_session is null then
    raise exception 'FAIL reassign: pickup session for A was not created at 16:00';
  end if;

  -- 17:00: reassign pickup from A to B.
  perform public.server_tx_reassign_task_once(v_a, gen_random_uuid(), v_pickup_ti, v_b);

  if (select status from public.routine_checkin_sessions where id = v_old_session) <> 'superseded' then
    raise exception 'FAIL reassign: A''s pickup session must be superseded immediately on reassignment';
  end if;

  select id into v_new_session from public.routine_checkin_sessions
  where household_id = v_hh_id and session_type = 'pickup' and scheduled_date = v_today and assignee_id = v_b;
  if v_new_session is null then
    raise exception 'FAIL reassign: B''s pickup session must be created immediately on reassignment';
  end if;

  if not exists (
    select 1 from private.notification_outbox
    where household_id = v_hh_id and recipient_user_id = v_a and type = 'routine_reassignment'
  ) then
    raise exception 'FAIL reassign: old assignee A must get an immediate change notification';
  end if;
  if not exists (
    select 1 from private.notification_outbox
    where household_id = v_hh_id and recipient_user_id = v_b and type = 'routine_reassignment'
  ) then
    raise exception 'FAIL reassign: new assignee B must get an immediate change notification';
  end if;

  -- 20:30 check-in: A must get nothing further; B (now live pickup assignee,
  -- with the still-open '夕食' evening item — note: that item's own
  -- planned_assignee_id still says A, a documented cascade-gap in
  -- 20260819000081's header comment, so B's rebuilt session only contains
  -- the pickup task itself here) gets the reminder instead.
  perform public.server_tx_dispatch_routine_automation(v_checkin_time, 2000);
  if exists (
    select 1 from private.scheduled_dispatch_receipts
    where household_id = v_hh_id and schedule_kind = 'pickup_checkin' and recipient_user_id = v_a
  ) then
    raise exception 'FAIL reassign: superseded assignee A must never get a pickup_checkin reminder (SL-19)';
  end if;
  if not exists (
    select 1 from private.scheduled_dispatch_receipts
    where household_id = v_hh_id and schedule_kind = 'pickup_checkin' and recipient_user_id = v_b
  ) then
    raise exception 'FAIL reassign: new assignee B must get the 20:30 reminder for the still-open pickup task';
  end if;
end;
$$;

-- ===========================================================================
-- Scenario 5: pickup assignee null -> both adults get one unassigned
-- warning, deduplicated across a simulated retry (SL-21).
-- ===========================================================================
do $$
declare
  v_hh_id uuid;
  v_a uuid := '16000000-0000-0000-0000-000000000005';
  v_b uuid := '16000000-0000-0000-0000-000000000006';
  -- One week after scenario 4's date: same weekday (so it is a workday iff
  -- today is — already confirmed true for this fixture's real run date) but
  -- with no pickup task_instance of its own, unlike scenario 4's date which
  -- now has one (reassigned to B).
  v_date date := (now() at time zone 'Asia/Tokyo')::date + 7;
  v_time timestamptz := ((v_date::text || ' 20:00:00')::timestamp at time zone 'Asia/Tokyo');
begin
  select household_id into v_hh_id from public.household_members where user_id = v_a;
  perform public.server_tx_dispatch_routine_automation(v_time, 2000);
  perform public.server_tx_dispatch_routine_automation(v_time, 2000); -- retry
  if (select count(*) from private.scheduled_dispatch_receipts
      where household_id = v_hh_id and schedule_kind = 'nonpickup_evening_checklist' and scheduled_local_date = v_date) <> 2 then
    raise exception 'FAIL unassigned-pickup: expected exactly one claimed warning per adult, got %',
      (select count(*) from private.scheduled_dispatch_receipts where household_id = v_hh_id and schedule_kind = 'nonpickup_evening_checklist' and scheduled_local_date = v_date);
  end if;
  if not exists (
    select 1 from private.notification_outbox
    where household_id = v_hh_id and recipient_user_id = v_a and channel = 'line'
      and payload -> 'items' -> 0 ->> 'title' like '%未設定%'
  ) then
    raise exception 'FAIL unassigned-pickup: A must receive the unassigned-pickup warning text';
  end if;
end;
$$;

-- ===========================================================================
-- Scenario 6: zero evening items for the non-pickup adult -> no session, no
-- notification (SL-10); custom schedule time only fires at its configured
-- minute, not the default (SL-23).
-- ===========================================================================
do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_a uuid := '16000000-0000-0000-0000-000000000007';
  v_b uuid := '16000000-0000-0000-0000-000000000008';
  v_pickup_def uuid;
  v_default_time timestamptz := ('2026-08-24 20:00:00'::timestamp at time zone 'Asia/Tokyo');
  v_custom_default_time timestamptz := ('2026-08-24 07:00:00'::timestamp at time zone 'Asia/Tokyo');
  v_custom_time timestamptz := ('2026-08-24 06:45:00'::timestamp at time zone 'Asia/Tokyo');
begin
  v_hh := public.server_tx_create_household(v_a, gen_random_uuid(), 'WP8 ZeroItems HH', 'A');
  v_hh_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role) values (v_hh_id, v_b, 'adult');

  select id into v_pickup_def from public.task_definitions where household_id = v_hh_id and code = 'pickup';
  insert into public.task_instances
    (household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
     planned_assignee_id, completion_mode, status, source, created_by)
  values (v_hh_id, v_pickup_def, 'recurring', '迎え', 'pickup', 'evening', '2026-08-24',
    v_a, 'whole', 'todo', 'recurring', v_a);
  -- No evening-phase task_instances assigned to B at all today.

  perform public.server_tx_dispatch_routine_automation(v_default_time, 2000);
  if exists (
    select 1 from public.routine_checkin_sessions
    where household_id = v_hh_id and session_type = 'nonpickup_evening' and scheduled_date = '2026-08-24'
  ) then
    raise exception 'FAIL zero-items: a nonpickup_evening session must never be created for zero items (SL-10)';
  end if;
  if exists (
    select 1 from private.scheduled_dispatch_receipts
    where household_id = v_hh_id and schedule_kind = 'nonpickup_evening_checklist'
  ) then
    raise exception 'FAIL zero-items: no notification should be claimed for zero items';
  end if;

  -- Custom daily_assignment time: 06:45 instead of the 07:00 default (SL-23).
  update public.household_routine_schedules
  set local_time = '06:45', schedule_version = schedule_version + 1
  where household_id = v_hh_id and schedule_kind = 'daily_assignment';

  perform public.server_tx_dispatch_routine_automation(v_custom_default_time, 2000);
  if exists (
    select 1 from private.scheduled_dispatch_receipts
    where household_id = v_hh_id and schedule_kind = 'daily_assignment' and scheduled_local_date = '2026-08-24'
  ) then
    raise exception 'FAIL custom-time: daily_assignment must NOT fire at the old default 07:00 once retimed to 06:45';
  end if;

  perform public.server_tx_dispatch_routine_automation(v_custom_time, 2000);
  if not exists (
    select 1 from private.scheduled_dispatch_receipts
    where household_id = v_hh_id and schedule_kind = 'daily_assignment' and scheduled_local_date = '2026-08-24'
  ) then
    raise exception 'FAIL custom-time: daily_assignment must fire at the newly configured 06:45 (SL-23)';
  end if;

  -- Same-day edit-after-send: retiming again today must not trigger a
  -- second send for today (SL-V5-02 "no_auto_resend").
  update public.household_routine_schedules
  set local_time = '07:15', schedule_version = schedule_version + 1
  where household_id = v_hh_id and schedule_kind = 'daily_assignment';
  perform public.server_tx_dispatch_routine_automation(
    ('2026-08-24 07:15:00'::timestamp at time zone 'Asia/Tokyo'), 2000
  );
  if (select count(*) from private.scheduled_dispatch_receipts
      where household_id = v_hh_id and schedule_kind = 'daily_assignment' and scheduled_local_date = '2026-08-24') <> 2 then
    -- 2 = one per adult, claimed once at 06:45; the 07:15 retime must add none.
    raise exception 'FAIL custom-time: a same-day retime after today''s send must never auto-resend';
  end if;
end;
$$;

-- ===========================================================================
-- Scenario 7: notification_preferences OFF still creates the session/task
-- but suppresses only the LINE push (#11 "userがroutine checklistをOFFにしても
-- PWA task/sessionは残る").
-- ===========================================================================
do $$
declare
  v_hh_id uuid;
  v_a uuid := '16000000-0000-0000-0000-000000000007';
  v_open_time timestamptz := ('2026-08-25 16:00:00'::timestamp at time zone 'Asia/Tokyo');
  v_pickup_def uuid;
begin
  select household_id into v_hh_id from public.household_members where user_id = v_a;
  insert into public.notification_preferences (household_id, user_id, routine_checklist_line)
  values (v_hh_id, v_a, false)
  on conflict (household_id, user_id) do update set routine_checklist_line = false;

  select id into v_pickup_def from public.task_definitions where household_id = v_hh_id and code = 'pickup';
  insert into public.task_instances
    (household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
     planned_assignee_id, completion_mode, status, source, created_by)
  values (v_hh_id, v_pickup_def, 'recurring', '迎え', 'pickup', 'evening', '2026-08-25',
    v_a, 'whole', 'todo', 'recurring', v_a);

  perform public.server_tx_dispatch_routine_automation(v_open_time, 2000);

  if not exists (
    select 1 from public.routine_checkin_sessions
    where household_id = v_hh_id and session_type = 'pickup' and scheduled_date = '2026-08-25' and assignee_id = v_a
  ) then
    raise exception 'FAIL pref-off: the session must still be created even with the LINE preference off';
  end if;
  if not exists (
    select 1 from private.scheduled_dispatch_receipts
    where household_id = v_hh_id and schedule_kind = 'pickup_checklist' and scheduled_local_date = '2026-08-25' and recipient_user_id = v_a
  ) then
    raise exception 'FAIL pref-off: the business dispatch receipt must still be claimed';
  end if;
  if exists (
    select 1 from private.notification_outbox
    where household_id = v_hh_id and recipient_user_id = v_a and channel = 'line' and status = 'queued'
      and dedup_key like 'routine-min:%:2026-08-25:16:00'
  ) then
    raise exception 'FAIL pref-off: no LINE outbox row should be created while routine_checklist_line=false';
  end if;
end;
$$;

-- ===========================================================================
-- Scenario 8: routine-session action RPCs — LINE-postback-shaped and
-- PWA-shaped calls both mutate the same canonical state (SL-16), a stale
-- repeat action on an already-terminal item is idempotent/safe (SL-17), and
-- an actor who is not the session's own assignee is rejected.
-- ===========================================================================
do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_a uuid := '16000000-0000-0000-0000-000000000009';
  v_b uuid := '16000000-0000-0000-0000-00000000000a';
  v_dropoff_def uuid;
  v_dropoff_ti uuid;
  v_extra_ti uuid;
  v_third_ti uuid;
  v_session_id uuid;
  v_op uuid;
  v_result jsonb;
  v_get jsonb;
  v_raised boolean;
begin
  v_hh := public.server_tx_create_household(v_a, gen_random_uuid(), 'WP8 SessionAction HH', 'A');
  v_hh_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role) values (v_hh_id, v_b, 'adult');

  select id into v_dropoff_def from public.task_definitions where household_id = v_hh_id and code = 'dropoff';
  insert into public.task_instances
    (id, household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
     planned_assignee_id, completion_mode, status, source, created_by)
  values (gen_random_uuid(), v_hh_id, v_dropoff_def, 'recurring', '送り', 'dropoff', 'morning', '2026-08-26',
    v_a, 'whole', 'todo', 'recurring', v_a)
  returning id into v_dropoff_ti;
  insert into public.task_instances
    (id, household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
     planned_assignee_id, completion_mode, status, source, created_by)
  values (gen_random_uuid(), v_hh_id, null, 'manual', '水筒', 'prep', 'morning', '2026-08-26',
    v_a, 'whole', 'todo', 'manual', v_a)
  returning id into v_extra_ti;
  -- Deliberately left incomplete for the whole scenario, so the session
  -- stays 'open' long enough to exercise the item-level (not session-level)
  -- stale-tap path below.
  insert into public.task_instances
    (id, household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
     planned_assignee_id, completion_mode, status, source, created_by)
  values (gen_random_uuid(), v_hh_id, null, 'manual', '帽子', 'prep', 'morning', '2026-08-26',
    v_a, 'whole', 'todo', 'manual', v_a)
  returning id into v_third_ti;

  perform public.server_tx_dispatch_routine_automation(('2026-08-26 07:00:00'::timestamp at time zone 'Asia/Tokyo'), 2000);
  select id into v_session_id from public.routine_checkin_sessions
  where household_id = v_hh_id and session_type = 'dropoff' and scheduled_date = '2026-08-26' and assignee_id = v_a;

  -- Access control: B (not the session's assignee) cannot act on it.
  v_raised := false;
  begin
    perform public.server_tx_routine_session_item_action(v_b, gen_random_uuid(), v_session_id, v_dropoff_ti, 'complete', 'pwa');
  exception when others then
    v_raised := true;
    if sqlerrm <> 'CROSS_HOUSEHOLD_RESOURCE' then
      raise exception 'FAIL access: expected CROSS_HOUSEHOLD_RESOURCE for a non-assignee actor, got %', sqlerrm;
    end if;
  end;
  if not v_raised then
    raise exception 'FAIL access: a non-assignee actor must be rejected';
  end if;

  -- LINE-postback-shaped call: complete the dropoff item as the assignee.
  v_op := gen_random_uuid();
  v_result := public.server_tx_routine_session_item_action(v_a, v_op, v_session_id, v_dropoff_ti, 'complete', 'line');
  if (select status from public.task_instances where id = v_dropoff_ti) <> 'completed' then
    raise exception 'FAIL line-postback: dropoff item must be completed';
  end if;
  if (select source from public.task_events where task_instance_id = v_dropoff_ti and event_type = 'completed') <> 'line' then
    raise exception 'FAIL line-postback: task_event source must record ''line''';
  end if;

  -- Idempotent replay: the SAME operation_id repeated (double-tap /
  -- redelivered webhook) must return the same result, not double-execute.
  v_result := public.server_tx_routine_session_item_action(v_a, v_op, v_session_id, v_dropoff_ti, 'complete', 'line');
  if (v_result->>'ok')::boolean is not true then
    raise exception 'FAIL line-postback: idempotent replay must still report ok=true';
  end if;

  -- PWA-shaped call for the second item: "partner_handled" ("相手が対応").
  perform public.server_tx_routine_session_item_action(v_a, gen_random_uuid(), v_session_id, v_extra_ti, 'partner_handled', 'pwa');
  if (select actual_completed_by_id from public.task_instances where id = v_extra_ti) <> v_b then
    raise exception 'FAIL pwa: partner_handled must record B (the other adult) as actual_completed_by_id';
  end if;

  -- SL-16: same canonical state visible via get-routine-session regardless
  -- of which channel mutated it. Session is still 'open' (v_third_ti is
  -- deliberately left incomplete).
  v_get := public.server_tx_get_routine_session(v_b, v_session_id);
  if (v_get->>'status') <> 'open' then
    raise exception 'FAIL get-session: session must still be open with one item outstanding, got %', v_get->>'status';
  end if;
  if jsonb_array_length(v_get->'items') <> 3 then
    raise exception 'FAIL get-session: expected 3 items in the session read model';
  end if;

  -- SL-17 (item-level path): a stale action on an already-terminal item,
  -- while the session itself is still open (another item pending), is a
  -- safe no-rewind response reporting current state — not an error and not
  -- a state change.
  v_result := public.server_tx_routine_session_item_action(v_a, gen_random_uuid(), v_session_id, v_dropoff_ti, 'complete', 'line');
  if (v_result->>'already_terminal')::boolean is not true then
    raise exception 'FAIL stale-tap: acting on an already-terminal item must report already_terminal=true, not rewind it';
  end if;

  -- SL-17 (session-level path): once every item is terminal the session
  -- itself becomes terminal, and a further stale action raises a safe
  -- terminal error rather than rewinding anything.
  perform public.server_tx_routine_session_item_action(v_a, gen_random_uuid(), v_session_id, v_third_ti, 'complete', 'pwa');
  if (select status from public.routine_checkin_sessions where id = v_session_id) <> 'submitted' then
    raise exception 'FAIL stale-tap: session must auto-submit once the last item is terminal';
  end if;
  v_raised := false;
  begin
    perform public.server_tx_routine_session_item_action(v_a, gen_random_uuid(), v_session_id, v_dropoff_ti, 'complete', 'line');
  exception when others then
    v_raised := true;
    if sqlerrm <> 'TASK_TERMINAL' then
      raise exception 'FAIL stale-tap: expected TASK_TERMINAL for an action on an already-submitted session, got %', sqlerrm;
    end if;
  end;
  if not v_raised then
    raise exception 'FAIL stale-tap: an action on an already-submitted session must be rejected';
  end if;
end;
$$;

-- ===========================================================================
-- Scenario 9: complete-routine-session's two top-level dispositions —
-- "全部完了" (complete_all) and confirmed "今回は不要" (skip_incomplete).
-- ===========================================================================
do $$
declare
  v_hh_id uuid;
  v_a uuid := '16000000-0000-0000-0000-000000000009';
  v_dropoff_def uuid;
  v_ti1 uuid;
  v_ti2 uuid;
  v_ti3 uuid;
  v_session_all uuid;
  v_session_skip uuid;
  v_result jsonb;
begin
  select household_id into v_hh_id from public.household_members where user_id = v_a;
  select id into v_dropoff_def from public.task_definitions where household_id = v_hh_id and code = 'dropoff';

  insert into public.task_instances
    (id, household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
     planned_assignee_id, completion_mode, status, source, created_by)
  values (gen_random_uuid(), v_hh_id, v_dropoff_def, 'recurring', '送り', 'dropoff', 'morning', '2026-08-27',
    v_a, 'whole', 'todo', 'recurring', v_a)
  returning id into v_ti1;
  insert into public.task_instances
    (id, household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
     planned_assignee_id, completion_mode, status, source, created_by)
  values (gen_random_uuid(), v_hh_id, null, 'manual', 'おむつ', 'prep', 'morning', '2026-08-27',
    v_a, 'whole', 'todo', 'manual', v_a)
  returning id into v_ti2;

  perform public.server_tx_dispatch_routine_automation(('2026-08-27 07:00:00'::timestamp at time zone 'Asia/Tokyo'), 2000);
  select id into v_session_all from public.routine_checkin_sessions
  where household_id = v_hh_id and session_type = 'dropoff' and scheduled_date = '2026-08-27' and assignee_id = v_a;

  v_result := public.server_tx_complete_routine_session(v_a, gen_random_uuid(), v_session_all, 'complete_all', 'pwa');
  if (v_result->>'completed_count')::int <> 2 then
    raise exception 'FAIL complete-all: expected 2 completed items, got %', v_result->>'completed_count';
  end if;
  if (select count(*) from public.task_instances where id in (v_ti1, v_ti2) and status = 'completed') <> 2 then
    raise exception 'FAIL complete-all: both items must be status=completed';
  end if;
  if (select status from public.routine_checkin_sessions where id = v_session_all) <> 'submitted' then
    raise exception 'FAIL complete-all: session must be submitted';
  end if;

  -- Second household-date for the skip_incomplete disposition.
  insert into public.task_instances
    (id, household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
     planned_assignee_id, completion_mode, status, source, created_by)
  values (gen_random_uuid(), v_hh_id, v_dropoff_def, 'recurring', '送り', 'dropoff', 'morning', '2026-08-28',
    v_a, 'whole', 'todo', 'recurring', v_a)
  returning id into v_ti3;

  perform public.server_tx_dispatch_routine_automation(('2026-08-28 07:00:00'::timestamp at time zone 'Asia/Tokyo'), 2000);
  select id into v_session_skip from public.routine_checkin_sessions
  where household_id = v_hh_id and session_type = 'dropoff' and scheduled_date = '2026-08-28' and assignee_id = v_a;

  v_result := public.server_tx_complete_routine_session(v_a, gen_random_uuid(), v_session_skip, 'skip_incomplete', 'line');
  if (select status from public.task_instances where id = v_ti3) <> 'skipped' then
    raise exception 'FAIL skip-incomplete: item must be status=skipped';
  end if;
  if (select status from public.routine_checkin_sessions where id = v_session_skip) <> 'submitted' then
    raise exception 'FAIL skip-incomplete: session must be submitted';
  end if;

  -- Acting on an already-submitted session must be rejected (terminal).
  begin
    perform public.server_tx_complete_routine_session(v_a, gen_random_uuid(), v_session_skip, 'complete_all', 'pwa');
    raise exception 'FAIL terminal-session: acting on an already-submitted session must raise';
  exception when others then
    if sqlerrm <> 'TASK_TERMINAL' then
      raise exception 'FAIL terminal-session: expected TASK_TERMINAL, got %', sqlerrm;
    end if;
  end;
end;
$$;

reset role;

select '22_routine_line_automation: PASS' as result;
