-- WP8 P1 follow-up (Sol design review): Google Calendar merge + due
-- highlights in the routine digest, and the assignment-conflict warning.
-- Exercises 20260819000091_dispatch_routine_automation_calendar_conflict.sql
-- against docs/design/v6/17_ROUTINE_LINE_AUTOMATION.md #3/#4/#7A and
-- 07_GOOGLE_CALENDAR.md #10/#13. See docs/adr/0008 for the design-detail
-- decisions this test file assumes.
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('24000000-0000-0000-0000-000000000001'), -- HH1 adult A (weekly digest scenario)
  ('24000000-0000-0000-0000-000000000002'), -- HH1 adult B
  ('24000000-0000-0000-0000-000000000003'), -- HH2 adult A (conflict scenario)
  ('24000000-0000-0000-0000-000000000004'), -- HH2 adult B
  ('24000000-0000-0000-0000-000000000005'), -- HH3 adult A (cross-household leak check)
  ('24000000-0000-0000-0000-000000000006'); -- HH3 adult B

set role service_role;

-- ===========================================================================
-- Scenario 1: Sunday 09:00 weekly section merges all five #3 sources —
-- projected Calendar occurrence, a multi-day event appearing on each
-- relevant day, a due request highlight, and a special-prep task — while a
-- linked request's own generated task_instance does not double up with the
-- request highlight.
-- ===========================================================================
do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_a uuid := '24000000-0000-0000-0000-000000000001';
  v_b uuid := '24000000-0000-0000-0000-000000000002';
  v_google_conn_id uuid;
  v_cal_conn_id uuid;
  v_dropoff_def uuid;
  v_prep_def uuid;
  v_linked_ti uuid;
  v_sunday_digest timestamptz := ('2026-08-23 09:00:00'::timestamp at time zone 'Asia/Tokyo');
  v_outbox record;
  v_body text;
  v_kyanpu_count int;
