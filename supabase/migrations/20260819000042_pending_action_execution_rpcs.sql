-- WP6: process-pending-actions's queue mechanics — the execution half of
-- private.pending_actions (confirmed -> executing -> succeeded/dead),
-- distinct from process-line-inbox's own draft/confirm/cancel staging RPCs
-- in 20260819000041. docs/design/v6/09_API_AND_EDGE_FUNCTIONS.md #6
-- "process-pending-actions: confirmed only, lease/reclaim, reauthorization,
-- DB/external side effect recovery"; 01_ARCHITECTURE.md.

create or replace function public.server_tx_claim_pending_actions_batch(
  p_worker_id text,
  p_limit int,
  p_lease_seconds int
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  if coalesce(p_worker_id, '') = '' or p_limit is null or p_limit <= 0
     or p_lease_seconds is null or p_lease_seconds <= 0 then
    raise exception 'INVALID_INPUT';
  end if;

  -- Opportunistically expire confirmed actions whose business TTL passed
  -- before anyone executed them (06_LINE_INTEGRATION.md #9 "expiry") so
  -- they stop being claim candidates instead of failing forever.
  update private.pending_actions
  set status = 'expired'
  where status = 'confirmed' and expires_at <= now();

  with claimable as (
    select id
    from private.pending_actions
    where expires_at > now()
      and (
        (status = 'confirmed' and next_attempt_at <= now())
        or (status = 'executing' and lease_until < now()) -- reclaim a dead worker's lease
      )
    order by confirmed_at nulls last, created_at
    for update skip locked
    limit p_limit
  ),
  updated as (
    update private.pending_actions pa
    set status = 'executing',
        attempts = pa.attempts + 1,
        lease_owner = p_worker_id,
        lease_token = gen_random_uuid(),
        lease_until = now() + make_interval(secs => p_lease_seconds),
        last_started_at = now()
    from claimable
    where pa.id = claimable.id
    returning pa.id, pa.household_id, pa.actor_id, pa.action_type, pa.normalized_payload,
      pa.operation_id, pa.attempts, pa.lease_token
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', id,
    'household_id', household_id,
    'actor_id', actor_id,
    'action_type', action_type,
    'normalized_payload', normalized_payload,
    'operation_id', operation_id,
    'attempts', attempts,
    'lease_token', lease_token
  ) order by attempts), '[]'::jsonb)
  into v_result
  from updated;

  return v_result;
end;
$$;

revoke all on function public.server_tx_claim_pending_actions_batch(text, int, int) from public;
revoke all on function public.server_tx_claim_pending_actions_batch(text, int, int) from anon;
revoke all on function public.server_tx_claim_pending_actions_batch(text, int, int) from authenticated;
grant execute on function public.server_tx_claim_pending_actions_batch(text, int, int) to service_role;

create or replace function public.server_tx_complete_pending_action(
  p_id uuid,
  p_lease_token uuid,
  p_result_type text,
  p_result_id uuid
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_updated int;
begin
  if p_id is null or p_lease_token is null then
    raise exception 'INVALID_INPUT';
  end if;

  update private.pending_actions
  set status = 'succeeded',
      result_type = p_result_type,
      result_id = p_result_id,
      lease_owner = null,
      lease_token = null,
      lease_until = null
  where id = p_id and lease_token = p_lease_token and status = 'executing';

  get diagnostics v_updated = row_count;
  return jsonb_build_object('ok', v_updated = 1);
end;
$$;

revoke all on function public.server_tx_complete_pending_action(uuid, uuid, text, uuid) from public;
revoke all on function public.server_tx_complete_pending_action(uuid, uuid, text, uuid) from anon;
revoke all on function public.server_tx_complete_pending_action(uuid, uuid, text, uuid) from authenticated;
grant execute on function public.server_tx_complete_pending_action(uuid, uuid, text, uuid) to service_role;

create or replace function public.server_tx_fail_pending_action(
  p_id uuid,
  p_lease_token uuid,
  p_error text,
  p_max_attempts int,
  p_retry_delay_seconds int
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_row record;
  v_new_status text;
begin
  if p_id is null or p_lease_token is null then
    raise exception 'INVALID_INPUT';
  end if;

  select * into v_row
  from private.pending_actions
  where id = p_id and lease_token = p_lease_token and status = 'executing'
  for update;

  if not found then
    return jsonb_build_object('ok', false); -- lease already reclaimed elsewhere
  end if;

  if v_row.attempts >= coalesce(p_max_attempts, 5) then
    v_new_status := 'dead';
    update private.pending_actions
    set status = v_new_status, last_error = p_error,
        lease_owner = null, lease_token = null, lease_until = null
    where id = p_id;
  else
    v_new_status := 'confirmed';
    update private.pending_actions
    set status = v_new_status, last_error = p_error,
        next_attempt_at = now() + make_interval(secs => coalesce(p_retry_delay_seconds, 60) * v_row.attempts),
        lease_owner = null, lease_token = null, lease_until = null
    where id = p_id;
  end if;

  return jsonb_build_object('ok', true, 'status', v_new_status);
end;
$$;

revoke all on function public.server_tx_fail_pending_action(uuid, uuid, text, int, int) from public;
revoke all on function public.server_tx_fail_pending_action(uuid, uuid, text, int, int) from anon;
revoke all on function public.server_tx_fail_pending_action(uuid, uuid, text, int, int) from authenticated;
grant execute on function public.server_tx_fail_pending_action(uuid, uuid, text, int, int) to service_role;
