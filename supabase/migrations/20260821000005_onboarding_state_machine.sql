alter table public.households
  add column if not exists morning_preparation_setup_completed_at timestamptz,
  add column if not exists connections_setup_completed_at timestamptz,
  add column if not exists notification_preferences_setup_completed_at timestamptz,
  add column if not exists onboarding_preview_completed_at timestamptz;

-- Preserve existing households: only newly created or genuinely unfinished
-- households enter the expanded onboarding flow after this migration.
update public.households
set morning_preparation_setup_completed_at = coalesce(morning_preparation_setup_completed_at, now()),
    connections_setup_completed_at = coalesce(connections_setup_completed_at, now()),
    notification_preferences_setup_completed_at = coalesce(notification_preferences_setup_completed_at, now()),
    onboarding_preview_completed_at = coalesce(onboarding_preview_completed_at, now())
where dropoff_pickup_setup_completed_at is not null
  and evening_routine_setup_completed_at is not null;

create or replace function public.server_tx_complete_onboarding_step(
  p_actor_id uuid,
  p_operation_id uuid,
  p_step text
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_request_hash text;
  v_receipt record;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null
     or p_step not in ('morning_preparation', 'connections', 'notifications', 'week_preview') then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(sha256(convert_to('complete-onboarding-step|' || p_step, 'UTF8')), 'hex');
  insert into private.mutation_receipts(actor_id, operation_id, action_type, request_hash)
  values (p_actor_id, p_operation_id, 'complete-onboarding-step', v_request_hash)
  on conflict(actor_id, operation_id) do nothing;
  if not found then
    select * into v_receipt from private.mutation_receipts
      where actor_id = p_actor_id and operation_id = p_operation_id;
    if v_receipt.request_hash <> v_request_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    return v_receipt.result_payload;
  end if;

  select household_id into v_household_id
  from public.household_members where user_id = p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;

  if p_step = 'morning_preparation' then
    update public.households set morning_preparation_setup_completed_at = coalesce(morning_preparation_setup_completed_at, now())
      where id = v_household_id and evening_routine_setup_completed_at is not null;
  elsif p_step = 'connections' then
    update public.households set connections_setup_completed_at = coalesce(connections_setup_completed_at, now())
      where id = v_household_id and morning_preparation_setup_completed_at is not null;
  elsif p_step = 'notifications' then
    update public.households set notification_preferences_setup_completed_at = coalesce(notification_preferences_setup_completed_at, now())
      where id = v_household_id and connections_setup_completed_at is not null;
  else
    update public.households set onboarding_preview_completed_at = coalesce(onboarding_preview_completed_at, now())
      where id = v_household_id and notification_preferences_setup_completed_at is not null;
  end if;
  if not found then raise exception 'ONBOARDING_STEP_OUT_OF_ORDER'; end if;

  v_result := jsonb_build_object('household_id', v_household_id, 'step', p_step, 'completed', true);
  update private.mutation_receipts
  set result_type = 'household', result_id = v_household_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;
  return v_result;
end;
$$;

revoke all on function public.server_tx_complete_onboarding_step(uuid, uuid, text) from public, anon, authenticated;
grant execute on function public.server_tx_complete_onboarding_step(uuid, uuid, text) to service_role;
