-- WP2: initial dropoff/pickup times and weekly assignee setup.
--
-- No dedicated endpoint exists in the v6 design docs for this — the only
-- generic contract that fits (`change-recurrence`) is a WP3 concept and is
-- not yet implemented. This mirrors server_tx_configure_evening_routines's
-- already-implemented, already-reviewed batch shape rather than building
-- WP3's full recurrence-engine endpoint just for this one wizard step:
-- dropoff/pickup task_definitions cannot use role-based assignee_strategy
-- (would create a cycle, per 08_RECURRING_TASKS_AND_RULES.md #4 — a
-- dropoff/pickup rule assigning "whoever does dropoff/pickup" is
-- circular), so this endpoint only ever writes 'fixed' strategy rows,
-- across up to 7 weekdays each for the 'dropoff'/'pickup' task codes
-- (already bootstrapped as task_definitions at household creation — this
-- endpoint only ever creates their recurrence_rules, never the
-- definitions themselves).
--
-- Same "no partial save" / claim-then-fill / version-bump-on-change /
-- future-todo-only reconciliation / 14-day materialize pattern as
-- configure-evening-routines. Adds households.dropoff_pickup_setup_completed_at
-- (mirrors evening_routine_setup_completed_at from migration
-- 20260819000012) so the PWA has an unambiguous "is this wizard step done"
-- signal instead of inferring it from row presence.

alter table public.households
  add column dropoff_pickup_setup_completed_at timestamptz null;

create or replace function public.server_tx_configure_dropoff_pickup(
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
  v_materialize_from date;
  v_materialize_to date;
  v_request_hash text;
  v_receipt record;
  v_household_id uuid;
  v_row jsonb;
  v_task_definition_id uuid;
  v_task_code text;
  v_weekday int;
  v_enabled boolean;
  v_fixed_assignee uuid;
  v_scheduled_time time;
  v_existing_rule public.recurrence_rules%rowtype;
  v_needs_new_version boolean;
  v_rule_id uuid;
  v_result jsonb;
begin
  v_materialize_from := v_today;
  v_materialize_to := v_today + 14;

  if p_actor_id is null or p_operation_id is null or p_rows is null
     or jsonb_typeof(p_rows) <> 'array' or jsonb_array_length(p_rows) = 0 then
    raise exception 'INVALID_INPUT';
  end if;

  -- Validate the entire batch shape before any mutation ("no partial
  -- save"): every row names dropoff/pickup, a valid weekday, an explicit
  -- enabled decision, and (only when enabled) a fixed assignee.
  for v_row in select * from jsonb_array_elements(p_rows)
  loop
    if not (v_row ? 'task_code') or (v_row->>'task_code') not in ('dropoff', 'pickup') then
      raise exception 'INVALID_INPUT';
    end if;
    if not (v_row ? 'weekday') or (v_row->>'weekday')::int not between 1 and 7 then
      raise exception 'INVALID_INPUT';
    end if;
    if not (v_row ? 'enabled') or jsonb_typeof(v_row->'enabled') <> 'boolean' then
      raise exception 'INVALID_INPUT';
    end if;
    if (v_row->>'enabled')::boolean and coalesce(v_row->>'fixed_assignee_id', '') = '' then
      raise exception 'INVALID_INPUT';
    end if;
    if not (v_row->>'enabled')::boolean and coalesce(v_row->>'fixed_assignee_id', '') <> '' then
      raise exception 'INVALID_INPUT';
    end if;
  end loop;

  -- Reject duplicate (task_code, weekday) rows in the same batch — each
  -- must be named at most once, same "no ambiguous instruction" principle
  -- as configure-evening-routines' exact-7-codes check.
  if (
    select count(*) from jsonb_array_elements(p_rows) r
  ) <> (
    select count(distinct (r->>'task_code', r->>'weekday'))
    from jsonb_array_elements(p_rows) r
  ) then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to('configure-dropoff-pickup|' || p_rows::text, 'UTF8')),
    'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'configure-dropoff-pickup', v_request_hash)
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

  -- Validate every fixed_assignee is a same-household member before
  -- mutating anything.
  for v_row in select * from jsonb_array_elements(p_rows)
  loop
    if (v_row->>'enabled')::boolean and not exists (
      select 1 from public.household_members
      where household_id = v_household_id and user_id = (v_row->>'fixed_assignee_id')::uuid
    ) then
      raise exception 'CROSS_HOUSEHOLD_RESOURCE';
    end if;
  end loop;

  for v_row in select * from jsonb_array_elements(p_rows)
  loop
    v_task_code := v_row->>'task_code';
    v_weekday := (v_row->>'weekday')::int;
    v_enabled := (v_row->>'enabled')::boolean;
    v_fixed_assignee := nullif(v_row->>'fixed_assignee_id', '')::uuid;
    v_scheduled_time := nullif(v_row->>'scheduled_local_time', '')::time;

    select id into v_task_definition_id
    from public.task_definitions
    where household_id = v_household_id and code = v_task_code;

    if v_task_definition_id is null then
      raise exception 'INVALID_INPUT';
    end if;

    select * into v_existing_rule
    from public.recurrence_rules
    where household_id = v_household_id and task_definition_id = v_task_definition_id
      and weekday = v_weekday and slot_key = 'default' and active
    order by version desc
    limit 1;

    if not v_enabled then
      if found then
        update public.recurrence_rules
        set active = false, effective_to = greatest(v_today - 1, v_existing_rule.effective_from)
        where id = v_existing_rule.id;

        delete from public.task_instances
        where household_id = v_household_id and recurrence_rule_id = v_existing_rule.id
          and scheduled_date >= v_today and status = 'todo';
      end if;
      continue;
    end if;

    v_needs_new_version := not found
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

      begin
        insert into public.recurrence_rules (
          household_id, task_definition_id, weekday, slot_key,
          assignee_strategy, planned_assignee_id, scheduled_local_time,
          effective_from, active, version, supersedes_rule_id, created_by
        ) values (
          v_household_id, v_task_definition_id, v_weekday, 'default',
          'fixed', v_fixed_assignee, v_scheduled_time,
          v_today, true, coalesce(v_existing_rule.version, 0) + 1,
          v_existing_rule.id, p_actor_id
        )
        returning id into v_rule_id;
      exception
        when exclusion_violation then
          raise exception 'RECURRENCE_OVERLAP';
      end;

      perform private.materialize_recurrence_rule(
        v_household_id, v_rule_id, v_materialize_from, v_materialize_to
      );
    else
      perform private.materialize_recurrence_rule(
        v_household_id, v_existing_rule.id, v_materialize_from, v_materialize_to
      );
    end if;
  end loop;

  update public.households
  set dropoff_pickup_setup_completed_at = now()
  where id = v_household_id;

  v_result := jsonb_build_object(
    'household_id', v_household_id,
    'dropoff_pickup_setup_completed_at', now()
  );

  update private.mutation_receipts
  set result_type = 'dropoff_pickup_setup', result_id = v_household_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_configure_dropoff_pickup(uuid, uuid, jsonb) from public;
revoke all on function public.server_tx_configure_dropoff_pickup(uuid, uuid, jsonb) from anon;
revoke all on function public.server_tx_configure_dropoff_pickup(uuid, uuid, jsonb) from authenticated;
grant execute on function public.server_tx_configure_dropoff_pickup(uuid, uuid, jsonb) to service_role;
