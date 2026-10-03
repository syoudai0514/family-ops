-- Regression for owner decision 2026-10-03:
-- one selected family calendar may expose event details; other connected
-- calendars remain usable for busy/conflict detection only.
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('cc100000-0000-0000-0000-000000000001');

set role service_role;

do $$
declare
  v_user uuid := 'cc100000-0000-0000-0000-000000000001';
  v_hh jsonb;
  v_hh_id uuid;
  v_google_conn_id uuid;
  v_target_conn_id uuid;
  v_private_conn_id uuid;
  v_today date := (now() at time zone 'Asia/Tokyo')::date;
  v_today_result jsonb;
  v_week_result jsonb;
  v_brief jsonb;
  v_lines text;
  v_task_id uuid;
begin
  v_hh := public.server_tx_create_household(
    v_user, gen_random_uuid(), 'Shared Calendar Visibility', 'Owner'
  );
  v_hh_id := (v_hh->>'household_id')::uuid;

  insert into public.domain_actor_refs(household_id, actor_kind, real_user_id)
  values (v_hh_id, 'real_user', v_user)
  on conflict (household_id, real_user_id) where actor_kind = 'real_user'
  do nothing;

  insert into private.google_connections(
    household_id, owner_user_id, google_subject, encrypted_refresh_token,
    encryption_version, scopes, status
  ) values (
    v_hh_id, v_user, 'shared-calendar-visibility-' || v_user::text,
    'ciphertext', 1, array['calendar.readonly'], 'active'
  ) returning id into v_google_conn_id;

  insert into public.calendar_connections(
    household_id, provider, external_calendar_id, display_name,
    google_connection_id, active, last_incremental_sync_at,
    reauth_required, is_family_write_target
  ) values (
    v_hh_id, 'google', 'family-target@example.invalid', 'おうちノート',
    v_google_conn_id, true, now(), false, true
  ) returning id into v_target_conn_id;

  insert into public.calendar_connections(
    household_id, provider, external_calendar_id, display_name,
    google_connection_id, active, last_incremental_sync_at,
    reauth_required, is_family_write_target
  ) values (
    v_hh_id, 'google', 'private-calendar@example.invalid', '個人カレンダー',
    v_google_conn_id, true, now(), false, false
  ) returning id into v_private_conn_id;

  insert into public.calendar_event_occurrences(
    household_id, calendar_connection_id, occurrence_key, google_event_id,
    title, starts_at, ends_at, status, transparency,
    projection_window_start, projection_window_end
  ) values
    (
      v_hh_id, v_target_conn_id, 'visible-shared-event', 'visible-shared-event',
      '共有予定',
      (v_today::text || ' 09:00:00')::timestamp at time zone 'Asia/Tokyo',
      (v_today::text || ' 10:00:00')::timestamp at time zone 'Asia/Tokyo',
      'confirmed', 'opaque', v_today - 1, v_today + 7
    ),
    (
      v_hh_id, v_private_conn_id, 'hidden-private-event', 'hidden-private-event',
      '個人予定（見せない）',
      (v_today::text || ' 11:00:00')::timestamp at time zone 'Asia/Tokyo',
      (v_today::text || ' 12:00:00')::timestamp at time zone 'Asia/Tokyo',
      'confirmed', 'opaque', v_today - 1, v_today + 7
    );

  insert into public.calendar_events_cache(
    household_id, calendar_connection_id, google_event_id, title,
    starts_at, ends_at, status, transparency
  ) values
    (
      v_hh_id, v_target_conn_id, 'cache-visible-shared-event', '共有キャッシュ予定',
      (v_today::text || ' 09:00:00')::timestamp at time zone 'Asia/Tokyo',
      (v_today::text || ' 10:00:00')::timestamp at time zone 'Asia/Tokyo',
      'confirmed', 'opaque'
    ),
    (
      v_hh_id, v_private_conn_id, 'cache-hidden-private-event', '個人キャッシュ予定（見せない）',
      (v_today::text || ' 11:00:00')::timestamp at time zone 'Asia/Tokyo',
      (v_today::text || ' 12:00:00')::timestamp at time zone 'Asia/Tokyo',
      'confirmed', 'opaque'
    );

  -- The private calendar still contributes to busy/conflict detection.
  insert into public.calendar_occurrence_busy_members(
    household_id, calendar_connection_id, occurrence_key, user_id, source
  ) values (
    v_hh_id, v_private_conn_id, 'hidden-private-event', v_user, 'manual'
  );

  insert into public.task_instances(
    household_id, task_definition_id, origin, title, category, routine_phase,
    scheduled_date, due_at, planned_assignee_id, completion_mode,
    status, source, created_by
  ) values (
    v_hh_id, null, 'manual', '重複確認用タスク', 'todo', 'anytime',
    v_today,
    (v_today::text || ' 11:30:00')::timestamp at time zone 'Asia/Tokyo',
    v_user, 'whole', 'todo', 'manual', v_user
  ) returning id into v_task_id;

  v_today_result := public.server_tx_get_today_schedule(v_user);
  if not exists (
    select 1 from jsonb_array_elements(v_today_result->'occurrences') x
    where x->>'title' = '共有予定'
  ) then
    raise exception 'FAIL shared calendar: target occurrence missing from Today: %',
      v_today_result->'occurrences';
  end if;
  if exists (
    select 1 from jsonb_array_elements(v_today_result->'occurrences') x
    where x->>'title' = '個人予定（見せない）'
  ) then
    raise exception 'FAIL shared calendar: private occurrence leaked into Today: %',
      v_today_result->'occurrences';
  end if;
  if not exists (
    select 1 from jsonb_array_elements(v_today_result->'assignments') x
    where (x->>'task_instance_id')::uuid = v_task_id
      and (x->>'has_conflict')::boolean
  ) then
    raise exception 'FAIL shared calendar: private busy event must still flag conflict: %',
      v_today_result->'assignments';
  end if;

  v_week_result := public.server_tx_get_week_schedule(v_user, v_today, v_today + 6);
  if exists (
    select 1 from jsonb_array_elements(v_week_result->'occurrences') x
    where x->>'title' = '個人予定（見せない）'
  ) or not exists (
    select 1 from jsonb_array_elements(v_week_result->'occurrences') x
    where x->>'title' = '共有予定'
  ) then
    raise exception 'FAIL shared calendar: Week visibility mismatch: %',
      v_week_result->'occurrences';
  end if;

  v_brief := public.server_read_daily_brief(v_user, v_today);
  if exists (
    select 1 from jsonb_array_elements(v_brief->'schedule') x
    where x->>'title' = '個人予定（見せない）'
  ) or not exists (
    select 1 from jsonb_array_elements(v_brief->'schedule') x
    where x->>'title' = '共有予定'
  ) then
    raise exception 'FAIL shared calendar: DailyBrief visibility mismatch: %',
      v_brief->'schedule';
  end if;

  v_lines := private.fn_calendar_day_lines(v_hh_id, v_today);
  if position('共有予定' in coalesce(v_lines, '')) = 0
     or position('個人予定（見せない）' in coalesce(v_lines, '')) > 0 then
    raise exception 'FAIL shared calendar: legacy digest visibility mismatch: %', v_lines;
  end if;