begin
  v_hh := public.server_tx_create_household(v_a, gen_random_uuid(), 'WP8 Digest HH', 'A');
  v_hh_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role) values (v_hh_id, v_b, 'adult');

  insert into private.google_connections
    (id, household_id, owner_user_id, google_subject, encrypted_refresh_token, encryption_version, scopes, status)
  values
    (gen_random_uuid(), v_hh_id, v_a, 'google-subj-24-hh1', 'cipher', 1,
     array['https://www.googleapis.com/auth/calendar.events'], 'active')
  returning id into v_google_conn_id;

  insert into public.calendar_connections
    (id, household_id, provider, external_calendar_id, google_connection_id, active, last_incremental_sync_at, reauth_required)
  values
    (gen_random_uuid(), v_hh_id, 'google', 'family-hh1@group.calendar.google.com', v_google_conn_id, true, now(), false)
  returning id into v_cal_conn_id;

  -- Single-day timed occurrence on Tue 2026-08-25.
  insert into public.calendar_event_occurrences
    (household_id, calendar_connection_id, occurrence_key, google_event_id, title,
     starts_at, ends_at, status, transparency, projection_window_start, projection_window_end)
  values
    (v_hh_id, v_cal_conn_id, 'event:ev1', 'ev1', '言語',
     ('2026-08-25 15:30:00'::timestamp at time zone 'Asia/Tokyo'),
     ('2026-08-25 16:00:00'::timestamp at time zone 'Asia/Tokyo'),
     'confirmed', null, '2026-01-01', '2027-01-01');

  -- Multi-day timed occurrence spanning Wed 08/26 - Fri 08/28.
  insert into public.calendar_event_occurrences
    (household_id, calendar_connection_id, occurrence_key, google_event_id, title,
     starts_at, ends_at, status, transparency, projection_window_start, projection_window_end)
  values
    (v_hh_id, v_cal_conn_id, 'event:ev2', 'ev2', 'キャンプ',
     ('2026-08-26 10:00:00'::timestamp at time zone 'Asia/Tokyo'),
     ('2026-08-28 10:00:00'::timestamp at time zone 'Asia/Tokyo'),
     'confirmed', null, '2026-01-01', '2027-01-01');

  -- Special-preparation task on Tue 2026-08-25 (source 4, existing FYI
  -- shape). The existing v_prep_titles-style query inner-joins
  -- task_definitions (unchanged from 20260819000082), so the fixture needs
  -- a real (non-dropoff) task_definition, not a task_definition_id-null
  -- ad-hoc task.
  select id into v_dropoff_def from public.task_definitions where household_id = v_hh_id and code = 'dropoff';
  insert into public.task_definitions
    (household_id, code, title, category, routine_phase, completion_mode, sort_order, created_by)
  values
    (v_hh_id, 'english_prep', '英語準備', 'prep', 'morning', 'whole', 90, v_a)
  returning id into v_prep_def;
  insert into public.task_instances
    (household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
     planned_assignee_id, completion_mode, status, source, created_by)
  values
    (v_hh_id, v_prep_def, 'recurring', '英語用品', 'prep', 'morning', '2026-08-25',
     v_a, 'whole', 'todo', 'recurring', v_a);

  -- A pending request due Thu 2026-08-27 (source 5), plus its own linked
  -- task_instance so the no-duplicate-line rule has something real to prove
  -- (the linked task is assigned to B, so B's own-task list would show it —
  -- but the weekly section has no per-adult own-task list at all, so no
  -- suppression is expected here; scenario 3 below covers the daily case
  -- where suppression *does* apply).
  insert into public.task_instances
    (id, household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
     planned_assignee_id, completion_mode, status, source, created_by)
  values
    (gen_random_uuid(), v_hh_id, null, 'request', '書類提出', 'errand', 'anytime', '2026-08-27',
     v_b, 'whole', 'todo', 'request', v_a)
  returning id into v_linked_ti;

  insert into public.requests
    (household_id, requester_id, recipient_id, shared_title, due_at, status, linked_task_instance_id)
  values
    (v_hh_id, v_a, v_b, '書類提出', ('2026-08-27 18:00:00'::timestamp at time zone 'Asia/Tokyo'), 'pending', v_linked_ti);

  perform public.server_tx_dispatch_routine_automation(v_sunday_digest, 2000);

  select * into v_outbox from private.notification_outbox
  where household_id = v_hh_id and recipient_user_id = v_a and channel = 'line' and type = 'routine'
    and dedup_key like 'routine-min:%:2026-08-23:09:00';
  if not found then
    raise exception 'FAIL digest: Sunday 09:00 weekly digest was not dispatched';
  end if;
  v_body := v_outbox.payload -> 'items' -> 0 ->> 'body';

  if v_body not like '%15:30 言語%' then
    raise exception 'FAIL digest: expected the projected Calendar occurrence "15:30 言語", body=%', v_body;
  end if;

  select array_length(regexp_split_to_array(v_body, 'キャンプ'), 1) - 1 into v_kyanpu_count;
  if v_kyanpu_count < 3 then
    raise exception 'FAIL digest: expected the multi-day event to appear on each of its 3 days, found % occurrences', v_kyanpu_count;
  end if;

  if v_body not like '%英語用品%' then
    raise exception 'FAIL digest: expected the special-preparation task line, body=%', v_body;
  end if;

  if v_body not like '%書類提出%' then
    raise exception 'FAIL digest: expected the due request highlight line, body=%', v_body;
  end if;

  -- Pre-existing assertion this migration must not break: Sunday digest
  -- still carries an 08/xx-formatted next-week date stamp.
  if v_body !~ '\d{2}/\d{2}' then
    raise exception 'FAIL digest: expected an MM/DD date stamp in the weekly section, body=%', v_body;
  end if;
end;
$$;

-- ===========================================================================
-- Scenario 2: Calendar unavailable/stale still sends household assignments
-- and preserves the existing stale/reauth warning line; a Calendar-side
-- read failure must never suppress the rest of the digest.
-- ===========================================================================
do $$
declare
  v_hh_id uuid;
  v_a uuid := '24000000-0000-0000-0000-000000000001';
  v_dropoff_def uuid;
  v_sunday_digest timestamptz := ('2026-08-30 09:00:00'::timestamp at time zone 'Asia/Tokyo');
  v_outbox record;
  v_body text;
