-- Live 2026-09-30: one special task that could not be mirrored sat first in the Google
-- Calendar outbox, and the claim raised on it every minute -- nothing behind it was ever
-- mirrored. An invalid row is now parked (failed + reason + backoff) and the claim
-- returns the next valid row. A time without an end time is no longer invalid: it is
-- mirrored all day with the time in the title (owner decision, option A).
\set ON_ERROR_STOP on

begin;

insert into auth.users (id) values ('98000000-0000-0000-0000-000000000001');

set role service_role;

do $$
declare
  v_owner uuid := '98000000-0000-0000-0000-000000000001';
  v_hh_id uuid;
  v_google_conn uuid;
  v_calendar_conn uuid;
  v_special uuid;
  v_bad uuid;
  v_good uuid;
  v_claim jsonb;
  v_row record;
begin
  v_hh_id := (public.server_tx_create_household(v_owner, gen_random_uuid(), 'mirror skip', 'Primary')->>'household_id')::uuid;
  insert into private.google_connections
    (household_id, owner_user_id, google_subject, encrypted_refresh_token, encryption_version, scopes, status)
  values (v_hh_id, v_owner, 'google-98', 'cipher', 1, array['https://www.googleapis.com/auth/calendar.events'], 'active')
  returning id into v_google_conn;
  insert into public.calendar_connections
    (household_id, provider, external_calendar_id, google_connection_id, active, reauth_required)
  values (v_hh_id, 'google', 'skip-98@group.calendar.google.com', v_google_conn, true, false)
  returning id into v_calendar_conn;
  perform public.server_tx_set_family_calendar_target(v_owner, gen_random_uuid(), v_calendar_conn);
  delete from private.family_ops_calendar_mirrors where household_id = v_hh_id;

  insert into public.task_definitions
    (household_id, code, title, category, routine_phase, completion_mode, calendar_visibility, created_by)
  values (v_hh_id, 'special_98', '特別', 'todo', 'anytime', 'whole', 'special', v_owner)
  returning id into v_special;

  -- Invalid: the end is before the start.
  insert into public.task_instances
    (household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date, due_at,
     calendar_ends_at, completion_mode, status, source, created_by)
  values (v_hh_id, v_special, 'manual', '食育の準備', 'todo', 'anytime', date '2026-10-07',
          timestamptz '2026-10-07 08:00+09', timestamptz '2026-10-07 07:00+09', 'whole', 'todo', 'test', v_owner)
  returning id into v_bad;
  -- A valid one behind it.
  insert into public.task_instances
    (household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
     completion_mode, status, source, created_by)
  values (v_hh_id, v_special, 'manual', '皮膚科', 'medical', 'anytime', date '2026-10-08',
          'whole', 'todo', 'test', v_owner)
  returning id into v_good;

  -- Only these two are claimable, the invalid one first.
  update private.family_ops_calendar_mirrors set next_attempt_at = now() + interval '1 day'
  where not (household_id = v_hh_id and projection_key in ('special:' || v_bad::text, 'special:' || v_good::text));
  update private.family_ops_calendar_mirrors set next_attempt_at = now() - interval '1 hour'
  where household_id = v_hh_id and projection_key = 'special:' || v_bad::text;
  update private.family_ops_calendar_mirrors set next_attempt_at = now() - interval '1 minute'
  where household_id = v_hh_id and projection_key = 'special:' || v_good::text;

  v_claim := public.server_tx_claim_family_ops_calendar_mirror('sql-98', 120);
  if v_claim is null or v_claim->>'projection_key' <> 'special:' || v_good::text or v_claim #>> '{event,summary}' <> '皮膚科' then
    raise exception 'FAIL mirror-skip: the valid row behind the invalid one must be claimed, got %', v_claim;
  end if;

  select sync_state, last_error, lease_token, next_attempt_at into v_row
  from private.family_ops_calendar_mirrors where household_id = v_hh_id and projection_key = 'special:' || v_bad::text;
  if v_row.sync_state <> 'failed' or v_row.last_error <> 'INVALID_INPUT'
     or v_row.lease_token is not null or v_row.next_attempt_at <= now() then
    raise exception 'FAIL mirror-skip: the invalid row must be parked with its reason and a backoff, got %', row_to_json(v_row);
  end if;

  -- The rule itself is unchanged: no end time is invented. Nothing else is claimable now.
  perform public.server_tx_complete_family_ops_calendar_mirror(
    v_hh_id, 'special:' || v_good::text, (v_claim->>'lease_token')::uuid, v_claim->>'deterministic_event_id', 'etag-98', false);
  v_claim := public.server_tx_claim_family_ops_calendar_mirror('sql-98-b', 120);
  if v_claim is not null and v_claim->>'household_id' = v_hh_id::text then
    raise exception 'FAIL mirror-skip: a parked row must wait for its backoff, got %', v_claim;
  end if;

  -- The live shape -- a time, no end time -- goes through as an all-day event with the
  -- time in the title. No end time is invented.
  update public.task_instances set calendar_ends_at = null where id = v_bad;
  update private.family_ops_calendar_mirrors set next_attempt_at = now() - interval '1 second'
  where household_id = v_hh_id and projection_key = 'special:' || v_bad::text;
  v_claim := public.server_tx_claim_family_ops_calendar_mirror('sql-98-c', 120);
  if v_claim->>'projection_key' <> 'special:' || v_bad::text
     or v_claim #>> '{event,summary}' <> '8:00 食育の準備'
     or v_claim #>> '{event,start,date}' <> '2026-10-07'
     or v_claim #>> '{event,end,date}' <> '2026-10-08'
     or v_claim #>> '{event,start,dateTime}' is not null
     or v_claim #>> '{event,transparency}' <> 'transparent' then
    raise exception 'FAIL mirror-skip: a time without an end must be all day with the time in the title, got %', v_claim;
  end if;
  perform public.server_tx_complete_family_ops_calendar_mirror(
    v_hh_id, 'special:' || v_bad::text, (v_claim->>'lease_token')::uuid, v_claim->>'deterministic_event_id', 'etag-98c', false);

  -- With a real end time it is a timed event, as before.
  update public.task_instances set calendar_ends_at = timestamptz '2026-10-07 08:30+09', due_at = timestamptz '2026-10-07 08:00+09' where id = v_bad;
  update private.family_ops_calendar_mirrors set next_attempt_at = now() - interval '1 second'
  where household_id = v_hh_id and projection_key = 'special:' || v_bad::text;
  v_claim := public.server_tx_claim_family_ops_calendar_mirror('sql-98-d', 120);
  if v_claim #>> '{event,summary}' <> '食育の準備' or v_claim #>> '{event,end,dateTime}' is null then
    raise exception 'FAIL mirror-skip: a task with an end time stays a timed event, got %', v_claim;
  end if;
end $$;

rollback;
