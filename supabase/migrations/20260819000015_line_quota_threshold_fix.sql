-- v6 re-review fix (P2):
--   - threshold formula was collapsing normal/reminder onto the same
--     soft_budget value. Correct formula per the reviewer:
--       reminder = min(soft_budget, hard_limit - reserve)
--       normal   = hard_limit - reserve
--       critical = hard_limit
--     With the documented defaults (soft_budget=180, reserve=20,
--     app_hard_cap=200) these coincide (180 either way), which is exactly
--     why a non-default soft_budget is needed to prove the formula itself
--     is right rather than accidentally-numerically-equal — see
--     tests/sql/05_line_quota_reservation.sql "non-default soft_budget".
--   - the caller-supplied p_priority is now cross-checked against
--     private.notification_outbox.priority for the given
--     notification_outbox_id (the DB's own record of what this
--     notification actually is), and a mismatch is rejected rather than
--     silently trusting the caller.
create or replace function public.server_tx_reserve_line_quota(
  p_notification_outbox_id uuid,
  p_priority text
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_billing_month date := date_trunc('month', (now() at time zone 'Asia/Tokyo'))::date;
  v_state record;
  v_active_reserved int;
  v_effective_hard_limit int;
  v_effective_usage int;
  v_threshold int;
  v_permitted boolean;
  v_reservation_id uuid;
  v_existing record;
  v_outbox_priority text;
begin
  if p_priority not in ('critical', 'normal', 'reminder') then
    raise exception 'INVALID_INPUT';
  end if;
  if p_notification_outbox_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  select priority into v_outbox_priority
  from private.notification_outbox
  where id = p_notification_outbox_id;

  if not found then
    raise exception 'INVALID_INPUT';
  end if;
  if v_outbox_priority <> p_priority then
    raise exception 'INVALID_INPUT';
  end if;

  -- idempotent replay: notification_outbox_id is UNIQUE on
  -- line_quota_reservations, so a retried reserve call for the same outbox
  -- row (e.g. after the Edge Function's own response was lost) must return
  -- the already-decided outcome instead of erroring on the unique
  -- violation or re-deciding admission against a now-different quota state.
  select * into v_existing
  from private.line_quota_reservations
  where notification_outbox_id = p_notification_outbox_id
  for update;

  if found then
    return jsonb_build_object(
      'permitted', v_existing.status in ('reserved', 'ambiguous', 'committed'),
      'reservation_id', v_existing.id,
      'billing_month', v_existing.billing_month,
      'replay', true
    );
  end if;

  insert into private.line_quota_state (billing_month, provider_limit, provider_consumed)
  values (v_billing_month, 200, 0)
  on conflict (billing_month) do nothing;

  select * into v_state
  from private.line_quota_state
  where billing_month = v_billing_month
  for update;

  select count(*) into v_active_reserved
  from private.line_quota_reservations
  where billing_month = v_billing_month
    and status in ('reserved', 'ambiguous');

  v_effective_hard_limit := least(v_state.provider_limit, v_state.app_hard_cap);
  v_effective_usage := greatest(v_state.provider_consumed, v_state.local_counted_success) + v_active_reserved;
  v_threshold := case p_priority
    when 'critical' then v_effective_hard_limit
    when 'normal' then v_effective_hard_limit - v_state.reserve
    when 'reminder' then least(v_state.soft_budget, v_effective_hard_limit - v_state.reserve)
  end;
  v_permitted := (v_effective_usage + 1) <= v_threshold;

  if v_permitted then
    insert into private.line_quota_reservations
      (billing_month, notification_outbox_id, status, provider_consumed_snapshot)
    values
      (v_billing_month, p_notification_outbox_id, 'reserved', v_state.provider_consumed)
    returning id into v_reservation_id;

    update private.notification_outbox
    set quota_reservation_id = v_reservation_id
    where id = p_notification_outbox_id;
  end if;

  return jsonb_build_object(
    'permitted', v_permitted,
    'reservation_id', v_reservation_id,
    'effective_usage_before', v_effective_usage,
    'effective_hard_limit', v_effective_hard_limit,
    'threshold', v_threshold,
    'billing_month', v_billing_month,
    'replay', false
  );
end;
$$;

revoke all on function public.server_tx_reserve_line_quota(uuid, text) from public;
revoke all on function public.server_tx_reserve_line_quota(uuid, text) from anon;
revoke all on function public.server_tx_reserve_line_quota(uuid, text) from authenticated;
grant execute on function public.server_tx_reserve_line_quota(uuid, text) to service_role;