begin
  select household_id into v_hh_id from public.household_members where user_id = v_a;

  -- Mark the HH1 connection from scenario 1 stale/reauth-required.
  update public.calendar_connections set reauth_required = true where household_id = v_hh_id;

  select id into v_dropoff_def from public.task_definitions where household_id = v_hh_id and code = 'dropoff';
  insert into public.task_instances
    (household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
     planned_assignee_id, completion_mode, status, source, created_by)
  values
    (v_hh_id, v_dropoff_def, 'recurring', '送り', 'dropoff', 'morning', '2026-08-30',
     v_a, 'whole', 'todo', 'recurring', v_a);

  perform public.server_tx_dispatch_routine_automation(v_sunday_digest, 2000);

  select * into v_outbox from private.notification_outbox
  where household_id = v_hh_id and recipient_user_id = v_a and channel = 'line' and type = 'routine'
    and dedup_key like 'routine-min:%:2026-08-30:09:00';
  if not found then
    raise exception 'FAIL stale calendar: digest was not dispatched despite reauth_required';
  end if;
  v_body := v_outbox.payload -> 'items' -> 0 ->> 'body';

  if v_body not like '%送り%' then
    raise exception 'FAIL stale calendar: household task data missing when Calendar is stale, body=%', v_body;
  end if;
  if v_body not like '%Google予定を最新化できていません%' then
    raise exception 'FAIL stale calendar: stale/reauth warning line was dropped, body=%', v_body;
  end if;
end;
$$;

-- ===========================================================================
-- Scenario 3: No-duplicate-line — a request whose linked task_instance is
-- already shown in the recipient's own "today" task list must not also
-- appear as a separate due-highlight line for that same recipient; a
-- calendar occurrence that merely shares a title with a household task is
-- NOT deduplicated (no schema link exists between the two — see ADR 0008
-- decision 4), so both lines are expected to appear independently.
-- ===========================================================================
do $$
declare
  v_hh_id uuid;
  v_a uuid := '24000000-0000-0000-0000-000000000001';
  v_b uuid := '24000000-0000-0000-0000-000000000002';
  v_cal_conn_id uuid;
  v_linked_ti uuid;
  v_checkin timestamptz := ('2026-09-06 09:00:00'::timestamp at time zone 'Asia/Tokyo'); -- Sunday
  v_outbox_a record;
  v_outbox_b record;
  v_body_a text;
  v_body_b text;
  v_title_count int;
begin
  select household_id into v_hh_id from public.household_members where user_id = v_a;
  select id into v_cal_conn_id from public.calendar_connections where household_id = v_hh_id limit 1;
  update public.calendar_connections set reauth_required = false, last_incremental_sync_at = now() where id = v_cal_conn_id;

  -- Request due today (2026-09-06), linked task assigned to A.
  insert into public.task_instances
    (id, household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
     planned_assignee_id, completion_mode, status, source, created_by)
  values
    (gen_random_uuid(), v_hh_id, null, 'request', 'ゴミ出し', 'errand', 'anytime', '2026-09-06',
     v_a, 'whole', 'todo', 'request', v_b)
  returning id into v_linked_ti;

  insert into public.requests
    (household_id, requester_id, recipient_id, shared_title, due_at, status, linked_task_instance_id)
  values
    (v_hh_id, v_b, v_a, 'ゴミ出し', ('2026-09-06 08:00:00'::timestamp at time zone 'Asia/Tokyo'), 'pending', v_linked_ti);

  -- Calendar occurrence sharing the exact same title as an unrelated
  -- household task due today, to prove no fuzzy title-based dedup happens.
  insert into public.calendar_event_occurrences
    (household_id, calendar_connection_id, occurrence_key, google_event_id, title,
     starts_at, ends_at, status, transparency, projection_window_start, projection_window_end)
  values
    (v_hh_id, v_cal_conn_id, 'event:ev-dup', 'ev-dup', 'ゴミ出し',
     ('2026-09-06 07:00:00'::timestamp at time zone 'Asia/Tokyo'),
     ('2026-09-06 07:15:00'::timestamp at time zone 'Asia/Tokyo'),
     'confirmed', null, '2026-01-01', '2027-01-01');

  perform public.server_tx_dispatch_routine_automation(v_checkin, 2000);

  select * into v_outbox_a from private.notification_outbox
  where household_id = v_hh_id and recipient_user_id = v_a and channel = 'line' and type = 'routine'
    and dedup_key like 'routine-min:%:2026-09-06:09:00';
  select * into v_outbox_b from private.notification_outbox
  where household_id = v_hh_id and recipient_user_id = v_b and channel = 'line' and type = 'routine'
    and dedup_key like 'routine-min:%:2026-09-06:09:00';
  v_body_a := v_outbox_a.payload -> 'items' -> 0 ->> 'body';
  v_body_b := v_outbox_b.payload -> 'items' -> 0 ->> 'body';

  -- A: the linked task is A's own task today, so the request highlight must
  -- be suppressed for A — "ゴミ出し" should appear exactly once (the
  -- calendar occurrence line + own-task line would otherwise both fire; the
  -- calendar occurrence is never deduped against the task, only the request
  -- highlight is suppressed against the linked task).
  select array_length(regexp_split_to_array(v_body_a, 'ゴミ出し'), 1) - 1 into v_title_count;
  if v_title_count <> 2 then
    raise exception 'FAIL nodup: expected exactly 2 "ゴミ出し" lines for A (own task + calendar, request highlight suppressed), got % body=%', v_title_count, v_body_a;
  end if;

  -- B: the linked task is NOT B's own task, so B's shared highlight list
  -- must still surface the request (not suppressed) in addition to the
  -- (undeduped) calendar occurrence line.
  select array_length(regexp_split_to_array(v_body_b, 'ゴミ出し'), 1) - 1 into v_title_count;
  if v_title_count <> 2 then
    raise exception 'FAIL nodup: expected exactly 2 "ゴミ出し" lines for B (request highlight + calendar, not B''s own task), got % body=%', v_title_count, v_body_b;
  end if;
