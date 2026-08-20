-- WP6: process-line-inbox's queue mechanics.
-- docs/design/v6/06_LINE_INTEGRATION.md #3 "Worker process-line-inbox every
-- 1 min handles parse/action", #9 "pending action ... lease/reclaim ...
-- expiry", #13 "process worker dies -> lease reclaim".
--
-- Two independent lease/reclaim/dead-letter queues, both service_role-only:
--   1. private.webhook_inbox  — durable LINE events (already written by
--      line-webhook-receiver); claimed/completed/failed here.
--   2. private.pending_actions (staging half) — draft/confirm/cancel. The
--      *execution* half of pending_actions (confirmed -> succeeded/dead) is
--      a separate queue with its own claim/complete/fail RPCs in
--      20260819000042 (process-pending-actions worker) — see
--      01_ARCHITECTURE.md's two distinct arrows into these two workers.

-- ---------------------------------------------------------------------------
-- webhook_inbox: claim / complete / fail
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_claim_webhook_inbox_batch(
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

  with claimable as (
    select id
    from private.webhook_inbox
    where (status = 'received' and next_attempt_at <= now())
       or (status = 'processing' and lease_until < now()) -- reclaim a dead worker's lease
    order by received_at
    for update skip locked
    limit p_limit
  ),
  updated as (
    update private.webhook_inbox w
    set status = 'processing',
        attempts = w.attempts + 1,
        lease_owner = p_worker_id,
        lease_token = gen_random_uuid(),
        lease_until = now() + make_interval(secs => p_lease_seconds),
        last_started_at = now()
    from claimable
    where w.id = claimable.id
    returning w.id, w.provider_event_id, w.source_external_user_id, w.payload, w.attempts, w.lease_token
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', id,
    'provider_event_id', provider_event_id,
    'source_external_user_id', source_external_user_id,
    'payload', payload,
    'attempts', attempts,
    'lease_token', lease_token
  ) order by attempts), '[]'::jsonb)
  into v_result
  from updated;

  return v_result;
end;
$$;

revoke all on function public.server_tx_claim_webhook_inbox_batch(text, int, int) from public;
revoke all on function public.server_tx_claim_webhook_inbox_batch(text, int, int) from anon;
revoke all on function public.server_tx_claim_webhook_inbox_batch(text, int, int) from authenticated;
grant execute on function public.server_tx_claim_webhook_inbox_batch(text, int, int) to service_role;

