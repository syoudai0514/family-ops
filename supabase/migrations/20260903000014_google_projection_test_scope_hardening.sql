-- WP-DD3A source-review HIGH remediation: production Google projection must be
-- physically unable to consume test-scoped Tasks, including AFTER DELETE where
-- the source row no longer exists. This is defense in depth: trigger entry keeps
-- OLD/NEW scope, and every production projector scan independently filters test.

-- HIGH-1: preserve scope at trigger entry; never infer DELETE scope by looking
-- up an already-deleted row.
create or replace function private.fn_enqueue_family_ops_calendar_task()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    if old.test_context_id is not null then
      return old;
    end if;
    perform private.enqueue_family_ops_calendar_projection(
      old.household_id, old.task_definition_id, old.scheduled_date, old.id
    );
    return old;
  end if;

  if new.test_context_id is not null then
    return new;
  end if;

  if tg_op = 'UPDATE' and old.scheduled_date is distinct from new.scheduled_date then
    -- test_context_id is immutable, so NEW production implies OLD production.
    perform private.enqueue_family_ops_calendar_projection(
      old.household_id, old.task_definition_id, old.scheduled_date, old.id
    );
  end if;

  perform private.enqueue_family_ops_calendar_projection(
    new.household_id, new.task_definition_id, new.scheduled_date, new.id
  );
  return new;
end;
$$;

revoke all on function private.fn_enqueue_family_ops_calendar_task()
  from public, anon, authenticated;
grant execute on function private.fn_enqueue_family_ops_calendar_task()
  to service_role;

