-- v6 re-review fix (P1 #3 batch completeness, P1 #4 timezone):
--   - configure-evening-routines must only accept a *complete* batch: all 7
--     canonical evening tasks (dinner/bath/laundry/dishes/cleaning/
--     smile_zemi/media_30min), each with an explicit enabled/disabled
--     decision. A partial batch (e.g. one task) must never mark setup
--     complete.
--   - current_date was evaluated multiple times against the wall-clock UTC
--     session date, not the household's fixed Asia/Tokyo timezone. Near the
--     UTC day boundary (e.g. 2026-08-19 15:30Z = 2026-08-20 00:30 JST) this
--     could compute the wrong effective_from/effective_to and materialize
--     window. Fixed to compute v_today = (now() at time zone
--     'Asia/Tokyo')::date exactly once and use it everywhere current_date
--     was previously used.
create or replace function public.server_tx_configure_evening_routines(
  p_actor_id uuid,
  p_operation_id uuid,
  p_rows jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_today date := (now() at time zone 'Asia/Tokyo')::date;
  v_required_codes text[] := array['dinner', 'bath', 'laundry', 'dishes', 'cleaning', 'smile_zemi', 'media_30min'];
  v_seen_codes text[] := '{}';
  v_request_hash text;
  v_receipt record;
  v_household_id uuid;
  v_row jsonb;
  v_task_definition_id uuid;
  v_strategy text;
  v_fixed_assignee uuid;
  v_scheduled_time time;
  v_enabled boolean;
  v_weekdays int[];
  v_weekday int;
  v_existing_rule public.recurrence_rules%rowtype;
  v_wants_active boolean;
  v_needs_new_version boolean;
  v_result jsonb;
  v_materialize_from date;
  v_materialize_to date;
  v_rule_id uuid;
begin
  v_materialize_from := v_today;
  v_materialize_to := v_today + 14;

  if p_actor_id is null or p_operation_id is null or p_rows is null
     or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) <> 7 then
    raise exception 'INVALID_INPUT';
  end if;

  -- Validate the *entire* batch shape before any mutation ("no partial
  -- save"), and that it is exactly the 7 canonical evening tasks, each with
  -- an explicit enabled/disabled decision — never a partial batch.
  for v_row in select * from jsonb_array_elements(p_rows)
  loop
    if not (v_row ? 'task_code') or coalesce(v_row->>'task_code', '') = '' then
      raise exception 'INVALID_INPUT';
    end if;
    if not (v_row ? 'weekdays') or jsonb_typeof(v_row->'weekdays') <> 'array' then
      raise exception 'INVALID_INPUT';
    end if;
    if not (v_row ? 'assignee_strategy')
       or (v_row->>'assignee_strategy') not in ('pickup_assignee', 'nonpickup_adult', 'fixed') then
      raise exception 'INVALID_INPUT';
    end if;
    if (v_row->>'assignee_strategy') = 'fixed' and coalesce(v_row->>'fixed_assignee_id', '') = '' then
      raise exception 'INVALID_INPUT';
    end if;
    if (v_row->>'assignee_strategy') <> 'fixed' and coalesce(v_row->>'fixed_assignee_id', '') <> '' then
      raise exception 'INVALID_INPUT';
    end if;
    if not (v_row ? 'enabled') or jsonb_typeof(v_row->'enabled') <> 'boolean' then
      raise exception 'INVALID_INPUT';
    end if;
    v_seen_codes := array_append(v_seen_codes, v_row->>'task_code');
  end loop;

  if (select array_agg(x order by x) from unnest(v_seen_codes) as x)
     <> (select array_agg(x order by x) from unnest(v_required_codes) as x) then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to('configure-evening-routines|' || p_rows::text, 'UTF8')),
    'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'configure-evening-routines', v_request_hash)
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

  -- Resolve task_definition_id per code and validate fixed_assignee is a
  -- same-household member, for every row, before mutating anything.
  for v_row in select * from jsonb_array_elements(p_rows)
  loop
    if not exists (
      select 1 from public.task_definitions
      where household_id = v_household_id and code = v_row->>'task_code'
    ) then
      raise exception 'INVALID_INPUT';
    end if;
    if (v_row->>'assignee_strategy') = 'fixed' and not exists (
      select 1 from public.household_members
      where household_id = v_household_id and user_id = (v_row->>'fixed_assignee_id')::uuid
    ) then
      raise exception 'CROSS_HOUSEHOLD_RESOURCE';
    end if;
  end loop;

  for v_row in select * from jsonb_array_elements(p_rows)
  loop
    select id into v_task_definition_id
    from public.task_definitions
    where household_id = v_household_id and code = v_row->>'task_code';

    v_strategy := v_row->>'assignee_strategy';
    v_fixed_assignee := nullif(v_row->>'fixed_assignee_id', '')::uuid;
    v_scheduled_time := nullif(v_row->>'scheduled_local_time', '')::time;
    v_enabled := (v_row->>'enabled')::boolean;

    select coalesce(array_agg((elem)::int), '{}') into v_weekdays
    from jsonb_array_elements_text(v_row->'weekdays') as elem;

    foreach v_weekday in array array[1, 2, 3, 4, 5, 6, 7]
    loop
      v_wants_active := v_enabled and v_weekday = any(v_weekdays);

      insert into public.evening_routine_preferences
        (household_id, task_definition_id, weekday, enabled, assignee_strategy, fixed_assignee_id, scheduled_local_time)
      values
        (v_household_id, v_task_definition_id, v_weekday, v_wants_active, v_strategy, v_fixed_assignee, v_scheduled_time)
      on conflict (household_id, task_definition_id, weekday)
      do update set
        enabled = v_wants_active,
        assignee_strategy = excluded.assignee_strategy,
        fixed_assignee_id = excluded.fixed_assignee_id,
        scheduled_local_time = excluded.scheduled_local_time,
        updated_at = now();

      select * into v_existing_rule
      from public.recurrence_rules
      where household_id = v_household_id and task_definition_id = v_task_definition_id
        and weekday = v_weekday and slot_key = 'default' and active
      order by version desc
      limit 1;

      if not v_wants_active then
        if found then
          update public.recurrence_rules
          set active = false, effective_to = greatest(v_today - 1, v_existing_rule.effective_from)
          where id = v_existing_rule.id;

          -- future todo-only reconciliation (18_MUTATION_CONTRACT_MATRIX.md #9
          -- "change recurrence": in_progress/completed/skipped/cancelled preserved)
          delete from public.task_instances
          where household_id = v_household_id and recurrence_rule_id = v_existing_rule.id
            and scheduled_date >= v_today and status = 'todo';
        end if;
        continue;
      end if;

      v_needs_new_version := not found
        or v_existing_rule.assignee_strategy <> v_strategy
        or v_existing_rule.planned_assignee_id is distinct from v_fixed_assignee
        or v_existing_rule.scheduled_local_time is distinct from v_scheduled_time;

      if v_needs_new_version then
        if found then
          update public.recurrence_rules
          set active = false, effective_to = greatest(v_today - 1, v_existing_rule.effective_from)
          where id = v_existing_rule.id;

          delete from public.task_instances
          where household_id = v_household_id and recurrence_rule_id = v_existing_rule.id
            and scheduled_date >= v_today and status = 'todo';
        end if;

        insert into public.recurrence_rules (
          household_id, task_definition_id, weekday, slot_key,
          assignee_strategy, planned_assignee_id, scheduled_local_time,
          effective_from, active, version, supersedes_rule_id, created_by
        ) values (
          v_household_id, v_task_definition_id, v_weekday, 'default',
          v_strategy, v_fixed_assignee, v_scheduled_time,
          v_today, true, coalesce(v_existing_rule.version, 0) + 1,
          v_existing_rule.id, p_actor_id
        )
        returning id into v_rule_id;

        perform private.materialize_recurrence_rule(
          v_household_id, v_rule_id, v_materialize_from, v_materialize_to
        );
      else
        perform private.materialize_recurrence_rule(
          v_household_id, v_existing_rule.id, v_materialize_from, v_materialize_to
        );
      end if;
    end loop;
  end loop;

  update public.households
  set evening_routine_setup_completed_at = now()
  where id = v_household_id;

  v_result := jsonb_build_object(
    'household_id', v_household_id,
    'evening_routine_setup_completed_at', now()
  );

  update private.mutation_receipts
  set result_type = 'evening_routine_setup', result_id = v_household_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_configure_evening_routines(uuid, uuid, jsonb) from public;
revoke all on function public.server_tx_configure_evening_routines(uuid, uuid, jsonb) from anon;
revoke all on function public.server_tx_configure_evening_routines(uuid, uuid, jsonb) from authenticated;
grant execute on function public.server_tx_configure_evening_routines(uuid, uuid, jsonb) to service_role;