end;
$$;

-- ===========================================================================
-- Scenario 4 (P1-2): daily_assignment 07:00 conflict warning — timed event
-- inside the window fires a warning. Per ADR 0008 decision 3, the count is
-- household-wide (matching #3/#4's own single-aggregate-line examples), so
-- BOTH adults' 07:00 messages carry the same warning here — personalization
-- is only over whether each recipient's own conflict_line preference lets
-- the (identically-computed) text through at all, exercised separately in
-- scenario 6.
-- ===========================================================================
do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_a uuid := '24000000-0000-0000-0000-000000000003';
  v_b uuid := '24000000-0000-0000-0000-000000000004';
  v_google_conn_id uuid;
  v_cal_conn_id uuid;
  v_dropoff_def uuid;
  v_dropoff_ti uuid;
  v_now timestamptz := ('2026-08-24 07:00:00'::timestamp at time zone 'Asia/Tokyo'); -- Monday, workday
  v_outbox record;
  v_body text;
  v_row_count int;
begin
  v_hh := public.server_tx_create_household(v_a, gen_random_uuid(), 'WP8 Conflict HH', 'A');
  v_hh_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role) values (v_hh_id, v_b, 'adult');

  insert into private.google_connections
    (id, household_id, owner_user_id, google_subject, encrypted_refresh_token, encryption_version, scopes, status)
  values
    (gen_random_uuid(), v_hh_id, v_a, 'google-subj-24-hh2', 'cipher', 1,
     array['https://www.googleapis.com/auth/calendar.events'], 'active')
  returning id into v_google_conn_id;

  insert into public.calendar_connections
    (id, household_id, provider, external_calendar_id, google_connection_id, active, last_incremental_sync_at, reauth_required)
  values
    (gen_random_uuid(), v_hh_id, 'google', 'family-hh2@group.calendar.google.com', v_google_conn_id, true, now(), false)
  returning id into v_cal_conn_id;

  select id into v_dropoff_def from public.task_definitions where household_id = v_hh_id and code = 'dropoff';
  -- dropoff task: due 07:30 (recurring path, but no recurrence_rule_id set
  -- here -> falls back to the ADR 0008 decision-2 60-minute default).
  insert into public.task_instances
    (id, household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date, due_at,
     planned_assignee_id, completion_mode, status, source, created_by)
  values
    (gen_random_uuid(), v_hh_id, v_dropoff_def, 'recurring', '送り', 'dropoff', 'morning', '2026-08-24',
     ('2026-08-24 07:30:00'::timestamp at time zone 'Asia/Tokyo'),
     v_a, 'whole', 'todo', 'recurring', v_a)
  returning id into v_dropoff_ti;

  -- Timed event at 08:00, i.e. 30 minutes after the 07:30 due_at — inside
  -- the default 60-minute window — busy-mapped to A (the dropoff assignee)
  -- via the normalized classification table, not creator_mapped_user_id.
  insert into public.calendar_event_occurrences
    (household_id, calendar_connection_id, occurrence_key, google_event_id, title,
     starts_at, ends_at, status, transparency, creator_mapped_user_id, projection_window_start, projection_window_end)
  values
    (v_hh_id, v_cal_conn_id, 'event:conflict1', 'conflict1', '歯医者',
     ('2026-08-24 08:00:00'::timestamp at time zone 'Asia/Tokyo'),
     ('2026-08-24 08:30:00'::timestamp at time zone 'Asia/Tokyo'),
     'confirmed', null, v_b, -- creator is B; busy attribution below is A, proving creator is ignored
     '2026-01-01', '2027-01-01');
  insert into public.calendar_occurrence_busy_members (household_id, calendar_connection_id, occurrence_key, user_id, source)
  values (v_hh_id, v_cal_conn_id, 'event:conflict1', v_a, 'family_ops_metadata');

  perform public.server_tx_dispatch_routine_automation(v_now, 2000);

  select * into v_outbox from private.notification_outbox
  where household_id = v_hh_id and recipient_user_id = v_a and channel = 'line' and type = 'routine'
    and dedup_key like 'routine-min:%:2026-08-24:07:00';
  select item ->> 'body' into v_body
  from jsonb_array_elements(v_outbox.payload -> 'items') as item
  where item ->> 'title' = '☀️ 今日の担当';
  if v_body not like '%⚠ 担当と予定の重なり%' then
    raise exception 'FAIL conflict: expected a conflict warning for A (event inside window, correctly busy-mapped), body=%', v_body;
  end if;

  -- B also sees the same household-wide warning (see header comment).
  select * into v_outbox from private.notification_outbox
  where household_id = v_hh_id and recipient_user_id = v_b and channel = 'line' and type = 'routine'
    and dedup_key like 'routine-min:%:2026-08-24:07:00';
  select item ->> 'body' into v_body
  from jsonb_array_elements(v_outbox.payload -> 'items') as item
  where item ->> 'title' = '☀️ 今日の担当';
  if v_body not like '%⚠ 担当と予定の重なり%' then
    raise exception 'FAIL conflict: expected B to also see the household-wide conflict warning, body=%', v_body;
  end if;

  -- Underlying data is untouched — sanity check the rows are still there
  -- exactly as inserted, independent of the LINE text just asserted above.
  select count(*) into v_row_count from public.calendar_event_occurrences where occurrence_key = 'event:conflict1';
  if v_row_count <> 1 then
    raise exception 'FAIL conflict: calendar_event_occurrences row must remain untouched';
  end if;
  select count(*) into v_row_count from public.task_instances where id = v_dropoff_ti and due_at is not null;
  if v_row_count <> 1 then
    raise exception 'FAIL conflict: task_instances row must remain untouched';
  end if;