end;
$$;

reset role;

-- Direct authenticated browser reads must be target-only even if a future
-- frontend forgets its own target filter.
set role authenticated;
set request.jwt.claim.sub = 'cc100000-0000-0000-0000-000000000001';
set request.jwt.claim.role = 'authenticated';

do $$
declare
  v_count int;
begin
  select count(*) into v_count
  from public.calendar_event_occurrences
  where occurrence_key in ('visible-shared-event', 'hidden-private-event');
  if v_count <> 1 then
    raise exception 'FAIL shared calendar RLS: expected one visible occurrence, saw %', v_count;
  end if;
  if exists (
    select 1 from public.calendar_event_occurrences
    where occurrence_key = 'hidden-private-event'
  ) then
    raise exception 'FAIL shared calendar RLS: private occurrence readable by browser';
  end if;

  select count(*) into v_count
  from public.calendar_events_cache
  where google_event_id in ('cache-visible-shared-event', 'cache-hidden-private-event');
  if v_count <> 1 then
    raise exception 'FAIL shared calendar cache RLS: expected one visible cache row, saw %', v_count;
  end if;
  if exists (
    select 1 from public.calendar_events_cache
    where google_event_id = 'cache-hidden-private-event'
  ) then
    raise exception 'FAIL shared calendar cache RLS: private cache row readable by browser';
  end if;
end;
$$;

reset role;
reset request.jwt.claim.sub;
reset request.jwt.claim.role;

select 'shared_calendar_visibility_boundary: PASS' as result;
