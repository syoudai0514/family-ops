-- WP2: update-routine-schedule — edit one of the 9 household_routine_schedules
-- rows (enabled + local_time only). 18_MUTATION_CONTRACT_MATRIX.md #9's text
-- still mentions a `weekday` input for the retired `weekly_digest` kind, but
-- the live schema's CHECK constraint (check (weekday is null), unconditional
-- for all 9 current kinds — see 20260819000004) makes weekday non-editable
-- for every kind that still exists. No weekday input is accepted here.

create or replace function public.server_tx_update_routine_schedule(
  p_actor_id uuid,
  p_operation_id uuid,
  p_schedule_kind text,
  p_enabled boolean,
  p_local_time time
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_request_hash text;
  v_receipt record;
  v_household_id uuid;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_enabled is null or p_local_time is null then
    raise exception 'INVALID_INPUT';
  end if;
  if p_schedule_kind not in (
    'daily_assignment',
    'dropoff_checklist', 'dropoff_checkin',
    'pickup_checklist', 'pickup_checkin',
    'nonpickup_evening_checklist', 'nonpickup_evening_checkin',
    'nonworkday_morning_digest', 'nonworkday_checkin'
  ) then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to(
      'update-routine-schedule|' || p_schedule_kind || '|' || p_enabled::text || '|' || p_local_time::text,
      'UTF8'
    )),
    'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'update-routine-schedule', v_request_hash)
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
    select 1 from public.household_routine_schedules
    where household_id = v_household_id and schedule_kind = p_schedule_kind
    for update
  ) then
    raise exception 'INVALID_INPUT';
  end if;

  update public.household_routine_schedules
  set
    enabled = p_enabled,
    local_time = p_local_time,
    schedule_version = schedule_version + 1,
    updated_by = p_actor_id
  where household_id = v_household_id and schedule_kind = p_schedule_kind;

  v_result := jsonb_build_object('ok', true);

  update private.mutation_receipts
  set result_type = 'household_routine_schedule', result_id = v_household_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_update_routine_schedule(uuid, uuid, text, boolean, time) from public;
revoke all on function public.server_tx_update_routine_schedule(uuid, uuid, text, boolean, time) from anon;
revoke all on function public.server_tx_update_routine_schedule(uuid, uuid, text, boolean, time) from authenticated;
grant execute on function public.server_tx_update_routine_schedule(uuid, uuid, text, boolean, time) to service_role;
