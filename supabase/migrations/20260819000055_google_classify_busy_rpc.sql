-- WP7E: classify-calendar-busy-members — manual busy classification.
-- docs/design/v6/07_GOOGLE_CALENDAR.md #8 "Manual busy classification
-- persistence", #9 "Direct Google-created event ... PWA may later allow
-- manual classification". User-facing mutation: full server_tx_* pattern
-- (claim-then-fill mutation_receipts, cross-household validation).
--
-- subject_event_id/original_start_time_key follow #7A's
-- classificationSubjectId (recurringEventId ?? event.id): the caller passes
-- the *series* id for a whole-series default (original_start_time_key
-- null) or a specific occurrence's key for a one-off override.

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
  if p_busy_scope = 'unknown' and p_member_user_ids is not null and array_length(p_member_user_ids, 1) > 0 then
    raise exception 'INVALID_INPUT';
  end if;
  if p_busy_scope <> 'unknown' and (p_member_user_ids is null or array_length(p_member_user_ids, 1) = 0) then
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

  if not exists (
    select 1 from public.calendar_connections
    where id = p_calendar_connection_id and household_id = v_household_id
  ) then
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
      select occurrence_key from public.calendar_event_occurrences
      where calendar_connection_id = p_calendar_connection_id
        and (google_event_id = p_subject_event_id or recurring_event_id = p_subject_event_id)
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
