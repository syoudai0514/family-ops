-- UX v3.3: outbound Google mirrors use a stable projection key/provider id,
-- never title/date matching. Provider work is claimed from an outbox after
-- the Family Ops task transaction has committed.
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('39000000-0000-0000-0000-000000000001'),
  ('39000000-0000-0000-0000-000000000002');

set role service_role;

do $$
declare
  v_owner uuid := '39000000-0000-0000-0000-000000000001';
  v_partner uuid := '39000000-0000-0000-0000-000000000002';
  v_hh jsonb;
  v_hh_id uuid;
  v_google_conn uuid;
  v_calendar_conn uuid;
  v_dropoff uuid;
  v_pickup uuid;
  v_special uuid;
  v_dropoff_task uuid;
  v_pickup_task uuid;
  v_special_task uuid;
  v_claim jsonb;
  v_second_claim jsonb;
  v_special_claim jsonb;
  v_local_date date := '2026-09-01';
begin
  v_hh := public.server_tx_create_household(v_owner, gen_random_uuid(), 'UX v3.3 Google outbox', 'Primary');
  v_hh_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role)
  values (v_hh_id, v_partner, 'adult');

  insert into private.google_connections
    (household_id, owner_user_id, google_subject, encrypted_refresh_token, encryption_version, scopes, status)
  values
    (v_hh_id, v_owner, 'google-outbox-30', 'cipher', 1,
     array['https://www.googleapis.com/auth/calendar.events'], 'active')
  returning id into v_google_conn;
  insert into public.calendar_connections
    (household_id, provider, external_calendar_id, google_connection_id, active, reauth_required)
  values (v_hh_id, 'google', 'outbox-30@group.calendar.google.com', v_google_conn, true, false)
  returning id into v_calendar_conn;
  if (select is_family_write_target from public.calendar_connections where id = v_calendar_conn) then
    raise exception 'FAIL family-google-outbox: a new connection must not become the write target automatically';
  end if;
  perform public.server_tx_set_family_calendar_target(v_owner, gen_random_uuid(), v_calendar_conn);
  if not (select is_family_write_target from public.calendar_connections where id = v_calendar_conn) then
    raise exception 'FAIL family-google-outbox: explicit target selection must enable outbound mirrors';
  end if;

  -- Connecting a calendar deliberately reconciles the household's existing
  -- horizon.  This fixture asserts one particular future projection, so
  -- discard that bootstrap work before inserting the isolated test tasks.
  delete from private.family_ops_calendar_mirrors where household_id = v_hh_id;

  select id into v_dropoff from public.task_definitions where household_id = v_hh_id and code = 'dropoff';
  select id into v_pickup from public.task_definitions where household_id = v_hh_id and code = 'pickup';
  insert into public.task_definitions
    (household_id, code, title, category, routine_phase, completion_mode, calendar_visibility, created_by)
  values (v_hh_id, 'clinic_30', '皮膚科', 'medical', 'anytime', 'whole', 'special', v_owner)
  returning id into v_special;

  insert into public.task_instances
    (household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
     planned_assignee_id, completion_mode, status, source, created_by)
  values
    (v_hh_id, v_dropoff, 'recurring', '送り', 'dropoff', 'morning', v_local_date, v_owner, 'whole', 'todo', 'test', v_owner)
  returning id into v_dropoff_task;
  insert into public.task_instances
    (household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
     planned_assignee_id, completion_mode, status, source, created_by)
  values
    (v_hh_id, v_pickup, 'recurring', '迎え', 'pickup', 'evening', v_local_date, v_partner, 'whole', 'todo', 'test', v_owner)
  returning id into v_pickup_task;

  if (select count(*) from private.family_ops_calendar_mirrors where household_id = v_hh_id and projection_key = 'transport:2026-09-01') <> 1 then
    raise exception 'FAIL family-google-outbox: dropoff/pickup must coalesce to one daily mirror';
  end if;
  -- Bootstrap recurrence materialisation can enqueue an existing date after
  -- the connection reconciliation.  Keep only this fixture's projection so
  -- the generic worker claim below deterministically tests the intended day.
  delete from private.family_ops_calendar_mirrors
  where household_id = v_hh_id and projection_key <> 'transport:2026-09-01';
  -- Some bootstrap rows are re-enqueued by legacy recurrence triggers after
  -- the delete above.  The worker queue is intentionally global across
  -- households, so defer every other fixture row as well and keep this
  -- projection as the sole claimable item.
  update private.family_ops_calendar_mirrors
  set next_attempt_at = now() + interval '1 day'
  where not (household_id = v_hh_id and projection_key = 'transport:2026-09-01');
  v_claim := public.server_tx_claim_family_ops_calendar_mirror('sql-30', 120);
  if v_claim->>'action' <> 'upsert'
     or v_claim #>> '{event,summary}' <> '送P迎M'
     or v_claim #>> '{event,start,date}' <> '2026-09-01'
     or v_claim #>> '{event,transparency}' <> 'transparent' then
    raise exception 'FAIL family-google-outbox: transport must be one transparent all-day P/M event, got %', v_claim;
  end if;
  perform public.server_tx_complete_family_ops_calendar_mirror(
    v_hh_id, 'transport:2026-09-01', (v_claim->>'lease_token')::uuid,
    v_claim->>'deterministic_event_id', 'etag-1', false
  );

  -- This mirrors the accepted canonical assignment update. It must reuse the
  -- same provider id (PATCH target), rather than create a second event.
  update public.task_instances set planned_assignee_id = v_partner where id = v_dropoff_task;
  v_second_claim := public.server_tx_claim_family_ops_calendar_mirror('sql-30-b', 120);
  if v_second_claim->>'provider_event_id' <> v_claim->>'deterministic_event_id'
     or v_second_claim #>> '{event,summary}' <> '送M迎M' then
    raise exception 'FAIL family-google-outbox: accepted reassignment must PATCH the stable daily provider id, got %', v_second_claim;
  end if;
  perform public.server_tx_complete_family_ops_calendar_mirror(
    v_hh_id, 'transport:2026-09-01', (v_second_claim->>'lease_token')::uuid,
    v_second_claim->>'provider_event_id', 'etag-2', false
  );

  update public.task_instances set planned_assignee_id = null where id in (v_dropoff_task, v_pickup_task);
  v_second_claim := public.server_tx_claim_family_ops_calendar_mirror('sql-30-c', 120);
  if v_second_claim->>'action' <> 'delete' then
    raise exception 'FAIL family-google-outbox: both transport assignees absent must delete/not create the daily event';
  end if;
  perform public.server_tx_complete_family_ops_calendar_mirror(
    v_hh_id, 'transport:2026-09-01', (v_second_claim->>'lease_token')::uuid,
    v_second_claim->>'provider_event_id', null, true
  );

  insert into public.task_instances
    (household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
     completion_mode, status, source, created_by)
  values (v_hh_id, v_special, 'manual', '皮膚科', 'medical', 'anytime', v_local_date,
          'whole', 'todo', 'test', v_owner)
  returning id into v_special_task;
  v_special_claim := public.server_tx_claim_family_ops_calendar_mirror('sql-30-special', 120);
  if v_special_claim->>'action' <> 'upsert'
     or v_special_claim #>> '{event,summary}' <> '皮膚科'
     or v_special_claim #>> '{event,start,date}' <> '2026-09-01'
     or v_special_claim #>> '{event,transparency}' <> 'transparent' then
    raise exception 'FAIL family-google-outbox: untimed special must be transparent all-day, got %', v_special_claim;
  end if;
  perform public.server_tx_complete_family_ops_calendar_mirror(
    v_hh_id, 'special:' || v_special_task::text, (v_special_claim->>'lease_token')::uuid,
    v_special_claim->>'deterministic_event_id', 'etag-special', false
  );

  -- The inbound occurrence marker comes from the provider id mapping only;
  -- a title does not participate in classification or dedupe.
  insert into public.calendar_event_occurrences
    (household_id, calendar_connection_id, occurrence_key, google_event_id, title,
     all_day_start, all_day_end_exclusive, status, transparency, projection_window_start, projection_window_end)
  values (v_hh_id, v_calendar_conn, 'event:family-special-30', v_special_claim->>'deterministic_event_id', '別の表示名でもよい',
          v_local_date, v_local_date + 1, 'confirmed', 'transparent', v_local_date, v_local_date + 60);
  if not (select family_ops_mirror from public.calendar_event_occurrences where occurrence_key = 'event:family-special-30') then
    raise exception 'FAIL family-google-outbox: inbound mirror must be identified by stable provider id';
  end if;
end;
$$;

reset role;
select '30_family_ops_google_outbox: PASS' as result;
