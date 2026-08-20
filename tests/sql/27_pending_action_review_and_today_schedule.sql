-- Sol re-review #3 fix (P1-1/P1-2, docs/adr/0011): SQL/RPC-level assertions
-- for 20260819000102_pending_action_review_and_today_schedule.sql --
-- server_tx_list_pending_actions and server_tx_get_today_schedule, plus the
-- refactored private.fn_calendar_conflict_exists/fn_conflict_task_count.
--
-- The PWA half (PendingActionCard/TodaySchedule components, list/confirm/
-- cancel button wiring) is covered by apps/web/src/features/today's own
-- vitest suite -- this file only covers what's genuinely checkable at the
-- SQL/RPC layer, matching this repo's existing tests/sql convention.
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('27000000-0000-0000-0000-000000000001'), -- HH1 adult A (pending-action scenarios)
  ('27000000-0000-0000-0000-000000000002'), -- HH1 adult B
  ('27000000-0000-0000-0000-000000000003'), -- HH2 adult A (today-schedule scenarios)
  ('27000000-0000-0000-0000-000000000004'), -- HH2 adult B
  ('27000000-0000-0000-0000-000000000005'), -- HH3 adult A (no-calendar/degrade scenario)
  ('27000000-0000-0000-0000-000000000006'); -- HH4 adult A (decoy cross-household calendar owner)

set role service_role;

-- ===========================================================================
-- Scenario 1: server_tx_list_pending_actions is actor-scoped (never the
-- partner's), reflects status transitions, drops terminal/expired rows, and
-- rejects invalid input.
-- ===========================================================================
do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_a uuid := '27000000-0000-0000-0000-000000000001';
  v_b uuid := '27000000-0000-0000-0000-000000000002';
  v_pending jsonb;
  v_pending_id uuid;
  v_list jsonb;
  v_raised boolean;
begin
  v_hh := public.server_tx_create_household(v_a, gen_random_uuid(), 'WP-P1-1 Pending HH', 'A');
  v_hh_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role) values (v_hh_id, v_b, 'adult');

  -- Nothing yet for either actor.
  v_list := public.server_tx_list_pending_actions(v_a);
  if jsonb_array_length(v_list) <> 0 then
    raise exception 'FAIL list: expected an empty list before any pending action exists, got %', v_list;
  end if;

  v_pending := public.server_tx_create_pending_action(
    v_a, v_hh_id, gen_random_uuid(), 'line', 'shopping_item_add',
    jsonb_build_object('title', 'オムツ', 'purchase_method', 'online'), 30
  );
  v_pending_id := (v_pending->>'pending_action_id')::uuid;

  -- A (the sender) sees exactly one draft row with the expected shape.
  v_list := public.server_tx_list_pending_actions(v_a);
  if jsonb_array_length(v_list) <> 1
     or (v_list -> 0 ->> 'id')::uuid <> v_pending_id
     or v_list -> 0 ->> 'status' <> 'draft'
     or v_list -> 0 ->> 'action_type' <> 'shopping_item_add'
     or (v_list -> 0 -> 'normalized_payload' ->> 'title') <> 'オムツ' then
    raise exception 'FAIL list: expected A''s draft pending action, got %', v_list;
  end if;

  -- B (the partner) must never see A's private draft.
  v_list := public.server_tx_list_pending_actions(v_b);
  if jsonb_array_length(v_list) <> 0 then
    raise exception 'FAIL list: partner must not see the sender''s pending action, got %', v_list;
  end if;

  -- Confirm: still listed, now status=confirmed (worker has not run yet).
  perform public.server_tx_confirm_pending_action(v_a, v_pending_id);
  v_list := public.server_tx_list_pending_actions(v_a);
  if jsonb_array_length(v_list) <> 1 or v_list -> 0 ->> 'status' <> 'confirmed' then
    raise exception 'FAIL list: expected confirmed pending action still listed, got %', v_list;
  end if;

  -- Simulate worker completion (server_tx_complete_pending_action's own
  -- effect, exercised directly here since only the LIST-side visibility
  -- change is under test) -- the card must disappear once succeeded.
  update private.pending_actions set status = 'succeeded' where id = v_pending_id;
  v_list := public.server_tx_list_pending_actions(v_a);
  if jsonb_array_length(v_list) <> 0 then
    raise exception 'FAIL list: a succeeded pending action must no longer be listed, got %', v_list;
  end if;

  -- A second, separately-created draft: cancel must also remove it from the list.
  v_pending := public.server_tx_create_pending_action(
    v_a, v_hh_id, gen_random_uuid(), 'line', 'task_create_once',
    jsonb_build_object('title', 'ゴミ出し', 'scheduled_date', '2026-08-25'), 30
  );
  v_pending_id := (v_pending->>'pending_action_id')::uuid;
  perform public.server_tx_cancel_pending_action(v_a, v_pending_id);
  v_list := public.server_tx_list_pending_actions(v_a);
  if jsonb_array_length(v_list) <> 0 then
    raise exception 'FAIL list: a cancelled pending action must no longer be listed, got %', v_list;
  end if;

  -- Expired: a draft whose expires_at has passed must not be listed either
  -- (matches "Expired pending action cannot be confirmed" — it must not
  -- even be offered).
  v_pending := public.server_tx_create_pending_action(
    v_a, v_hh_id, gen_random_uuid(), 'line', 'shopping_item_add',
    jsonb_build_object('title', '牛乳', 'purchase_method', 'store'), 30
  );
  v_pending_id := (v_pending->>'pending_action_id')::uuid;
  update private.pending_actions set expires_at = now() - interval '1 minute' where id = v_pending_id;
  v_list := public.server_tx_list_pending_actions(v_a);
  if jsonb_array_length(v_list) <> 0 then
    raise exception 'FAIL list: an expired draft must not be listed, got %', v_list;
  end if;
  -- and confirming an expired draft is still correctly rejected (existing
  -- RPC behavior, re-asserted here in the same scenario for completeness).
  v_raised := false;
  begin
    perform public.server_tx_confirm_pending_action(v_a, v_pending_id);
  exception when others then
    v_raised := true;
    if sqlerrm <> 'INVALID_INPUT' then
      raise exception 'FAIL list: expected INVALID_INPUT confirming an expired draft, got %', sqlerrm;
    end if;
  end;
  if not v_raised then
    raise exception 'FAIL list: confirming an expired draft must be rejected';
  end if;

  -- Invalid input.
  v_raised := false;
  begin
    perform public.server_tx_list_pending_actions(null);
  exception when others then
    v_raised := true;
    if sqlerrm <> 'INVALID_INPUT' then
      raise exception 'FAIL list: expected INVALID_INPUT for a null actor, got %', sqlerrm;
    end if;
  end;
  if not v_raised then
    raise exception 'FAIL list: a null actor must be rejected';
  end if;
