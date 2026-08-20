-- WP3 (Recurrence engine): general-purpose `change-recurrence` endpoint.
-- docs/design/v6/18_MUTATION_CONTRACT_MATRIX.md #9 "change recurrence";
-- 08_RECURRING_TASKS_AND_RULES.md #8 "Future rule change"; #9 "Overlap
-- prevention"; 03_DOMAIN_AND_DATA_MODEL.md #3 "recurrence_rules".
--
-- Unlike configure-evening-routines / configure-dropoff-pickup (WP1/WP2
-- batch wizards that each write up to 7/14 rows in one call),
-- change-recurrence operates on exactly one (task_definition_id, weekday,
-- slot_key) rule per call, per the matrix's single-rule input shape ("rule
-- id / task definition", not a batch array). It follows the *exact* same
-- proven mechanics as those two: no-partial-save input validation before
-- any mutation, claim-then-fill idempotency via private.mutation_receipts,
-- version-bump-on-change (close old active rule's effective_to the day
-- before the new rule's effective_from, insert a new version, leave
-- in_progress/completed/skipped/cancelled instances untouched, delete only
-- future 'todo' instances tied to the closed rule), 14-day materialize
-- horizon, and RECURRENCE_OVERLAP on `recurrence_rules_no_overlap`
-- exclusion_violation.
--
-- Implementation decisions not pinned down verbatim by the matrix text:
--   - The rule is identified by (task_definition_id, weekday, slot_key)
--     rather than an opaque rule_id, matching the doc's "rule id / task
--     definition" alternative and the identity tuple the exclusion
--     constraint itself is keyed on; slot_key defaults to 'default' when
--     omitted, same default the DB column and every existing writer use.
--   - effective_from is required and must be >= today (Asia/Tokyo): the
--     matrix's own reconciliation rule ("future todo only auto reconcile")
--     only makes sense for a change taking effect today or later; backdating
--     is rejected as INVALID_INPUT rather than silently clamped.
--   - dropoff/pickup task_definitions (code in ('dropoff','pickup')) reject
--     role-based assignee_strategy up front with INVALID_INPUT — per
--     08_RECURRING_TASKS_AND_RULES.md #4, "dropoff and pickup definitions
--     cannot themselves use dropoff/pickup/nonpickup role strategies"
--     (would be a circular resolution).
--   - planned_assignee_user_id must be present iff assignee_strategy='fixed'
--     and absent otherwise, mirroring the recurrence_rules CHECK constraint
--     itself (03_DOMAIN_AND_DATA_MODEL.md #3 "Assignment constraints") — a
--     violation is INVALID_INPUT before ever reaching the DB constraint.

create or replace function public.server_tx_change_recurrence(
  p_actor_id uuid,
  p_operation_id uuid,
  p_task_definition_id uuid,
  p_weekday int,
  p_slot_key text,
  p_assignee_strategy text,
  p_planned_assignee_user_id uuid,
  p_scheduled_local_time time,
  p_conflict_window_minutes int,
  p_effective_from date
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_today date := (now() at time zone 'Asia/Tokyo')::date;
  v_slot_key text := coalesce(nullif(btrim(p_slot_key), ''), 'default');
  v_conflict_window int := coalesce(p_conflict_window_minutes, 60);
  v_effective_from date := coalesce(p_effective_from, v_today);
  v_request_hash text;
  v_receipt record;
  v_household_id uuid;
  v_task public.task_definitions%rowtype;
  v_existing_rule public.recurrence_rules%rowtype;
  v_rule_id uuid;
  v_result jsonb;
  v_materialize_from date;
  v_materialize_to date;
begin
  if p_actor_id is null or p_operation_id is null or p_task_definition_id is null or p_weekday is null then
    raise exception 'INVALID_INPUT';
  end if;
  if p_weekday not between 1 and 7 then
    raise exception 'INVALID_INPUT';
  end if;
  if p_assignee_strategy is null
     or p_assignee_strategy not in ('fixed', 'dropoff_assignee', 'pickup_assignee', 'nonpickup_adult', 'unassigned') then
    raise exception 'INVALID_INPUT';
  end if;
  if p_assignee_strategy = 'fixed' and p_planned_assignee_user_id is null then
    raise exception 'INVALID_INPUT';
  end if;
  if p_assignee_strategy <> 'fixed' and p_planned_assignee_user_id is not null then
    raise exception 'INVALID_INPUT';
  end if;
  if v_conflict_window < 0 or v_conflict_window > 720 then
    raise exception 'INVALID_INPUT';
  end if;
  if v_effective_from < v_today then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to(
      'change-recurrence|' || p_task_definition_id::text || '|' || p_weekday::text || '|' || v_slot_key
        || '|' || p_assignee_strategy || '|' || coalesce(p_planned_assignee_user_id::text, '')
        || '|' || coalesce(p_scheduled_local_time::text, '') || '|' || v_conflict_window::text
        || '|' || v_effective_from::text,
      'UTF8'
    )),
    'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'change-recurrence', v_request_hash)
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

  select * into v_task
  from public.task_definitions
  where household_id = v_household_id and id = p_task_definition_id;

  if not found then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  if v_task.code in ('dropoff', 'pickup') and p_assignee_strategy in ('dropoff_assignee', 'pickup_assignee', 'nonpickup_adult') then
    raise exception 'INVALID_INPUT';
  end if;

  if p_planned_assignee_user_id is not null and not exists (
    select 1 from public.household_members
    where household_id = v_household_id and user_id = p_planned_assignee_user_id
  ) then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  select * into v_existing_rule
  from public.recurrence_rules
  where household_id = v_household_id and task_definition_id = p_task_definition_id
    and weekday = p_weekday and slot_key = v_slot_key and active
  order by version desc
  limit 1;

  if found then
    update public.recurrence_rules
    set active = false, effective_to = greatest(v_today - 1, v_existing_rule.effective_from)
    where id = v_existing_rule.id;

    -- future todo-only reconciliation (08_RECURRING_TASKS_AND_RULES.md #8):
    -- in_progress/completed/skipped/cancelled instances are immutable here.
    delete from public.task_instances
    where household_id = v_household_id and recurrence_rule_id = v_existing_rule.id
      and scheduled_date >= v_today and status = 'todo';
  end if;

  begin
    insert into public.recurrence_rules (
      household_id, task_definition_id, weekday, slot_key,
      assignee_strategy, planned_assignee_id, scheduled_local_time, conflict_window_minutes,
      effective_from, active, version, supersedes_rule_id, created_by
    ) values (
      v_household_id, p_task_definition_id, p_weekday, v_slot_key,
      p_assignee_strategy, p_planned_assignee_user_id, p_scheduled_local_time, v_conflict_window,
      v_effective_from, true, coalesce(v_existing_rule.version, 0) + 1, v_existing_rule.id, p_actor_id
    )
    returning id into v_rule_id;
  exception
    when exclusion_violation then
      raise exception 'RECURRENCE_OVERLAP';
  end;

  v_materialize_from := v_today;
  v_materialize_to := v_today + 14;
  perform private.materialize_recurrence_rule(v_household_id, v_rule_id, v_materialize_from, v_materialize_to);

  v_result := jsonb_build_object(
    'rule_id', v_rule_id,
    'task_definition_id', p_task_definition_id,
    'weekday', p_weekday,
    'slot_key', v_slot_key,
    'assignee_strategy', p_assignee_strategy,
    'effective_from', v_effective_from
  );

  update private.mutation_receipts
  set result_type = 'recurrence_rule', result_id = v_rule_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_change_recurrence(uuid, uuid, uuid, int, text, text, uuid, time, int, date) from public;
revoke all on function public.server_tx_change_recurrence(uuid, uuid, uuid, int, text, text, uuid, time, int, date) from anon;
revoke all on function public.server_tx_change_recurrence(uuid, uuid, uuid, int, text, text, uuid, time, int, date) from authenticated;
grant execute on function public.server_tx_change_recurrence(uuid, uuid, uuid, int, text, text, uuid, time, int, date) to service_role;