create or replace function public.server_tx_complete_webhook_inbox_item(
  p_id uuid,
  p_lease_token uuid
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

  update private.webhook_inbox
  set status = 'done',
      processed_at = now(),
      lease_owner = null,
      lease_token = null,
      lease_until = null
  where id = p_id and lease_token = p_lease_token and status = 'processing';

  get diagnostics v_updated = row_count;
  -- v_updated = 0 means the lease was already reclaimed by another worker
  -- (this worker was too slow) — reported, not raised, since it is an
  -- expected race outcome the caller handles by simply not double-counting.
  return jsonb_build_object('ok', v_updated = 1);
end;
$$;

revoke all on function public.server_tx_complete_webhook_inbox_item(uuid, uuid) from public;
revoke all on function public.server_tx_complete_webhook_inbox_item(uuid, uuid) from anon;
revoke all on function public.server_tx_complete_webhook_inbox_item(uuid, uuid) from authenticated;
grant execute on function public.server_tx_complete_webhook_inbox_item(uuid, uuid) to service_role;

create or replace function public.server_tx_fail_webhook_inbox_item(
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
  from private.webhook_inbox
  where id = p_id and lease_token = p_lease_token and status = 'processing'
  for update;

  if not found then
    return jsonb_build_object('ok', false); -- lease already reclaimed elsewhere
  end if;

  if v_row.attempts >= coalesce(p_max_attempts, 5) then
    v_new_status := 'dead';
    update private.webhook_inbox
    set status = v_new_status, last_error = p_error,
        lease_owner = null, lease_token = null, lease_until = null
    where id = p_id;
  else
    v_new_status := 'received';
    update private.webhook_inbox
    set status = v_new_status, last_error = p_error,
        next_attempt_at = now() + make_interval(secs => coalesce(p_retry_delay_seconds, 60) * v_row.attempts),
        lease_owner = null, lease_token = null, lease_until = null
    where id = p_id;
  end if;

  return jsonb_build_object('ok', true, 'status', v_new_status);
end;
$$;

revoke all on function public.server_tx_fail_webhook_inbox_item(uuid, uuid, text, int, int) from public;
revoke all on function public.server_tx_fail_webhook_inbox_item(uuid, uuid, text, int, int) from anon;
revoke all on function public.server_tx_fail_webhook_inbox_item(uuid, uuid, text, int, int) from authenticated;
grant execute on function public.server_tx_fail_webhook_inbox_item(uuid, uuid, text, int, int) to service_role;

-- ---------------------------------------------------------------------------
-- pending_actions: create (draft) / confirm / cancel
-- (06_LINE_INTEGRATION.md #9: "Confirmation postback itself never performs
-- external side-effect inline; it marks confirmed then worker executes.")
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_create_pending_action(
  p_actor_id uuid,
  p_household_id uuid,
  p_operation_id uuid,
  p_source text,
  p_action_type text,
  p_normalized_payload jsonb,
  p_ttl_minutes int
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_id uuid;
  v_existing record;
begin
  if p_actor_id is null or p_household_id is null or p_operation_id is null
     or coalesce(p_action_type, '') = '' or p_normalized_payload is null then
    raise exception 'INVALID_INPUT';
  end if;
  if p_source not in ('line', 'pwa') then
    raise exception 'INVALID_INPUT';
  end if;

  if not exists (
    select 1 from public.household_members
    where household_id = p_household_id and user_id = p_actor_id
  ) then
    raise exception 'NOT_HOUSEHOLD_MEMBER';
  end if;

  -- unique(actor_id, operation_id) makes this naturally idempotent: the
  -- caller (process-line-inbox) derives operation_id deterministically from
  -- the LINE webhook event id, so redelivery/lease-reclaim of the same
  -- event always resolves to the same row instead of creating a duplicate.
  insert into private.pending_actions (
    household_id, actor_id, source, action_type, normalized_payload,
    operation_id, status, expires_at
  )
  values (
    p_household_id, p_actor_id, p_source, p_action_type, p_normalized_payload,
    p_operation_id, 'draft', now() + make_interval(mins => coalesce(p_ttl_minutes, 30))
  )
  on conflict (actor_id, operation_id) do nothing
  returning id into v_id;

  if v_id is not null then
    return jsonb_build_object('pending_action_id', v_id, 'status', 'draft', 'created', true);
  end if;

  select id, status into v_existing
  from private.pending_actions
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return jsonb_build_object('pending_action_id', v_existing.id, 'status', v_existing.status, 'created', false);
end;
$$;

revoke all on function public.server_tx_create_pending_action(uuid, uuid, uuid, text, text, jsonb, int) from public;
revoke all on function public.server_tx_create_pending_action(uuid, uuid, uuid, text, text, jsonb, int) from anon;
revoke all on function public.server_tx_create_pending_action(uuid, uuid, uuid, text, text, jsonb, int) from authenticated;
grant execute on function public.server_tx_create_pending_action(uuid, uuid, uuid, text, text, jsonb, int) to service_role;

create or replace function public.server_tx_confirm_pending_action(
  p_actor_id uuid,
  p_pending_action_id uuid
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_row record;
begin
  if p_actor_id is null or p_pending_action_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  select * into v_row from private.pending_actions where id = p_pending_action_id for update;

  if not found then
    raise exception 'INVALID_INPUT';
  end if;
  if v_row.actor_id <> p_actor_id then
    raise exception 'NOT_HOUSEHOLD_MEMBER';
  end if;

  -- Double-tap safety (06_LINE_INTEGRATION.md #14 "quick reply double tap
  -- => one completion"): a second confirm postback on an already-progressed
  -- row is a success no-op replay, not an error.
  if v_row.status in ('confirmed', 'queued', 'executing', 'succeeded') then
    return jsonb_build_object('pending_action_id', v_row.id, 'status', v_row.status);
  end if;

  if v_row.status <> 'draft' then
    raise exception 'INVALID_INPUT'; -- cancelled/expired/dead: terminal, cannot confirm
  end if;

  if v_row.expires_at <= now() then
    update private.pending_actions set status = 'expired' where id = v_row.id;
    raise exception 'INVALID_INPUT';
  end if;

  update private.pending_actions
  set status = 'confirmed', confirmed_at = now()
  where id = v_row.id;

  return jsonb_build_object('pending_action_id', v_row.id, 'status', 'confirmed');
end;
$$;

revoke all on function public.server_tx_confirm_pending_action(uuid, uuid) from public;
revoke all on function public.server_tx_confirm_pending_action(uuid, uuid) from anon;
revoke all on function public.server_tx_confirm_pending_action(uuid, uuid) from authenticated;
grant execute on function public.server_tx_confirm_pending_action(uuid, uuid) to service_role;

create or replace function public.server_tx_cancel_pending_action(
  p_actor_id uuid,
  p_pending_action_id uuid
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_row record;
begin
  if p_actor_id is null or p_pending_action_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  select * into v_row from private.pending_actions where id = p_pending_action_id for update;

  if not found then
    raise exception 'INVALID_INPUT';
  end if;
  if v_row.actor_id <> p_actor_id then
    raise exception 'NOT_HOUSEHOLD_MEMBER';
  end if;

  if v_row.status = 'cancelled' then
    return jsonb_build_object('pending_action_id', v_row.id, 'status', 'cancelled'); -- double-tap no-op
  end if;

  if v_row.status not in ('draft', 'confirmed', 'queued') then
    raise exception 'INVALID_INPUT'; -- executing/succeeded/expired/dead: too late to cancel
  end if;

  update private.pending_actions set status = 'cancelled' where id = v_row.id;

  return jsonb_build_object('pending_action_id', v_row.id, 'status', 'cancelled');
end;
$$;

revoke all on function public.server_tx_cancel_pending_action(uuid, uuid) from public;
revoke all on function public.server_tx_cancel_pending_action(uuid, uuid) from anon;
revoke all on function public.server_tx_cancel_pending_action(uuid, uuid) from authenticated;
grant execute on function public.server_tx_cancel_pending_action(uuid, uuid) to service_role;
