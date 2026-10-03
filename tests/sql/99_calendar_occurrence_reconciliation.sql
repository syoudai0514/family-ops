-- A rolling projection must reconcile when its day boundaries change, and
-- manual classifications (including unknown) must keep precedence over defaults.
\set ON_ERROR_STOP on
begin;

insert into auth.users (id) values
  ('99000000-0000-0000-0000-000000000071'),
  ('99000000-0000-0000-0000-000000000072');
set role service_role;

do $$
declare
  v_owner uuid := '99000000-0000-0000-0000-000000000071';
  v_partner uuid := '99000000-0000-0000-0000-000000000072';
  v_household uuid;
  v_google_connection uuid;
  v_connection uuid;
  v_other_connection uuid;
  v_instances jsonb;
  v_result jsonb;
begin
  v_household := (public.server_tx_create_household(v_owner, gen_random_uuid(), 'Calendar reconcile', 'Owner')->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role)
  values (v_household, v_partner, 'adult');
  insert into private.google_connections
    (household_id, owner_user_id, google_subject, encrypted_refresh_token, encryption_version, scopes, status)
  values (v_household, v_owner, 'reconcile-fixture', 'cipher', 1, array['https://www.googleapis.com/auth/calendar.events'], 'active')
  returning id into v_google_connection;
  insert into public.calendar_connections
    (household_id, external_calendar_id, google_connection_id)
  values (v_household, 'reconcile-fixture@group.calendar.google.com', v_google_connection)
  returning id into v_connection;
  insert into public.calendar_connections
    (household_id, external_calendar_id, google_connection_id)
  values (v_household, 'other-reconcile-fixture@group.calendar.google.com', v_google_connection)
  returning id into v_other_connection;

  v_instances := jsonb_build_array(
    jsonb_build_object('id', 'cancelled-later', 'summary', 'Cancelled after midnight',
      'start', jsonb_build_object('dateTime', '2026-10-05T09:00:00+09:00'),
      'end', jsonb_build_object('dateTime', '2026-10-05T10:00:00+09:00'),
      'extendedProperties', jsonb_build_object('private', jsonb_build_object('familyOpsBusyMemberIds', v_owner::text))),
    jsonb_build_object('id', 'expired-history',
      'start', jsonb_build_object('date', '2026-09-26'), 'end', jsonb_build_object('date', '2026-09-27')),
    jsonb_build_object('id', 'moved-instance', 'recurringEventId', 'rolling-series',
      'originalStartTime', jsonb_build_object('dateTime', '2026-10-06T09:00:00+09:00'),
      'start', jsonb_build_object('dateTime', '2026-10-06T09:00:00+09:00'),
      'end', jsonb_build_object('dateTime', '2026-10-06T10:00:00+09:00'))
  );
  perform public.server_tx_rebuild_google_occurrence_projection(v_connection, date '2026-09-26', date '2026-12-02', v_instances);
  perform public.server_tx_rebuild_google_occurrence_projection(v_other_connection, date '2026-09-26', date '2026-12-02', v_instances);

  -- The next complete page set omits the deleted event and expired history.
  -- A moved recurring instance retains its original-start occurrence identity.
  v_result := public.server_tx_rebuild_google_occurrence_projection(v_connection, date '2026-09-27', date '2026-12-03',
    jsonb_build_array(jsonb_build_object('id', 'moved-instance', 'recurringEventId', 'rolling-series',
      'originalStartTime', jsonb_build_object('dateTime', '2026-10-06T09:00:00+09:00'),
      'start', jsonb_build_object('dateTime', '2026-10-07T11:00:00+09:00'),
      'end', jsonb_build_object('dateTime', '2026-10-07T12:00:00+09:00'))));
  if (v_result->>'pruned_occurrences')::int <> 2
     or (select count(*) from public.calendar_event_occurrences where calendar_connection_id = v_connection) <> 1
     or exists (select 1 from public.calendar_occurrence_busy_members where calendar_connection_id = v_connection) then
    raise exception 'FAIL calendar reconciliation: shifted rolling window retained omitted occurrences or busy rows';
  end if;
  if (select starts_at from public.calendar_event_occurrences where calendar_connection_id = v_connection)
       is distinct from timestamptz '2026-10-07T11:00:00+09:00' then
    raise exception 'FAIL calendar reconciliation: moved recurrence did not update its stable identity';
  end if;
  if (select count(*) from public.calendar_event_occurrences where calendar_connection_id = v_other_connection) <> 3 then
    raise exception 'FAIL calendar reconciliation: rebuild affected another calendar connection';
  end if;

  -- A slow previous-day worker may arrive after the new snapshot. It cannot
  -- remove the newer moved event or resurrect omitted events.
  v_result := public.server_tx_rebuild_google_occurrence_projection(v_connection, date '2026-09-26', date '2026-12-02', v_instances);
  if v_result->>'skipped_stale_window' is distinct from 'true'
     or (select count(*) from public.calendar_event_occurrences where calendar_connection_id = v_connection) <> 1
     or (select starts_at from public.calendar_event_occurrences where calendar_connection_id = v_connection)
          is distinct from timestamptz '2026-10-07T11:00:00+09:00' then
    raise exception 'FAIL calendar reconciliation: old-window worker replaced a newer projection';
  end if;

  -- Three recurring instances let us test nonempty and empty exact overrides,
  -- together with a default that is updated after those overrides exist.
  v_instances := '[]'::jsonb;
  for i in 8..10 loop
    v_instances := v_instances || jsonb_build_array(jsonb_build_object('id', 'busy-' || i, 'recurringEventId', 'busy-series',
      'originalStartTime', jsonb_build_object('date', '2026-10-' || lpad(i::text, 2, '0')),
      'start', jsonb_build_object('date', '2026-10-' || lpad(i::text, 2, '0')),
      'end', jsonb_build_object('date', '2026-10-' || lpad((i + 1)::text, 2, '0')),
      'extendedProperties', jsonb_build_object('private', jsonb_build_object('familyOpsBusyMemberIds', v_owner::text))));
  end loop;
  perform public.server_tx_rebuild_google_occurrence_projection(v_connection, date '2026-09-27', date '2026-12-03', v_instances);
  perform public.server_tx_classify_calendar_busy(v_owner, gen_random_uuid(), v_connection, 'busy-series', null, 'self', array[v_owner]);
  perform public.server_tx_classify_calendar_busy(v_owner, gen_random_uuid(), v_connection, 'busy-series', 'date:2026-10-08', 'unknown', array[]::uuid[]);
  perform public.server_tx_classify_calendar_busy(v_owner, gen_random_uuid(), v_connection, 'busy-series', 'date:2026-10-09', 'partner', array[v_partner]);
  perform public.server_tx_classify_calendar_busy(v_owner, gen_random_uuid(), v_connection, 'busy-series', null, 'family', array[v_owner, v_partner]);
  if exists (select 1 from public.calendar_occurrence_busy_members where calendar_connection_id = v_connection and occurrence_key = 'rec:busy-series:date:2026-10-08')
     or (select array_agg(user_id) from public.calendar_occurrence_busy_members where calendar_connection_id = v_connection and occurrence_key = 'rec:busy-series:date:2026-10-09') is distinct from array[v_partner]
     or (select count(*) from public.calendar_occurrence_busy_members where calendar_connection_id = v_connection and occurrence_key = 'rec:busy-series:date:2026-10-10') <> 2 then
    raise exception 'FAIL calendar reconciliation: series change overrode immediate occurrence classifications';
  end if;

  perform public.server_tx_rebuild_google_occurrence_projection(v_connection, date '2026-09-27', date '2026-12-03', v_instances);
  if exists (select 1 from public.calendar_occurrence_busy_members where calendar_connection_id = v_connection and occurrence_key = 'rec:busy-series:date:2026-10-08')
     or (select array_agg(user_id) from public.calendar_occurrence_busy_members where calendar_connection_id = v_connection and occurrence_key = 'rec:busy-series:date:2026-10-09') is distinct from array[v_partner] then
    raise exception 'FAIL calendar reconciliation: rebuild lost exact override precedence';
  end if;

  -- Unknown series defaults must also suppress provider busy metadata.
  perform public.server_tx_classify_calendar_busy(v_owner, gen_random_uuid(), v_connection, 'busy-series', null, 'unknown', null);
  perform public.server_tx_rebuild_google_occurrence_projection(v_connection, date '2026-09-27', date '2026-12-03', v_instances);
  if exists (select 1 from public.calendar_occurrence_busy_members where calendar_connection_id = v_connection and occurrence_key = 'rec:busy-series:date:2026-10-10')
     or (select array_agg(user_id) from public.calendar_occurrence_busy_members where calendar_connection_id = v_connection and occurrence_key = 'rec:busy-series:date:2026-10-09') is distinct from array[v_partner] then
    raise exception 'FAIL calendar reconciliation: unknown default fell through to metadata or overrode exact assignment';
  end if;

  begin
    perform public.server_tx_classify_calendar_busy(v_owner, gen_random_uuid(), v_connection, 'busy-series', null, 'self', array[]::uuid[]);
    raise exception 'FAIL calendar reconciliation: a known busy scope accepted an empty member list';
  exception when others then
    if sqlerrm <> 'INVALID_INPUT' then raise; end if;
  end;

  -- Empty authoritative result clears projections and busy rows but leaves
  -- classifications available if the series comes back into the window.
  perform public.server_tx_rebuild_google_occurrence_projection(v_connection, date '2026-09-28', date '2026-12-04', '[]'::jsonb);
  if exists (select 1 from public.calendar_event_occurrences where calendar_connection_id = v_connection)
     or exists (select 1 from public.calendar_occurrence_busy_members where calendar_connection_id = v_connection)
     or (select count(*) from public.calendar_busy_classifications where calendar_connection_id = v_connection) <> 3 then
    raise exception 'FAIL calendar reconciliation: empty rebuild retained active data or removed manual classifications';
  end if;

  -- The newest empty snapshot still establishes a window watermark.
  v_result := public.server_tx_rebuild_google_occurrence_projection(v_connection, date '2026-09-27', date '2026-12-03', v_instances);
  if v_result->>'skipped_stale_window' is distinct from 'true'
     or exists (select 1 from public.calendar_event_occurrences where calendar_connection_id = v_connection)
     or (select last_occurrence_projection_window_start from public.calendar_connections where id = v_connection) is distinct from date '2026-09-28' then
    raise exception 'FAIL calendar reconciliation: old-window worker repopulated an authoritative empty projection';
  end if;
end;
$$;

rollback;
select '99_calendar_occurrence_reconciliation: PASS' as result;