end;
$$;

-- ===========================================================================
-- Scenario 2: server_tx_get_today_schedule -- occurrence display filtering
-- (all-day/transparent excluded, cross-household excluded), per-assignment
-- has_conflict via the SAME predicate fn_conflict_task_count uses, and
-- calendar_connected/calendar_stale for a healthy connection.
-- ===========================================================================
do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_other_hh jsonb;
  v_other_hh_id uuid;
  v_a uuid := '27000000-0000-0000-0000-000000000003';
  v_b uuid := '27000000-0000-0000-0000-000000000004';
  v_google_conn_id uuid;
  v_cal_conn_id uuid;
  v_other_cal_conn_id uuid;
  v_dropoff_def uuid;
  v_today date := (now() at time zone 'Asia/Tokyo')::date;
  v_conflict_ti uuid;
  v_clean_ti uuid;
  v_result jsonb;
  v_occ_keys text[];
  v_conflict_assignment jsonb;
  v_clean_assignment jsonb;
begin
  v_hh := public.server_tx_create_household(v_a, gen_random_uuid(), 'WP-P1-2 Schedule HH', 'A');
  v_hh_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role) values (v_hh_id, v_b, 'adult');

  -- A dedicated, never-elsewhere-used actor for the decoy household — every
  -- user_id can belong to at most one household (household_members'
  -- unique(user_id)), so this cannot reuse v_a/v_b.
  v_other_hh := public.server_tx_create_household(
    '27000000-0000-0000-0000-000000000006'::uuid, gen_random_uuid(), 'WP-P1-2 Other HH', 'A'
  );
  v_other_hh_id := (v_other_hh->>'household_id')::uuid;

  insert into private.google_connections
    (id, household_id, owner_user_id, google_subject, encrypted_refresh_token, encryption_version, scopes, status)
  values
    (gen_random_uuid(), v_hh_id, v_a, 'google-subj-27-hh1', 'cipher', 1,
     array['https://www.googleapis.com/auth/calendar.events'], 'active')
  returning id into v_google_conn_id;

  insert into public.calendar_connections
    (id, household_id, provider, external_calendar_id, google_connection_id, active, last_incremental_sync_at, reauth_required)
  values
    (gen_random_uuid(), v_hh_id, 'google', 'family-27hh1@group.calendar.google.com', v_google_conn_id, true, now(), false)
  returning id into v_cal_conn_id;

  select id into v_dropoff_def from public.task_definitions where household_id = v_hh_id and code = 'dropoff';

  -- Conflicting: dropoff due 07:30, timed non-transparent event at 08:00
  -- (inside the default 60-minute window), busy-mapped to A.
  insert into public.task_instances
    (id, household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date, due_at,
     planned_assignee_id, completion_mode, status, source, created_by)
  values
    (gen_random_uuid(), v_hh_id, v_dropoff_def, 'recurring', '送り', 'dropoff', 'morning', v_today,
     (v_today::text || ' 07:30:00')::timestamp at time zone 'Asia/Tokyo',
     v_a, 'whole', 'todo', 'recurring', v_a)
  returning id into v_conflict_ti;

  insert into public.calendar_event_occurrences
    (household_id, calendar_connection_id, occurrence_key, google_event_id, title,
     starts_at, ends_at, status, transparency, creator_mapped_user_id, projection_window_start, projection_window_end)
  values
    (v_hh_id, v_cal_conn_id, 'event:27-conflict', '27-conflict', '歯医者',
     (v_today::text || ' 08:00:00')::timestamp at time zone 'Asia/Tokyo',
     (v_today::text || ' 08:30:00')::timestamp at time zone 'Asia/Tokyo',
     'confirmed', null, v_b, '2026-01-01', '2027-01-01');
  insert into public.calendar_occurrence_busy_members (household_id, calendar_connection_id, occurrence_key, user_id, source)
  values (v_hh_id, v_cal_conn_id, 'event:27-conflict', v_a, 'family_ops_metadata');

  -- Clean: a manual task far from any calendar occurrence -> no conflict.
  insert into public.task_instances
    (id, household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date, due_at,
     planned_assignee_id, completion_mode, status, source, created_by)
  values
    (gen_random_uuid(), v_hh_id, null, 'manual', '書類提出', 'todo', 'anytime', v_today,
     (v_today::text || ' 20:00:00')::timestamp at time zone 'Asia/Tokyo',
     v_b, 'whole', 'todo', 'manual', v_b)
  returning id into v_clean_ti;

  -- All-day event today -> must be excluded from the display list.
  insert into public.calendar_event_occurrences
    (household_id, calendar_connection_id, occurrence_key, google_event_id, title,
     all_day_start, all_day_end_exclusive, status, transparency, projection_window_start, projection_window_end)
  values
    (v_hh_id, v_cal_conn_id, 'event:27-allday', '27-allday', '終日イベント',
     v_today, v_today + 1, 'confirmed', null, '2026-01-01', '2027-01-01');

  -- Transparent timed event today -> must be excluded from the display list.
  insert into public.calendar_event_occurrences
    (household_id, calendar_connection_id, occurrence_key, google_event_id, title,
     starts_at, ends_at, status, transparency, projection_window_start, projection_window_end)
  values
    (v_hh_id, v_cal_conn_id, 'event:27-transparent', '27-transparent', '空き時間予定',
     (v_today::text || ' 10:00:00')::timestamp at time zone 'Asia/Tokyo',
     (v_today::text || ' 10:30:00')::timestamp at time zone 'Asia/Tokyo',
     'confirmed', 'transparent', '2026-01-01', '2027-01-01');

  -- Decoy calendar row under a different household must never appear.
  insert into private.google_connections
    (id, household_id, owner_user_id, google_subject, encrypted_refresh_token, encryption_version, scopes, status)
  values
    (gen_random_uuid(), v_other_hh_id, '27000000-0000-0000-0000-000000000006'::uuid, 'google-subj-27-other', 'cipher', 1,
     array['https://www.googleapis.com/auth/calendar.events'], 'active')
  returning id into v_google_conn_id;
  insert into public.calendar_connections
    (id, household_id, provider, external_calendar_id, google_connection_id, active, last_incremental_sync_at, reauth_required)
  values
    (gen_random_uuid(), v_other_hh_id, 'google', 'family-27other@group.calendar.google.com', v_google_conn_id, true, now(), false)
  returning id into v_other_cal_conn_id;
  insert into public.calendar_event_occurrences
    (household_id, calendar_connection_id, occurrence_key, google_event_id, title,
     starts_at, ends_at, status, transparency, projection_window_start, projection_window_end)
  values
    (v_other_hh_id, v_other_cal_conn_id, 'event:27-other-hh', '27-other-hh', '他家庭の予定',
     (v_today::text || ' 09:00:00')::timestamp at time zone 'Asia/Tokyo',
     (v_today::text || ' 09:30:00')::timestamp at time zone 'Asia/Tokyo',
     'confirmed', null, '2026-01-01', '2027-01-01');

  v_result := public.server_tx_get_today_schedule(v_a);

  if (v_result->>'household_id')::uuid <> v_hh_id then
    raise exception 'FAIL schedule: household_id mismatch, got %', v_result->>'household_id';
  end if;
  if (v_result->>'calendar_connected')::boolean is not true then
    raise exception 'FAIL schedule: expected calendar_connected=true, got %', v_result->>'calendar_connected';
  end if;
  if (v_result->>'calendar_stale')::boolean is not false then
    raise exception 'FAIL schedule: expected calendar_stale=false for a just-synced connection, got %', v_result->>'calendar_stale';
  end if;

  select array_agg(occ ->> 'occurrence_key') into v_occ_keys
  from jsonb_array_elements(v_result -> 'occurrences') as occ;
  if v_occ_keys is null or not (v_occ_keys @> array['event:27-conflict']) then
    raise exception 'FAIL schedule: expected the timed non-transparent occurrence to appear, got %', v_result -> 'occurrences';
  end if;
  if v_occ_keys @> array['event:27-allday'] then
    raise exception 'FAIL schedule: an all-day event must be excluded, got %', v_result -> 'occurrences';
  end if;
  if v_occ_keys @> array['event:27-transparent'] then
    raise exception 'FAIL schedule: a transparent event must be excluded, got %', v_result -> 'occurrences';
  end if;
  if v_occ_keys @> array['event:27-other-hh'] then
    raise exception 'FAIL schedule: cross-household calendar data must never appear, got %', v_result -> 'occurrences';
  end if;

  select occ into v_conflict_assignment
  from jsonb_array_elements(v_result -> 'occurrences') as occ
  where occ ->> 'occurrence_key' = 'event:27-conflict';
  if not (v_conflict_assignment -> 'busy_user_ids' @> to_jsonb(v_a::text)) then
    raise exception 'FAIL schedule: expected busy_user_ids to include A, got %', v_conflict_assignment -> 'busy_user_ids';
  end if;

  select item into v_conflict_assignment
  from jsonb_array_elements(v_result -> 'assignments') as item
  where (item ->> 'task_instance_id')::uuid = v_conflict_ti;
  if v_conflict_assignment is null or (v_conflict_assignment ->> 'has_conflict')::boolean is not true then
    raise exception 'FAIL schedule: expected the dropoff assignment to be flagged has_conflict=true, got %', v_conflict_assignment;
  end if;

  select item into v_clean_assignment
  from jsonb_array_elements(v_result -> 'assignments') as item
  where (item ->> 'task_instance_id')::uuid = v_clean_ti;
  if v_clean_assignment is null or (v_clean_assignment ->> 'has_conflict')::boolean is not false then
    raise exception 'FAIL schedule: expected the unrelated manual task to be has_conflict=false, got %', v_clean_assignment;
  end if;

  -- fn_conflict_task_count (the LINE digest's own aggregate) must agree
  -- with the per-item flags above -- exactly 1 conflicting task household-wide.
  if private.fn_conflict_task_count(v_hh_id, v_today, v_today, null) <> 1 then
    raise exception 'FAIL schedule: fn_conflict_task_count must agree with the per-item has_conflict flags';
  end if;
end;
$$;

-- ===========================================================================
-- Scenario 3: graceful degradation when no calendar is connected at all,
-- and calendar_stale=true for a reauth-required or long-unsynced connection.
-- ===========================================================================
do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_a uuid := '27000000-0000-0000-0000-000000000004';
  v_today date := (now() at time zone 'Asia/Tokyo')::date;
  v_dropoff_def uuid;
  v_result jsonb;
  v_google_conn_id uuid;
  v_cal_conn_id uuid;
begin
  -- Reuse HH2's own actor 4 as a fresh single-member household of its own
  -- would collide with scenario 2's household membership; instead exercise
  -- the "no calendar connection at all" path directly against a brand-new
  -- household for this same auth.users row is not possible (already a
  -- member of HH2) -- so this scenario creates ITS OWN third household
  -- with a never-before-used actor instead, kept local to this do-block.
  v_hh := public.server_tx_create_household(
    '27000000-0000-0000-0000-000000000005'::uuid, gen_random_uuid(), 'WP-P1-2 No-Calendar HH', 'A'
  );
  v_hh_id := (v_hh->>'household_id')::uuid;

  select id into v_dropoff_def from public.task_definitions where household_id = v_hh_id and code = 'dropoff';
  insert into public.task_instances
    (id, household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date, due_at,
     planned_assignee_id, completion_mode, status, source, created_by)
  values
    (gen_random_uuid(), v_hh_id, v_dropoff_def, 'recurring', '送り', 'dropoff', 'morning', v_today,
     (v_today::text || ' 07:30:00')::timestamp at time zone 'Asia/Tokyo',
     '27000000-0000-0000-0000-000000000005'::uuid, 'whole', 'todo', 'recurring',
     '27000000-0000-0000-0000-000000000005'::uuid);

  v_result := public.server_tx_get_today_schedule('27000000-0000-0000-0000-000000000005'::uuid);
  if (v_result->>'calendar_connected')::boolean is not false then
    raise exception 'FAIL degrade: expected calendar_connected=false with no connection row, got %', v_result->>'calendar_connected';
  end if;
  if (v_result->>'calendar_stale')::boolean is not false then
    raise exception 'FAIL degrade: expected calendar_stale=false (nothing to be stale) with no connection, got %', v_result->>'calendar_stale';
  end if;
  if jsonb_array_length(v_result -> 'occurrences') <> 0 then
    raise exception 'FAIL degrade: expected zero occurrences with no calendar connection, got %', v_result -> 'occurrences';
  end if;
  if jsonb_array_length(v_result -> 'assignments') <> 1 then
    raise exception 'FAIL degrade: household tasks must still be usable without a calendar connection, got %', v_result -> 'assignments';
  end if;

  -- Now attach a reauth-required connection -> calendar_stale must flip true
  -- even though nothing else changed.
  insert into private.google_connections
    (id, household_id, owner_user_id, google_subject, encrypted_refresh_token, encryption_version, scopes, status)
  values
    (gen_random_uuid(), v_hh_id, '27000000-0000-0000-0000-000000000005'::uuid, 'google-subj-27-reauth', 'cipher', 1,
     array['https://www.googleapis.com/auth/calendar.events'], 'active')
  returning id into v_google_conn_id;
  insert into public.calendar_connections
    (id, household_id, provider, external_calendar_id, google_connection_id, active, last_incremental_sync_at, reauth_required)
  values
    (gen_random_uuid(), v_hh_id, 'google', 'family-27reauth@group.calendar.google.com', v_google_conn_id, true, now(), true)
  returning id into v_cal_conn_id;

  v_result := public.server_tx_get_today_schedule('27000000-0000-0000-0000-000000000005'::uuid);
  if (v_result->>'calendar_connected')::boolean is not true then
    raise exception 'FAIL degrade: expected calendar_connected=true once a connection exists, got %', v_result->>'calendar_connected';
  end if;
  if (v_result->>'calendar_stale')::boolean is not true then
    raise exception 'FAIL degrade: expected calendar_stale=true while reauth_required, got %', v_result->>'calendar_stale';
  end if;

  -- Clear reauth but simulate a sync from 2 hours ago -> still stale via the
  -- 60-minute-old threshold.
  update public.calendar_connections
  set reauth_required = false, last_incremental_sync_at = now() - interval '2 hours'
  where id = v_cal_conn_id;

  v_result := public.server_tx_get_today_schedule('27000000-0000-0000-0000-000000000005'::uuid);
  if (v_result->>'calendar_stale')::boolean is not true then
    raise exception 'FAIL degrade: expected calendar_stale=true for a sync older than 60 minutes, got %', v_result->>'calendar_stale';
  end if;
end;
$$;

reset role;

select 'pending_action_review_and_today_schedule: PASS' as result;
