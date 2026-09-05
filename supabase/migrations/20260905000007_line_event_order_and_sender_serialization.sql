-- Q4/Q70/Q71 follow-up hardening.
-- Revision CAS prevents overlapping stale writes; provider event ordering also
-- prevents an older LINE event that arrives late from rolling back a newer
-- correction.  Claiming at most one live event per LINE sender removes the
-- avoidable same-sender race between worker invocations.

alter table private.pending_actions
  add column if not exists last_line_event_timestamp bigint not null default 0;

do $$ begin
  alter table private.pending_actions
    add constraint pending_actions_line_event_timestamp_nonnegative
    check (last_line_event_timestamp >= 0);
exception when duplicate_object then null;
end $$;

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

  with eligible as (
    select w.id,
           row_number() over (
             partition by coalesce(w.source_external_user_id, w.id::text)
             order by coalesce((w.payload->>'timestamp')::bigint, 0), w.received_at, w.id
           ) as sender_rank
    from private.webhook_inbox w
    where (
      (w.status = 'received' and w.next_attempt_at <= now())
      or (w.status = 'processing' and w.lease_until < now())
    )
      and not exists (
        select 1
        from private.webhook_inbox busy
        where busy.id <> w.id
          and busy.status = 'processing'
          and busy.lease_until >= now()
          and busy.source_external_user_id is not distinct from w.source_external_user_id
      )
  ), claimable as (
    select w.id
    from private.webhook_inbox w
    join eligible e on e.id = w.id and e.sender_rank = 1
    order by coalesce((w.payload->>'timestamp')::bigint, 0), w.received_at, w.id
    for update of w skip locked
    limit p_limit
  ), updated as (
    update private.webhook_inbox w
    set status = 'processing',
        attempts = w.attempts + 1,
        lease_owner = p_worker_id,
        lease_token = gen_random_uuid(),
        lease_until = now() + make_interval(secs => p_lease_seconds),
        last_started_at = now()
    from claimable
    where w.id = claimable.id
    returning w.id, w.provider_event_id, w.source_external_user_id,
              w.payload, w.attempts, w.lease_token
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

revoke all on function public.server_tx_claim_webhook_inbox_batch(text, int, int) from public, anon, authenticated;
grant execute on function public.server_tx_claim_webhook_inbox_batch(text, int, int) to service_role;

-- Supersede the revision-only edit contract.  A real LINE edit must prove
-- both the row version it read and the provider event timestamp responsible
-- for this correction.
drop function if exists public.server_tx_update_pending_action(uuid, uuid, text, jsonb, bigint);

create function public.server_tx_update_pending_action(
  p_actor_id uuid,
  p_pending_action_id uuid,
  p_action_type text,
  p_normalized_payload jsonb,
  p_expected_revision bigint,
  p_line_event_timestamp bigint
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_row record;
  v_state record;
begin
  if p_actor_id is null or p_pending_action_id is null
     or p_expected_revision is null or p_expected_revision < 0
     or p_line_event_timestamp is null or p_line_event_timestamp <= 0
     or p_action_type not in (
       'shopping_item_add', 'task_create_once', 'request_create',
       'assignment_change_request', 'line_multi_intent_review'
     )
     or p_normalized_payload is null
     or jsonb_typeof(p_normalized_payload) <> 'object' then
    raise exception 'INVALID_INPUT';
  end if;

  -- Lock first so the reason for rejection is deterministic and a concurrent
  -- edit cannot move between the revision/event-order checks and the update.
  select actor_id, source, status, expires_at, revision,
         last_line_event_timestamp
    into v_state
  from private.pending_actions
  where id = p_pending_action_id
  for update;

  if not found or v_state.actor_id <> p_actor_id
     or v_state.source <> 'line'
     or v_state.status <> 'draft'
     or v_state.expires_at <= now() then
    raise exception 'PENDING_ACTION_NOT_EDITABLE';
  end if;
  if v_state.revision <> p_expected_revision
     or p_line_event_timestamp <= v_state.last_line_event_timestamp then
    raise exception 'PENDING_ACTION_STALE';
  end if;

  update private.pending_actions
  set action_type = p_action_type,
      normalized_payload = p_normalized_payload,
      revision = revision + 1,
      last_line_event_timestamp = p_line_event_timestamp,
      updated_at = now()
  where id = p_pending_action_id
  returning id, action_type, normalized_payload, status, expires_at, revision,
            last_line_event_timestamp
    into v_row;

  return jsonb_build_object(
    'id', v_row.id,
    'action_type', v_row.action_type,
    'normalized_payload', v_row.normalized_payload,
    'status', v_row.status,
    'expires_at', v_row.expires_at,
    'revision', v_row.revision,
    'last_line_event_timestamp', v_row.last_line_event_timestamp
  );
end;
$$;

revoke all on function public.server_tx_update_pending_action(uuid, uuid, text, jsonb, bigint, bigint)
  from public, anon, authenticated;
grant execute on function public.server_tx_update_pending_action(uuid, uuid, text, jsonb, bigint, bigint)
  to service_role;
