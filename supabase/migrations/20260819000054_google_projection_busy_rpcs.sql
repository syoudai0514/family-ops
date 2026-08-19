-- WP7E: rolling occurrence projection (Google-expanded instances) + busy
-- member computation from Family-Ops metadata and manual classifications.
-- docs/design/v6/07_GOOGLE_CALENDAR.md #8 "Rolling occurrence projection",
-- #9 "Busy attribution". Service_role-only; called from process-google-sync
-- (periodic rebuild) and, for the immediate-feedback path, from
-- classify-calendar-busy-members (see server_tx_classify_calendar_busy in
-- 20260819000055).

-- Rebuilds calendar_event_occurrences + calendar_occurrence_busy_members for
-- one [p_window_start, p_window_end] rolling window from a full page-set of
-- Google singleEvents=true instances (p_instances: jsonb array of raw event
-- resources, already fully paginated by the caller — this call is one
-- all-at-once transaction, not incremental). Cancelled/deleted instances
-- (#8 "Cancelled/deleted instance never enters active projection") are
-- skipped entirely; the canonical tombstone/exception cache (WP7D) is what
-- carries delete semantics, not the projection.
create or replace function public.server_tx_rebuild_google_occurrence_projection(
  p_calendar_connection_id uuid,
  p_window_start date,
  p_window_end date,
  p_instances jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_upserted int := 0;
  v_pruned int := 0;
  v_busy_rebuilt int := 0;
begin
  if p_calendar_connection_id is null or p_window_start is null or p_window_end is null or p_instances is null then
    raise exception 'INVALID_INPUT';
  end if;
  if jsonb_typeof(p_instances) <> 'array' then
    raise exception 'INVALID_INPUT';
  end if;

  select household_id into v_household_id
  from public.calendar_connections
  where id = p_calendar_connection_id;

  if v_household_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  -- `if not exists` + explicit truncate (rather than a bare CREATE
  -- TEMPORARY ... ON COMMIT DROP) so this still works when called more than
  -- once inside the same transaction (e.g. a worker rebuilding several
  -- calendar connections' windows back to back, or these SQL tests) — a
  -- bare CREATE would raise "already exists" on the second call since ON
  -- COMMIT DROP only fires at actual transaction commit.
  create temporary table if not exists _touched_occurrences (occurrence_key text primary key) on commit drop;
  truncate _touched_occurrences;

  with parsed as (
    select
      i ->> 'id' as google_event_id,
      i ->> 'recurringEventId' as recurring_event_id,
      i -> 'originalStartTime' as original_start_time,
      i ->> 'summary' as title,
      case when i #> '{start,date}' is not null then null
           else (i #>> '{start,dateTime}')::timestamptz end as starts_at,
      case when i #> '{end,date}' is not null then null
           else (i #>> '{end,dateTime}')::timestamptz end as ends_at,
      (i #>> '{start,date}')::date as all_day_start,
      (i #>> '{end,date}')::date as all_day_end_exclusive,
      coalesce(i ->> 'status', 'confirmed') as status,
      i ->> 'transparency' as transparency,
      nullif(i ->> 'updated', '')::timestamptz as source_google_updated_at,
      i #>> '{extendedProperties,private,familyOpsBusyMemberIds}' as busy_member_ids_csv
    from jsonb_array_elements(p_instances) as i
    where i ->> 'id' is not null
  ),
  active as (
    select *, private.google_occurrence_key(google_event_id, recurring_event_id, original_start_time) as occurrence_key
    from parsed
    where status <> 'cancelled'
  ),
  ins as (
    insert into public.calendar_event_occurrences (
      household_id, calendar_connection_id, occurrence_key, google_event_id, recurring_event_id,
      title, starts_at, ends_at, all_day_start, all_day_end_exclusive, status,
      transparency, projection_window_start, projection_window_end, source_google_updated_at
    )
    select
      v_household_id, p_calendar_connection_id, a.occurrence_key, a.google_event_id, a.recurring_event_id,
      a.title, a.starts_at, a.ends_at, a.all_day_start, a.all_day_end_exclusive, a.status,
      a.transparency, p_window_start, p_window_end, a.source_google_updated_at
    from active a
    on conflict (calendar_connection_id, occurrence_key) do update set
      google_event_id = excluded.google_event_id,
      recurring_event_id = excluded.recurring_event_id,
      title = excluded.title,
      starts_at = excluded.starts_at,
      ends_at = excluded.ends_at,
      all_day_start = excluded.all_day_start,
      all_day_end_exclusive = excluded.all_day_end_exclusive,
      status = excluded.status,
      transparency = excluded.transparency,
      projection_window_start = excluded.projection_window_start,
      projection_window_end = excluded.projection_window_end,
      source_google_updated_at = excluded.source_google_updated_at
    returning occurrence_key
  )
  insert into _touched_occurrences select occurrence_key from ins;

  select count(*) into v_upserted from _touched_occurrences;

  -- Anything previously projected inside this exact window that this rebuild
  -- did not touch no longer occurs there (moved, cancelled, or exception).
  -- Busy-member rows for those occurrences are removed first (FK).
  delete from public.calendar_occurrence_busy_members m
  using public.calendar_event_occurrences o
  where m.calendar_connection_id = p_calendar_connection_id
    and m.occurrence_key = o.occurrence_key
    and o.calendar_connection_id = p_calendar_connection_id
    and o.projection_window_start = p_window_start
    and o.projection_window_end = p_window_end
    and not exists (select 1 from _touched_occurrences t where t.occurrence_key = o.occurrence_key);

  with pruned as (
    delete from public.calendar_event_occurrences o
    where o.calendar_connection_id = p_calendar_connection_id
      and o.projection_window_start = p_window_start
      and o.projection_window_end = p_window_end
      and not exists (select 1 from _touched_occurrences t where t.occurrence_key = o.occurrence_key)
    returning 1
  )
  select count(*) into v_pruned from pruned;

  -- Busy member rebuild, precedence order (#8 "Manual busy classification
  -- persistence"): 1) exact occurrence override, 2) event/series default,
  -- 3) Family Ops extended metadata, 4) unknown (no rows at all).
  delete from public.calendar_occurrence_busy_members m
  using _touched_occurrences t
  where m.calendar_connection_id = p_calendar_connection_id and m.occurrence_key = t.occurrence_key;

  with occ as (
    select o.occurrence_key, o.google_event_id, o.recurring_event_id,
           coalesce(o.recurring_event_id, o.google_event_id) as subject_event_id,
           private.google_original_start_time_key(
             (select i -> 'originalStartTime' from jsonb_array_elements(p_instances) i where i ->> 'id' = o.google_event_id limit 1)
           ) as original_start_time_key,
           (
             select i #>> '{extendedProperties,private,familyOpsBusyMemberIds}'
             from jsonb_array_elements(p_instances) i
             where i ->> 'id' = o.google_event_id
             limit 1
           ) as busy_member_ids_csv
    from public.calendar_event_occurrences o
    join _touched_occurrences t on t.occurrence_key = o.occurrence_key
    where o.calendar_connection_id = p_calendar_connection_id
  ),
  instance_override as (
    select occ.occurrence_key, bcm.user_id, 'manual'::text as source
    from occ
    join public.calendar_busy_classifications bc
      on bc.calendar_connection_id = p_calendar_connection_id
     and bc.subject_event_id = occ.subject_event_id
     and bc.original_start_time_key = occ.original_start_time_key
     and occ.original_start_time_key is not null
    join public.calendar_busy_classification_members bcm on bcm.classification_id = bc.id
  ),
  series_default as (
    select occ.occurrence_key, bcm.user_id, 'manual'::text as source
    from occ
    join public.calendar_busy_classifications bc
      on bc.calendar_connection_id = p_calendar_connection_id
     and bc.subject_event_id = occ.subject_event_id
     and bc.original_start_time_key is null
    join public.calendar_busy_classification_members bcm on bcm.classification_id = bc.id
    where not exists (select 1 from instance_override io where io.occurrence_key = occ.occurrence_key)
  ),
  metadata_default as (
    select occ.occurrence_key, hm.user_id, 'family_ops_metadata'::text as source
    from occ
    cross join lateral unnest(string_to_array(occ.busy_member_ids_csv, ',')) as raw_id
    join public.household_members hm
      on hm.household_id = v_household_id and hm.user_id::text = btrim(raw_id)
    where occ.busy_member_ids_csv is not null
      and not exists (select 1 from instance_override io where io.occurrence_key = occ.occurrence_key)
      and not exists (select 1 from series_default sd where sd.occurrence_key = occ.occurrence_key)
  ),
  combined as (
    select * from instance_override
    union all
    select * from series_default
    union all
    select * from metadata_default
  ),
  inserted as (
    insert into public.calendar_occurrence_busy_members (household_id, calendar_connection_id, occurrence_key, user_id, source)
    select v_household_id, p_calendar_connection_id, occurrence_key, user_id, source
    from combined
    on conflict (calendar_connection_id, occurrence_key, user_id) do update set source = excluded.source
    returning 1
  )
  select count(*) into v_busy_rebuilt from inserted;

  return jsonb_build_object(
    'upserted_occurrences', v_upserted,
    'pruned_occurrences', v_pruned,
    'busy_member_rows', v_busy_rebuilt
  );
end;
$$;

revoke all on function public.server_tx_rebuild_google_occurrence_projection(uuid, date, date, jsonb) from public;
revoke all on function public.server_tx_rebuild_google_occurrence_projection(uuid, date, date, jsonb) from anon;
revoke all on function public.server_tx_rebuild_google_occurrence_projection(uuid, date, date, jsonb) from authenticated;
grant execute on function public.server_tx_rebuild_google_occurrence_projection(uuid, date, date, jsonb) to service_role;