end;
$$;

-- ===========================================================================
-- Scenario 4b: a calendar occurrence busy-mapped to a DIFFERENT household
-- member than the task's assignee must never produce a false conflict —
-- Sol's explicit acceptance criterion, and the reason busy attribution must
-- come from calendar_occurrence_busy_members rather than
-- creator_mapped_user_id (which here is deliberately set to the assignee,
-- A, to prove the creator field is genuinely ignored).
-- ===========================================================================
do $$
declare
  v_hh_id uuid;
  v_a uuid := '24000000-0000-0000-0000-000000000003';
  v_b uuid := '24000000-0000-0000-0000-000000000004';
  v_cal_conn_id uuid;
  v_dropoff_def uuid;
  v_now timestamptz := ('2026-08-28 07:00:00'::timestamp at time zone 'Asia/Tokyo'); -- Friday
  v_outbox record;
  v_body text;
  v_count int;
begin
  select household_id into v_hh_id from public.household_members where user_id = v_a;
  select id into v_cal_conn_id from public.calendar_connections where household_id = v_hh_id limit 1;
  select id into v_dropoff_def from public.task_definitions where household_id = v_hh_id and code = 'dropoff';

  insert into public.task_instances
    (household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date, due_at,
     planned_assignee_id, completion_mode, status, source, created_by)
  values
    (v_hh_id, v_dropoff_def, 'recurring', '送り', 'dropoff', 'morning', '2026-08-28',
     ('2026-08-28 07:30:00'::timestamp at time zone 'Asia/Tokyo'),
     v_a, 'whole', 'todo', 'recurring', v_a);

  -- Inside window (08:00, 30m after the 07:30 due_at) but busy-mapped only
  -- to B, not A — creator_mapped_user_id is set to A specifically to prove
  -- it is never consulted.
  insert into public.calendar_event_occurrences
    (household_id, calendar_connection_id, occurrence_key, google_event_id, title,
     starts_at, ends_at, status, transparency, creator_mapped_user_id, projection_window_start, projection_window_end)
  values
    (v_hh_id, v_cal_conn_id, 'event:mismatch', 'mismatch', 'ママ通院',
     ('2026-08-28 08:00:00'::timestamp at time zone 'Asia/Tokyo'),
     ('2026-08-28 08:30:00'::timestamp at time zone 'Asia/Tokyo'),
     'confirmed', null, v_a, '2026-01-01', '2027-01-01');
  insert into public.calendar_occurrence_busy_members (household_id, calendar_connection_id, occurrence_key, user_id, source)
  values (v_hh_id, v_cal_conn_id, 'event:mismatch', v_b, 'family_ops_metadata');

  v_count := private.fn_conflict_task_count(v_hh_id, '2026-08-28', '2026-08-28', null);
  if v_count <> 0 then
    raise exception 'FAIL conflict mismatch: busy-member(B) != assignee(A) must not count as a conflict, got %', v_count;
  end if;

  perform public.server_tx_dispatch_routine_automation(v_now, 2000);

  select * into v_outbox from private.notification_outbox
  where household_id = v_hh_id and recipient_user_id = v_a and channel = 'line' and type = 'routine'
    and dedup_key like 'routine-min:%:2026-08-28:07:00';
  select item ->> 'body' into v_body
  from jsonb_array_elements(v_outbox.payload -> 'items') as item
  where item ->> 'title' = '☀️ 今日の担当';
  if v_body like '%⚠ 担当と予定の重なり%' then
    raise exception 'FAIL conflict mismatch: no warning expected when the busy member differs from the assignee, body=%', v_body;
  end if;