-- HIGH-2: replace the frozen production implementation so its own scans cannot
-- read test Tasks even when invoked by a production Task mutation/reconcile.
create or replace function private.enqueue_family_ops_calendar_projection_legacy_v1(
  p_household_id uuid,
  p_task_definition_id uuid,
  p_local_date date,
  p_task_instance_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_visibility text;
  v_connection_id uuid;
  v_projection_key text;
  v_kind text;
  v_desired_action text := 'upsert';
begin
  if p_household_id is null or p_local_date is null then return; end if;

  if p_task_definition_id is not null then
    select calendar_visibility into v_visibility
    from public.task_definitions
    where household_id = p_household_id and id = p_task_definition_id;
  else
    select calendar_visibility into v_visibility
    from public.task_instances
    where household_id = p_household_id
      and id = p_task_instance_id
      and test_context_id is null;
  end if;
  if coalesce(v_visibility, 'hidden') = 'hidden' then return; end if;

  select id into v_connection_id
  from public.calendar_connections
  where household_id = p_household_id
    and is_family_write_target and active and not reauth_required
  order by created_at, id
  limit 1;
  if v_connection_id is null then return; end if;

  if v_visibility = 'transport' then
    v_kind := 'transport';
    v_projection_key := 'transport:' || p_local_date::text;
    if not exists (
      select 1
      from public.task_instances ti
      join public.task_definitions td
        on td.household_id = ti.household_id and td.id = ti.task_definition_id
      where ti.household_id = p_household_id
        and ti.test_context_id is null
        and ti.scheduled_date = p_local_date
        and ti.status <> 'cancelled'
        and td.calendar_visibility = 'transport'
        and ti.planned_assignee_id is not null
    ) then
      v_desired_action := 'delete';
    end if;
  else
    v_kind := 'special';
    v_projection_key := 'special:' || p_task_instance_id::text;
    if not exists (
      select 1 from public.task_instances
      where household_id = p_household_id
        and id = p_task_instance_id
        and test_context_id is null
        and status <> 'cancelled'
        and calendar_visibility = 'special'
    ) then
      v_desired_action := 'delete';
    end if;
  end if;

  insert into private.family_ops_calendar_mirrors (
    household_id, projection_key, kind, local_date, task_instance_id,
    calendar_connection_id, desired_action, sync_state, attempts,
    next_attempt_at, lease_token, lease_until, last_error
  ) values (
    p_household_id, v_projection_key, v_kind, p_local_date,
    case when v_kind = 'special' then p_task_instance_id else null end,
    v_connection_id, v_desired_action, 'pending', 0, now(), null, null, null
  )
  on conflict (household_id, projection_key) do update
  set calendar_connection_id = excluded.calendar_connection_id,
      kind = excluded.kind,
      local_date = excluded.local_date,
      task_instance_id = excluded.task_instance_id,
      desired_action = excluded.desired_action,
      sync_state = 'pending', attempts = 0, next_attempt_at = now(),
      lease_token = null, lease_until = null, last_error = null,
      updated_at = now();
end;
$$;

revoke all on function private.enqueue_family_ops_calendar_projection_legacy_v1(uuid, uuid, date, uuid)
  from public, anon, authenticated, service_role;

-- Reconciliation is a production projection enumerator. Test rows are not even
-- candidates and therefore cannot indirectly enqueue/delete provider state.
create or replace function public.server_tx_reconcile_family_ops_calendar(
  p_household_id uuid,
  p_start_date date default (now() at time zone 'Asia/Tokyo')::date,
  p_end_date date default ((now() at time zone 'Asia/Tokyo')::date + 60)
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_task record;
  v_count integer := 0;
begin
  if p_household_id is null or p_start_date is null or p_end_date is null or p_end_date < p_start_date then
    raise exception 'INVALID_INPUT';
  end if;

  for v_task in
    select id, household_id, task_definition_id, scheduled_date
    from public.task_instances
    where household_id = p_household_id
      and test_context_id is null
      and scheduled_date between p_start_date and p_end_date
      and calendar_visibility in ('transport', 'special')
  loop
    perform private.enqueue_family_ops_calendar_projection(
      v_task.household_id, v_task.task_definition_id, v_task.scheduled_date, v_task.id
    );
    v_count := v_count + 1;
  end loop;

  return jsonb_build_object('queued_task_count', v_count);
end;
$$;

revoke all on function public.server_tx_reconcile_family_ops_calendar(uuid, date, date)
  from public, anon, authenticated;
grant execute on function public.server_tx_reconcile_family_ops_calendar(uuid, date, date)
  to service_role;

-- Worker materialization re-reads canonical Tasks. Those reads are also
-- production-only; this prevents a queued production transport mirror from
-- being influenced by a same-day test Task with a real-user compatibility ID.
create or replace function public.server_tx_claim_family_ops_calendar_mirror(
  p_worker_id text,
  p_lease_seconds integer default 120
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_mirror private.family_ops_calendar_mirrors%rowtype;
  v_lease uuid := gen_random_uuid();
  v_dropoff uuid;
  v_pickup uuid;
  v_task public.task_instances%rowtype;
  v_title text;
  v_payload jsonb;
  v_event_id text;
begin
  if coalesce(p_worker_id, '') = '' then raise exception 'INVALID_INPUT'; end if;

  select * into v_mirror
  from private.family_ops_calendar_mirrors
  where (sync_state in ('pending', 'failed') and next_attempt_at <= now())
     or (sync_state = 'processing' and lease_until < now())
  order by next_attempt_at, updated_at
  for update skip locked
  limit 1;
  if not found then return null; end if;

  update private.family_ops_calendar_mirrors
  set sync_state = 'processing', lease_token = v_lease,
      lease_until = now() + make_interval(secs => greatest(coalesce(p_lease_seconds, 120), 30)),
      attempts = attempts + 1, updated_at = now()
  where household_id = v_mirror.household_id and projection_key = v_mirror.projection_key
  returning * into v_mirror;

  v_event_id := coalesce(v_mirror.provider_event_id,
    'fo' || substr(md5(v_mirror.household_id::text || ':' || v_mirror.projection_key), 1, 32));

  if v_mirror.desired_action = 'delete' then
    return jsonb_build_object(
      'household_id', v_mirror.household_id, 'projection_key', v_mirror.projection_key,
      'calendar_connection_id', v_mirror.calendar_connection_id, 'lease_token', v_lease,
      'action', 'delete', 'provider_event_id', v_mirror.provider_event_id,
      'deterministic_event_id', v_event_id
    );
  end if;

  if v_mirror.kind = 'transport' then
    select ti.planned_assignee_id into v_dropoff
    from public.task_instances ti
    join public.task_definitions td
      on td.household_id = ti.household_id and td.id = ti.task_definition_id
    where ti.household_id = v_mirror.household_id
      and ti.test_context_id is null
      and ti.scheduled_date = v_mirror.local_date
      and ti.status <> 'cancelled'
      and td.code = 'dropoff'
    order by ti.updated_at desc, ti.id desc
    limit 1;

    select ti.planned_assignee_id into v_pickup
    from public.task_instances ti
    join public.task_definitions td
      on td.household_id = ti.household_id and td.id = ti.task_definition_id
    where ti.household_id = v_mirror.household_id
      and ti.test_context_id is null
      and ti.scheduled_date = v_mirror.local_date
      and ti.status <> 'cancelled'
      and td.code = 'pickup'
    order by ti.updated_at desc, ti.id desc
    limit 1;

    if v_dropoff is null and v_pickup is null then
      return jsonb_build_object(
        'household_id', v_mirror.household_id, 'projection_key', v_mirror.projection_key,
        'calendar_connection_id', v_mirror.calendar_connection_id, 'lease_token', v_lease,
        'action', 'delete', 'provider_event_id', v_mirror.provider_event_id,
        'deterministic_event_id', v_event_id
      );
    end if;

    v_title := '送 ' || coalesce(private.family_ops_member_token(v_mirror.household_id, v_dropoff), '未定')
      || ' ｜ 迎 ' || coalesce(private.family_ops_member_token(v_mirror.household_id, v_pickup), '未定');
    v_payload := jsonb_build_object(
      'id', v_event_id, 'summary', v_title,
      'start', jsonb_build_object('date', v_mirror.local_date::text),
      'end', jsonb_build_object('date', (v_mirror.local_date + 1)::text),
      'transparency', 'transparent'
    );
  else
    select * into v_task
    from public.task_instances
    where household_id = v_mirror.household_id
      and id = v_mirror.task_instance_id
      and test_context_id is null;

    if not found or v_task.status = 'cancelled' or v_task.calendar_visibility <> 'special' then
      return jsonb_build_object(
        'household_id', v_mirror.household_id, 'projection_key', v_mirror.projection_key,
        'calendar_connection_id', v_mirror.calendar_connection_id, 'lease_token', v_lease,
        'action', 'delete', 'provider_event_id', v_mirror.provider_event_id,
        'deterministic_event_id', v_event_id
      );
    end if;

    if v_task.due_at is not null and v_task.calendar_ends_at is null then
      raise exception 'CALENDAR_EVENT_END_REQUIRED';
    end if;
    if v_task.calendar_ends_at is not null and v_task.calendar_ends_at <= v_task.due_at then
      raise exception 'INVALID_INPUT';
    end if;

    if v_task.due_at is null then
      v_payload := jsonb_build_object(
        'id', v_event_id, 'summary', v_task.title,
        'start', jsonb_build_object('date', v_task.scheduled_date::text),
        'end', jsonb_build_object('date', (v_task.scheduled_date + 1)::text),
        'transparency', 'transparent'
      );
    else
      v_payload := jsonb_build_object(
        'id', v_event_id, 'summary', v_task.title,
        'start', jsonb_build_object('dateTime', v_task.due_at, 'timeZone', 'Asia/Tokyo'),
        'end', jsonb_build_object('dateTime', v_task.calendar_ends_at, 'timeZone', 'Asia/Tokyo')
      );
    end if;
  end if;

  v_payload := v_payload || jsonb_build_object(
    'extendedProperties', jsonb_build_object('private', jsonb_build_object(
      'familyOpsMirror', 'true',
      'familyOpsProjectionKey', v_mirror.projection_key,
      'familyOpsKind', v_mirror.kind,
      'familyOpsTaskInstanceId', coalesce(v_mirror.task_instance_id::text, '')
    ))
  );

  return jsonb_build_object(
    'household_id', v_mirror.household_id,
    'projection_key', v_mirror.projection_key,
    'calendar_connection_id', v_mirror.calendar_connection_id,
    'lease_token', v_lease,
    'action', 'upsert',
    'provider_event_id', v_mirror.provider_event_id,
    'deterministic_event_id', v_event_id,
    'event', v_payload
  );
end;
$$;

revoke all on function public.server_tx_claim_family_ops_calendar_mirror(text, integer)
  from public, anon, authenticated;
grant execute on function public.server_tx_claim_family_ops_calendar_mirror(text, integer)
  to service_role;
