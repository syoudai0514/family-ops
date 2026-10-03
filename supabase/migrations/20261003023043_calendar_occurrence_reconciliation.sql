-- Each Google occurrence projection is a fully paginated rolling snapshot.
-- Reconcile it across window changes and preserve manual classification
-- precedence both during rebuilds and immediate series-default updates.

-- Retain the last window even when its complete provider result is empty.
-- A delayed worker from the previous Tokyo day must not replace a newer one.
alter table public.calendar_connections
  add column last_occurrence_projection_window_start date;

update public.calendar_connections c
set last_occurrence_projection_window_start = (
  select max(o.projection_window_start)
  from public.calendar_event_occurrences o
  where o.calendar_connection_id = c.id
);

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
  v_previous_window_start date;
  v_upserted int := 0;
  v_pruned int := 0;
  v_busy_rebuilt int := 0;
begin
  if p_calendar_connection_id is null or p_window_start is null or p_window_end is null or p_instances is null then
    raise exception 'INVALID_INPUT';
  end if;
  if p_window_end <= p_window_start or jsonb_typeof(p_instances) <> 'array' then
    raise exception 'INVALID_INPUT';
  end if;

  -- Serialize snapshot replacement for each connection. Window freshness is
  -- checked under the same lock used to update its durable watermark below.
  select household_id, last_occurrence_projection_window_start
    into v_household_id, v_previous_window_start
  from public.calendar_connections
  where id = p_calendar_connection_id
  for update;

  if v_household_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  if p_window_start < v_previous_window_start then
    return jsonb_build_object(
      'upserted_occurrences', 0, 'pruned_occurrences', 0, 'busy_member_rows', 0,
      'skipped_stale_window', true
    );
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

  -- Every fully paginated rebuild is the authoritative rolling snapshot for
  -- this connection. Prune missing rows even if the previous window differed;
  -- otherwise cancelled/moved occurrences survive when the Tokyo day advances.
  -- Canonical event history and manual classifications live in separate tables.
  -- Busy-member rows for omitted occurrences are removed first (FK).
  delete from public.calendar_occurrence_busy_members m
  using public.calendar_event_occurrences o
  where m.calendar_connection_id = p_calendar_connection_id
    and m.occurrence_key = o.occurrence_key
    and o.calendar_connection_id = p_calendar_connection_id
    and not exists (select 1 from _touched_occurrences t where t.occurrence_key = o.occurrence_key);

  with pruned as (
    delete from public.calendar_event_occurrences o
    where o.calendar_connection_id = p_calendar_connection_id
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
  classified as (
    select occ.*, coalesce(instance_override.id, series_default.id) as classification_id
    from occ
    left join public.calendar_busy_classifications instance_override
      on instance_override.calendar_connection_id = p_calendar_connection_id
     and instance_override.subject_event_id = occ.subject_event_id
     and instance_override.original_start_time_key = occ.original_start_time_key
     and occ.original_start_time_key is not null
    left join public.calendar_busy_classifications series_default
      on series_default.calendar_connection_id = p_calendar_connection_id
     and series_default.subject_event_id = occ.subject_event_id
     and series_default.original_start_time_key is null
  ),
  manual_members as (
    -- Classification existence establishes precedence, even for 'unknown'
    -- (a deliberate override with no member rows).
    select occ.occurrence_key, bcm.user_id, 'manual'::text as source
    from classified occ
    join public.calendar_busy_classification_members bcm
      on bcm.classification_id = occ.classification_id
  ),
  metadata_default as (
    select occ.occurrence_key, hm.user_id, 'family_ops_metadata'::text as source
    from classified occ
    cross join lateral unnest(string_to_array(occ.busy_member_ids_csv, ',')) as raw_id
    join public.household_members hm
      on hm.household_id = v_household_id and hm.user_id::text = btrim(raw_id)
    where occ.busy_member_ids_csv is not null
      and occ.classification_id is null
  ),
  combined as (
    select * from manual_members
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

  update public.calendar_connections
  set last_occurrence_projection_window_start = p_window_start,
      last_occurrence_projection_at = now()
  where id = p_calendar_connection_id;

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

create or replace function public.server_tx_classify_calendar_busy(
  p_actor_id uuid,
  p_operation_id uuid,
  p_calendar_connection_id uuid,
  p_subject_event_id text,
  p_original_start_time_key text,
  p_busy_scope text,
  p_member_user_ids uuid[]
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_request_hash text;
  v_receipt record;
  v_classification_id uuid;
  v_member_id uuid;
  v_result jsonb;
  v_touched_key text;
begin
  if p_actor_id is null or p_operation_id is null or p_calendar_connection_id is null
     or p_subject_event_id is null or p_busy_scope is null then
    raise exception 'INVALID_INPUT';
  end if;
  if p_busy_scope not in ('self', 'partner', 'family', 'unknown') then
    raise exception 'INVALID_INPUT';
  end if;
  if p_busy_scope = 'unknown' and p_member_user_ids is not null and cardinality(p_member_user_ids) > 0 then
    raise exception 'INVALID_INPUT';
  end if;
  if p_busy_scope <> 'unknown' and (p_member_user_ids is null or cardinality(p_member_user_ids) = 0) then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to(
      'classify-calendar-busy|' || p_calendar_connection_id::text || '|' || p_subject_event_id
        || '|' || coalesce(p_original_start_time_key, '') || '|' || p_busy_scope
        || '|' || coalesce(array_to_string(array(select unnest(p_member_user_ids) order by 1), ','), ''),
      'UTF8'
    )),
    'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'classify-calendar-busy-members', v_request_hash)
    on conflict (actor_id, operation_id) do nothing;

    if found then
      exit;
    end if;

    select * into v_receipt
    from private.mutation_receipts
    where actor_id = p_actor_id and operation_id = p_operation_id
    for update;

    if found then
      if v_receipt.request_hash <> v_request_hash then
        raise exception 'IDEMPOTENCY_CONFLICT';
      end if;
      return v_receipt.result_payload;
    end if;
  end loop;

  select household_id into v_household_id
  from public.household_members
  where user_id = p_actor_id;

  if v_household_id is null then
    raise exception 'NOT_HOUSEHOLD_MEMBER';
  end if;

  -- The rebuild holds this same connection lock, so updating classifications
  -- and their immediate busy rows cannot interleave with snapshot replacement.
  perform 1 from public.calendar_connections
  where id = p_calendar_connection_id and household_id = v_household_id
  for update;
  if not found then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  if p_member_user_ids is not null then
    foreach v_member_id in array p_member_user_ids loop
      if not exists (
        select 1 from public.household_members
        where household_id = v_household_id and user_id = v_member_id
      ) then
        raise exception 'CROSS_HOUSEHOLD_RESOURCE';
      end if;
    end loop;
  end if;

  -- Two disjoint partial unique indexes (instance override vs series
  -- default) mean only one can ever be the correct ON CONFLICT arbiter for a
  -- given call; naming the wrong one for this row's null-ness would let a
  -- genuine duplicate on the *other* index raise a hard unique_violation
  -- instead of updating, so branch explicitly.
  if p_original_start_time_key is not null then
    insert into public.calendar_busy_classifications (
      household_id, calendar_connection_id, subject_event_id, original_start_time_key, busy_scope, created_by
    ) values (
      v_household_id, p_calendar_connection_id, p_subject_event_id, p_original_start_time_key, p_busy_scope, p_actor_id
    )
    on conflict (calendar_connection_id, subject_event_id, original_start_time_key)
      where original_start_time_key is not null
    do update set busy_scope = excluded.busy_scope, created_by = excluded.created_by
    returning id into v_classification_id;
  else
    insert into public.calendar_busy_classifications (
      household_id, calendar_connection_id, subject_event_id, original_start_time_key, busy_scope, created_by
    ) values (
      v_household_id, p_calendar_connection_id, p_subject_event_id, null, p_busy_scope, p_actor_id
    )
    on conflict (calendar_connection_id, subject_event_id)
      where original_start_time_key is null
    do update set busy_scope = excluded.busy_scope, created_by = excluded.created_by
    returning id into v_classification_id;
  end if;

  delete from public.calendar_busy_classification_members where classification_id = v_classification_id;

  if p_member_user_ids is not null then
    insert into public.calendar_busy_classification_members (classification_id, household_id, user_id)
    select v_classification_id, v_household_id, m
    from unnest(p_member_user_ids) as m;
  end if;

  -- Immediate feedback: reapply to whichever occurrence rows already exist
  -- for this subject so the UI reflects the new classification before the
  -- next projection rebuild.
  if p_original_start_time_key is not null then
    for v_touched_key in
      select occurrence_key from public.calendar_event_occurrences
      where calendar_connection_id = p_calendar_connection_id
        and (occurrence_key = 'rec:' || p_subject_event_id || ':' || p_original_start_time_key
             or occurrence_key = 'event:' || p_subject_event_id)
    loop
      delete from public.calendar_occurrence_busy_members
      where calendar_connection_id = p_calendar_connection_id and occurrence_key = v_touched_key;

      if p_member_user_ids is not null then
        insert into public.calendar_occurrence_busy_members (household_id, calendar_connection_id, occurrence_key, user_id, source)
        select v_household_id, p_calendar_connection_id, v_touched_key, m, 'manual'
        from unnest(p_member_user_ids) as m;
      end if;
    end loop;
  else
    for v_touched_key in
      select o.occurrence_key from public.calendar_event_occurrences o
      where o.calendar_connection_id = p_calendar_connection_id
        and (o.google_event_id = p_subject_event_id or o.recurring_event_id = p_subject_event_id)
        -- Updating the default must leave exact occurrence overrides intact,
        -- including explicit 'unknown' overrides without member rows.
        and not exists (
          select 1 from public.calendar_busy_classifications bc
          where bc.calendar_connection_id = p_calendar_connection_id
            and bc.subject_event_id = p_subject_event_id
            and bc.original_start_time_key is not null
            and o.occurrence_key = 'rec:' || p_subject_event_id || ':' || bc.original_start_time_key
        )
    loop
      delete from public.calendar_occurrence_busy_members
      where calendar_connection_id = p_calendar_connection_id and occurrence_key = v_touched_key;

      if p_member_user_ids is not null then
        insert into public.calendar_occurrence_busy_members (household_id, calendar_connection_id, occurrence_key, user_id, source)
        select v_household_id, p_calendar_connection_id, v_touched_key, m, 'manual'
        from unnest(p_member_user_ids) as m;
      end if;
    end loop;
  end if;

  v_result := jsonb_build_object(
    'classification_id', v_classification_id,
    'subject_event_id', p_subject_event_id,
    'original_start_time_key', p_original_start_time_key,
    'busy_scope', p_busy_scope
  );

  update private.mutation_receipts
  set result_type = 'calendar_busy_classification', result_id = v_classification_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_classify_calendar_busy(uuid, uuid, uuid, text, text, text, uuid[]) from public;
revoke all on function public.server_tx_classify_calendar_busy(uuid, uuid, uuid, text, text, text, uuid[]) from anon;
revoke all on function public.server_tx_classify_calendar_busy(uuid, uuid, uuid, text, text, text, uuid[]) from authenticated;
grant execute on function public.server_tx_classify_calendar_busy(uuid, uuid, uuid, text, text, text, uuid[]) to service_role;