end;
$$;

-- ===========================================================================
-- Scenario 5: event outside the conflict window -> no warning; transparent
-- event inside the window -> no warning; all-day event inside the nominal
-- window -> no warning.
-- ===========================================================================
do $$
declare
  v_hh_id uuid;
  v_a uuid := '24000000-0000-0000-0000-000000000003';
  v_cal_conn_id uuid;
  v_dropoff_def uuid;
  v_dropoff_ti uuid;
  v_now timestamptz := ('2026-08-25 07:00:00'::timestamp at time zone 'Asia/Tokyo'); -- Tuesday
  v_outbox record;
  v_body text;
begin
  select household_id into v_hh_id from public.household_members where user_id = v_a;
  select id into v_cal_conn_id from public.calendar_connections where household_id = v_hh_id limit 1;
  select id into v_dropoff_def from public.task_definitions where household_id = v_hh_id and code = 'dropoff';

  insert into public.task_instances
    (id, household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date, due_at,
     planned_assignee_id, completion_mode, status, source, created_by)
  values
    (gen_random_uuid(), v_hh_id, v_dropoff_def, 'recurring', '送り', 'dropoff', 'morning', '2026-08-25',
     ('2026-08-25 07:30:00'::timestamp at time zone 'Asia/Tokyo'),
     v_a, 'whole', 'todo', 'recurring', v_a)
  returning id into v_dropoff_ti;

  -- Outside window: starts 09:30, more than 60m after 07:30 due_at.
  insert into public.calendar_event_occurrences
    (household_id, calendar_connection_id, occurrence_key, google_event_id, title,
     starts_at, ends_at, status, transparency, projection_window_start, projection_window_end)
  values
    (v_hh_id, v_cal_conn_id, 'event:outside', 'outside', '遠い予定',
     ('2026-08-25 09:30:00'::timestamp at time zone 'Asia/Tokyo'),
     ('2026-08-25 10:00:00'::timestamp at time zone 'Asia/Tokyo'),
     'confirmed', null, '2026-01-01', '2027-01-01');
  insert into public.calendar_occurrence_busy_members (household_id, calendar_connection_id, occurrence_key, user_id, source)
  values (v_hh_id, v_cal_conn_id, 'event:outside', v_a, 'manual');

  -- Transparent, inside window (08:00).
  insert into public.calendar_event_occurrences
    (household_id, calendar_connection_id, occurrence_key, google_event_id, title,
     starts_at, ends_at, status, transparency, projection_window_start, projection_window_end)
  values
    (v_hh_id, v_cal_conn_id, 'event:transparent', 'transparent', '空き時間予定',
     ('2026-08-25 08:00:00'::timestamp at time zone 'Asia/Tokyo'),
     ('2026-08-25 08:15:00'::timestamp at time zone 'Asia/Tokyo'),
     'confirmed', 'transparent', '2026-01-01', '2027-01-01');
  insert into public.calendar_occurrence_busy_members (household_id, calendar_connection_id, occurrence_key, user_id, source)
  values (v_hh_id, v_cal_conn_id, 'event:transparent', v_a, 'manual');

  -- All-day, inside the nominal day.
  insert into public.calendar_event_occurrences
    (household_id, calendar_connection_id, occurrence_key, google_event_id, title,
     all_day_start, all_day_end_exclusive, status, transparency, projection_window_start, projection_window_end)
  values
    (v_hh_id, v_cal_conn_id, 'event:allday', 'allday', '終日イベント',
     '2026-08-25', '2026-08-26', 'confirmed', null, '2026-01-01', '2027-01-01');
  insert into public.calendar_occurrence_busy_members (household_id, calendar_connection_id, occurrence_key, user_id, source)
  values (v_hh_id, v_cal_conn_id, 'event:allday', v_a, 'manual');

  perform public.server_tx_dispatch_routine_automation(v_now, 2000);

  select * into v_outbox from private.notification_outbox
  where household_id = v_hh_id and recipient_user_id = v_a and channel = 'line' and type = 'routine'
    and dedup_key like 'routine-min:%:2026-08-25:07:00';
  select item ->> 'body' into v_body
  from jsonb_array_elements(v_outbox.payload -> 'items') as item
  where item ->> 'title' = '☀️ 今日の担当';
  if v_body like '%⚠ 担当と予定の重なり%' then
    raise exception 'FAIL conflict: outside-window/transparent/all-day events must never trigger a conflict warning, body=%', v_body;
  end if;
  -- All three should still show up as ordinary calendar lines were this a
  -- digest (not applicable to daily_assignment, which has no Calendar
  -- section) — the assertion above is the load-bearing one for this branch.
