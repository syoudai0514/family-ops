-- WP7D: canonical incremental sync — staging + atomic commit, 410 recovery.
-- docs/design/v6/07_GOOGLE_CALENDAR.md #6 "Canonical incremental sync —
-- exact query contract", #7 "Deleted/cancelled/untitled resources",
-- #7A "Recurring occurrence identity".
-- All service_role-only; called from process-google-sync.

-- originalStartTimeKey / occurrenceKey / classificationSubjectId (#7A),
-- reused by both canonical-cache tombstoning here and by projection rebuild.
create or replace function private.google_original_start_time_key(p_original_start_time jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_original_start_time is null then null
    when p_original_start_time ? 'date' then 'date:' || (p_original_start_time ->> 'date')
    when p_original_start_time ? 'dateTime' then
      'datetime:' || to_char(
        (p_original_start_time ->> 'dateTime')::timestamptz at time zone 'UTC',
        'YYYY-MM-DD"T"HH24:MI:SS"Z"'
      )
    else null
  end;
$$;

create or replace function private.google_occurrence_key(p_event_id text, p_recurring_event_id text, p_original_start_time jsonb)
returns text
language sql
immutable
set search_path = ''
as $$
  select case
    when p_recurring_event_id is not null then
      'rec:' || p_recurring_event_id || ':' || coalesce(private.google_original_start_time_key(p_original_start_time), 'unknown')
    else
      'event:' || p_event_id
  end;
$$;

revoke all on function private.google_original_start_time_key(jsonb) from public;
revoke all on function private.google_original_start_time_key(jsonb) from anon;
revoke all on function private.google_original_start_time_key(jsonb) from authenticated;
grant execute on function private.google_original_start_time_key(jsonb) to service_role;

revoke all on function private.google_occurrence_key(text, text, jsonb) from public;
revoke all on function private.google_occurrence_key(text, text, jsonb) from anon;
revoke all on function private.google_occurrence_key(text, text, jsonb) from authenticated;
grant execute on function private.google_occurrence_key(text, text, jsonb) to service_role;

-- Bulk stage a page of raw Google event resources for a sync_run_id.
-- PK (sync_run_id, google_event_id) makes re-staging the same id within one
-- run a deterministic upsert (#6 "duplicate same id is deterministic
-- upsert"). Never touches live cache/token state.
create or replace function public.server_tx_stage_google_events(
  p_calendar_connection_id uuid,
  p_sync_run_id uuid,
  p_events jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_count int := 0;
begin
  if p_calendar_connection_id is null or p_sync_run_id is null or p_events is null then
    raise exception 'INVALID_INPUT';
  end if;
  if jsonb_typeof(p_events) <> 'array' then
    raise exception 'INVALID_INPUT';
  end if;

  insert into private.google_event_staging (sync_run_id, calendar_connection_id, google_event_id, event_json, received_at)
  select p_sync_run_id, p_calendar_connection_id, e ->> 'id', e, now()
  from jsonb_array_elements(p_events) as e
  where e ->> 'id' is not null
  on conflict (sync_run_id, google_event_id) do update
    set event_json = excluded.event_json, received_at = excluded.received_at;

  get diagnostics v_count = row_count;
  return jsonb_build_object('staged_count', v_count);
end;
$$;

revoke all on function public.server_tx_stage_google_events(uuid, uuid, jsonb) from public;
revoke all on function public.server_tx_stage_google_events(uuid, uuid, jsonb) from anon;
revoke all on function public.server_tx_stage_google_events(uuid, uuid, jsonb) from authenticated;
grant execute on function public.server_tx_stage_google_events(uuid, uuid, jsonb) to service_role;

-- Final-page-only atomic reconcile: after ALL pages of a sync run staged
-- successfully (incremental or 410-triggered full resync), this is the one
-- transaction that (a) upserts canonical cache rows from staging, (b) for a
-- full resync tombstones any previously-live cache row absent from the new
-- staged set (Google's own showDeleted=true page already carries explicit
-- tombstones for anything still within its retention window; this is the
-- belt-and-suspenders path for rows that fell out of that window), (c)
-- stores the new nextSyncToken, and (d) deletes this run's staging rows.
-- A page-2+ failure before this is ever called leaves live cache/token
-- state completely untouched (#6 step 4).
create or replace function public.server_tx_commit_google_sync(
  p_calendar_connection_id uuid,
  p_sync_run_id uuid,
  p_next_sync_token text,
  p_is_full_resync boolean
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_upserted int := 0;
  v_implicit_deleted int := 0;
begin
  if p_calendar_connection_id is null or p_sync_run_id is null or p_next_sync_token is null then
    raise exception 'INVALID_INPUT';
  end if;

  select household_id into v_household_id
  from public.calendar_connections
  where id = p_calendar_connection_id;

  if v_household_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  with parsed as (
    select
      s.google_event_id,
      s.event_json ->> 'recurringEventId' as recurring_event_id,
      s.event_json -> 'originalStartTime' as original_start_time,
      s.event_json ->> 'summary' as title,
      s.event_json ->> 'description' as description,
      s.event_json ->> 'location' as location,
      case when s.event_json #> '{start,date}' is not null then null
           else (s.event_json #>> '{start,dateTime}')::timestamptz end as starts_at,
      case when s.event_json #> '{end,date}' is not null then null
           else (s.event_json #>> '{end,dateTime}')::timestamptz end as ends_at,
      (s.event_json #>> '{start,date}')::date as all_day_start,
      (s.event_json #>> '{end,date}')::date as all_day_end_exclusive,
      coalesce(s.event_json ->> 'status', 'confirmed') as status,
      s.event_json -> 'recurrence' as recurrence,
      s.event_json #>> '{creator,email}' as creator_external_id,
      s.event_json #>> '{organizer,email}' as organizer_external_id,
      s.event_json ->> 'transparency' as transparency,
      nullif(s.event_json ->> 'updated', '')::timestamptz as google_updated_at,
      s.event_json ->> 'etag' as etag
    from private.google_event_staging s
    where s.sync_run_id = p_sync_run_id and s.calendar_connection_id = p_calendar_connection_id
  ),
  upsert as (
    insert into public.calendar_events_cache (
      household_id, calendar_connection_id, google_event_id, recurring_event_id,
      original_start_time, title, description, location, starts_at, ends_at,
      all_day_start, all_day_end_exclusive, status, recurrence,
      creator_external_id, organizer_external_id, transparency,
      google_updated_at, etag, tombstone_kind
    )
    select
      v_household_id, p_calendar_connection_id, p.google_event_id, p.recurring_event_id,
      p.original_start_time, p.title, p.description, p.location, p.starts_at, p.ends_at,
      p.all_day_start, p.all_day_end_exclusive, p.status, p.recurrence,
      p.creator_external_id, p.organizer_external_id, p.transparency,
      p.google_updated_at, p.etag,
      case
        when p.status = 'cancelled' and p.recurring_event_id is not null then 'cancelled_exception'
        when p.status = 'cancelled' then 'deleted'
        else null
      end
    from parsed p
    on conflict (calendar_connection_id, google_event_id) do update set
      recurring_event_id = excluded.recurring_event_id,
      original_start_time = excluded.original_start_time,
      title = excluded.title,
      description = excluded.description,
      location = excluded.location,
      starts_at = excluded.starts_at,
      ends_at = excluded.ends_at,
      all_day_start = excluded.all_day_start,
      all_day_end_exclusive = excluded.all_day_end_exclusive,
      status = excluded.status,
      recurrence = excluded.recurrence,
      creator_external_id = excluded.creator_external_id,
      organizer_external_id = excluded.organizer_external_id,
      transparency = excluded.transparency,
      google_updated_at = excluded.google_updated_at,
      etag = excluded.etag,
      tombstone_kind = excluded.tombstone_kind
    returning 1
  )
  select count(*) into v_upserted from upsert;

  if p_is_full_resync then
    with implicit as (
      update public.calendar_events_cache c
      set status = 'cancelled', tombstone_kind = coalesce(c.tombstone_kind, 'deleted')
      where c.calendar_connection_id = p_calendar_connection_id
        and c.tombstone_kind is null
        and not exists (
          select 1 from private.google_event_staging s
          where s.sync_run_id = p_sync_run_id and s.calendar_connection_id = p_calendar_connection_id
            and s.google_event_id = c.google_event_id
        )
      returning 1
    )
    select count(*) into v_implicit_deleted from implicit;
  end if;

  insert into private.google_sync_state (calendar_connection_id, next_sync_token, last_success_at, last_full_sync_at, last_error)
  values (p_calendar_connection_id, p_next_sync_token, now(), case when p_is_full_resync then now() else null end, null)
  on conflict (calendar_connection_id) do update set
    next_sync_token = excluded.next_sync_token,
    last_success_at = now(),
    last_full_sync_at = case when p_is_full_resync then now() else private.google_sync_state.last_full_sync_at end,
    last_error = null;

  update public.calendar_connections
  set last_incremental_sync_at = now()
  where id = p_calendar_connection_id;

  delete from private.google_event_staging
  where sync_run_id = p_sync_run_id and calendar_connection_id = p_calendar_connection_id;

  return jsonb_build_object('upserted_count', v_upserted, 'implicit_deleted_count', v_implicit_deleted);
end;
$$;

revoke all on function public.server_tx_commit_google_sync(uuid, uuid, text, boolean) from public;
revoke all on function public.server_tx_commit_google_sync(uuid, uuid, text, boolean) from anon;
revoke all on function public.server_tx_commit_google_sync(uuid, uuid, text, boolean) from authenticated;
grant execute on function public.server_tx_commit_google_sync(uuid, uuid, text, boolean) to service_role;

-- 410 Gone: clears the stored syncToken so the next process-google-sync run
-- performs a fresh Initial full sync (#6 "410 Gone" step 2), and records the
-- reason for observability. Live cache is left untouched until that full
-- resync's own commit call.
create or replace function public.server_tx_invalidate_google_sync_token(
  p_calendar_connection_id uuid,
  p_reason text
)
returns void
language sql
security invoker
set search_path = ''
as $$
  insert into private.google_sync_state (calendar_connection_id, next_sync_token, last_error)
  values (p_calendar_connection_id, null, coalesce(p_reason, '410 Gone'))
  on conflict (calendar_connection_id) do update set
    next_sync_token = null,
    last_error = coalesce(p_reason, '410 Gone');
$$;

revoke all on function public.server_tx_invalidate_google_sync_token(uuid, text) from public;
revoke all on function public.server_tx_invalidate_google_sync_token(uuid, text) from anon;
revoke all on function public.server_tx_invalidate_google_sync_token(uuid, text) from authenticated;
grant execute on function public.server_tx_invalidate_google_sync_token(uuid, text) to service_role;

-- Abandoned staging TTL=24h (#6 step 7): a sync run that crashed before ever
-- reaching commit leaves orphaned staging rows; sweep them periodically.
create or replace function public.server_tx_cleanup_abandoned_google_staging(p_ttl_hours int default 24)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  with deleted as (
    delete from private.google_event_staging
    where received_at < now() - make_interval(hours => coalesce(p_ttl_hours, 24))
    returning 1
  )
  select jsonb_build_object('deleted_count', count(*)) from deleted;
$$;

revoke all on function public.server_tx_cleanup_abandoned_google_staging(int) from public;
revoke all on function public.server_tx_cleanup_abandoned_google_staging(int) from anon;
revoke all on function public.server_tx_cleanup_abandoned_google_staging(int) from authenticated;
grant execute on function public.server_tx_cleanup_abandoned_google_staging(int) to service_role;