end;
$$;

-- ===========================================================================
-- Scenario 6: conflict_line=false suppresses only the LINE warning text —
-- the underlying task_instances/calendar_event_occurrences rows and the
-- raw conflict computation are untouched.
-- ===========================================================================
do $$
declare
  v_hh_id uuid;
  v_a uuid := '24000000-0000-0000-0000-000000000003';
  v_cal_conn_id uuid;
  v_dropoff_def uuid;
  v_now timestamptz := ('2026-08-26 07:00:00'::timestamp at time zone 'Asia/Tokyo'); -- Wednesday
  v_outbox record;
  v_body text;
  v_raw_count int;
begin
  select household_id into v_hh_id from public.household_members where user_id = v_a;
  select id into v_cal_conn_id from public.calendar_connections where household_id = v_hh_id limit 1;
  select id into v_dropoff_def from public.task_definitions where household_id = v_hh_id and code = 'dropoff';

  update public.notification_preferences set conflict_line = false
  where household_id = v_hh_id and user_id = v_a;

  insert into public.task_instances
    (household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date, due_at,
     planned_assignee_id, completion_mode, status, source, created_by)
  values
    (v_hh_id, v_dropoff_def, 'recurring', '送り', 'dropoff', 'morning', '2026-08-26',
     ('2026-08-26 07:30:00'::timestamp at time zone 'Asia/Tokyo'),
     v_a, 'whole', 'todo', 'recurring', v_a);

  insert into public.calendar_event_occurrences
    (household_id, calendar_connection_id, occurrence_key, google_event_id, title,
     starts_at, ends_at, status, transparency, projection_window_start, projection_window_end)
  values
    (v_hh_id, v_cal_conn_id, 'event:conflict2', 'conflict2', '通院',
     ('2026-08-26 08:00:00'::timestamp at time zone 'Asia/Tokyo'),
     ('2026-08-26 08:30:00'::timestamp at time zone 'Asia/Tokyo'),
     'confirmed', null, '2026-01-01', '2027-01-01');
  insert into public.calendar_occurrence_busy_members (household_id, calendar_connection_id, occurrence_key, user_id, source)
  values (v_hh_id, v_cal_conn_id, 'event:conflict2', v_a, 'manual');

  -- Underlying computation still finds the conflict, independent of the
  -- preference toggle (proves the gate is LINE-text-only, per notification_
  -- preferences.conflict_line's own contract).
  if private.fn_conflict_task_count(v_hh_id, '2026-08-26', '2026-08-26', v_a) < 1 then
    raise exception 'FAIL conflict_line: underlying conflict computation must be unaffected by conflict_line=false';
  end if;

  perform public.server_tx_dispatch_routine_automation(v_now, 2000);

  select * into v_outbox from private.notification_outbox
  where household_id = v_hh_id and recipient_user_id = v_a and channel = 'line' and type = 'routine'
    and dedup_key like 'routine-min:%:2026-08-26:07:00';
  select item ->> 'body' into v_body
  from jsonb_array_elements(v_outbox.payload -> 'items') as item
  where item ->> 'title' = '☀️ 今日の担当';
  if v_body like '%⚠ 担当と予定の重なり%' then
    raise exception 'FAIL conflict_line: conflict_line=false must suppress the LINE warning text, body=%', v_body;
  end if;
  if v_body not like '%送り%' then
    raise exception 'FAIL conflict_line: household task data must remain, body=%', v_body;
  end if;

  select count(*) into v_raw_count from public.calendar_event_occurrences where occurrence_key = 'event:conflict2';
  if v_raw_count <> 1 then
    raise exception 'FAIL conflict_line: calendar_event_occurrences row must remain untouched by the preference';
  end if;
end;
$$;

-- ===========================================================================
-- Scenario 7: cross-household isolation — two households with occurrences
-- and busy-members at the identical local time can never influence each
-- other's conflict count or digest content.
-- ===========================================================================
do $$
declare
  v_hh jsonb;
  v_hh3_id uuid;
  v_hh2_id uuid;
  v_c uuid := '24000000-0000-0000-0000-000000000005';
  v_d uuid := '24000000-0000-0000-0000-000000000006';
  v_google_conn_id uuid;
  v_cal_conn_id uuid;
  v_dropoff_def uuid;
  v_now timestamptz := ('2026-08-27 07:00:00'::timestamp at time zone 'Asia/Tokyo'); -- Thursday
  v_outbox record;
  v_body text;
  v_conflict_count int;
begin
  v_hh := public.server_tx_create_household(v_c, gen_random_uuid(), 'WP8 Conflict HH3', 'C');
  v_hh3_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role) values (v_hh3_id, v_d, 'adult');

  select household_id into v_hh2_id from public.household_members where user_id = '24000000-0000-0000-0000-000000000003';

  insert into private.google_connections
    (id, household_id, owner_user_id, google_subject, encrypted_refresh_token, encryption_version, scopes, status)
  values
    (gen_random_uuid(), v_hh3_id, v_c, 'google-subj-24-hh3', 'cipher', 1,
     array['https://www.googleapis.com/auth/calendar.events'], 'active')
  returning id into v_google_conn_id;

  insert into public.calendar_connections
    (id, household_id, provider, external_calendar_id, google_connection_id, active, last_incremental_sync_at, reauth_required)
  values
    (gen_random_uuid(), v_hh3_id, 'google', 'family-hh3@group.calendar.google.com', v_google_conn_id, true, now(), false)
  returning id into v_cal_conn_id;

  select id into v_dropoff_def from public.task_definitions where household_id = v_hh3_id and code = 'dropoff';
  -- HH3's dropoff task has NO due_at set (so it can never conflict) and no
  -- calendar occurrence at all — HH2's same-day-same-time conflict fixtures
  -- (scenario 4/5/6, still present in HH2 from '24000000...0003') must not
  -- leak into HH3's count despite identical local clock time.
  insert into public.task_instances
    (household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
     planned_assignee_id, completion_mode, status, source, created_by)
  values
    (v_hh3_id, v_dropoff_def, 'recurring', '送り', 'dropoff', 'morning', '2026-08-27',
     v_c, 'whole', 'todo', 'recurring', v_c);

  v_conflict_count := private.fn_conflict_task_count(v_hh3_id, '2026-08-27', '2026-08-27', null);
  if v_conflict_count <> 0 then
    raise exception 'FAIL cross-household: HH3 conflict count must be 0 (no due_at, no occurrences), got %', v_conflict_count;
  end if;

  perform public.server_tx_dispatch_routine_automation(v_now, 2000);

  select * into v_outbox from private.notification_outbox
  where household_id = v_hh3_id and recipient_user_id = v_c and channel = 'line' and type = 'routine'
    and dedup_key like 'routine-min:%:2026-08-27:07:00';
  select item ->> 'body' into v_body
  from jsonb_array_elements(v_outbox.payload -> 'items') as item
  where item ->> 'title' = '☀️ 今日の担当';
  if v_body like '%⚠ 担当と予定の重なり%' then
    raise exception 'FAIL cross-household: HH3 must never see a conflict warning derived from HH2 data, body=%', v_body;
  end if;
end;
$$;

reset role;

select '24_routine_digest_calendar_and_conflict: PASS' as result;
