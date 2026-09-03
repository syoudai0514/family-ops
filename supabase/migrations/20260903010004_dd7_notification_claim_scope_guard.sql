-- WP-DD7: production LINE sender scope guard.
--
-- Preserve the existing proven worker semantics (expiry sweep, fixed provider
-- retry key, lease/reclaim, quota reservation and ambiguity handling) while
-- making the DD3A split explicit: direct test-context delivery belongs only to
-- private.test_delivery_outbox and can never be claimed by the production LINE
-- outbox worker.  in_app_only intents likewise cannot accidentally call LINE.

create or replace function public.server_tx_claim_notification_outbox_batch(
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

  perform private.fn_sweep_notification_outbox_expirations();

  with claimable as (
    select id
    from private.notification_outbox
    where channel = 'line'
      and test_context_id is null
      and coalesce(urgency, 'immediate') <> 'in_app_only'
      and (
        (status = 'queued' and next_attempt_at <= now())
        or (status = 'sending' and lease_until < now())
      )
    order by priority = 'critical' desc, next_attempt_at
    for update skip locked
    limit p_limit
  ),
  updated as (
    update private.notification_outbox o
    set status = 'sending',
        attempts = o.attempts + 1,
        lease_owner = p_worker_id,
        lease_token = gen_random_uuid(),
        lease_until = now() + make_interval(secs => p_lease_seconds),
        last_started_at = now(),
        provider_first_attempt_at = coalesce(o.provider_first_attempt_at, now()),
        provider_retry_key = coalesce(o.provider_retry_key, gen_random_uuid()),
        provider_retry_expires_at = coalesce(o.provider_retry_expires_at, now() + interval '23 hours')
    from claimable
    where o.id = claimable.id
    returning o.id, o.household_id, o.recipient_user_id, o.type, o.payload, o.dedup_key,
      o.priority, o.attempts, o.provider_retry_key, o.business_expires_at,
      o.quota_reservation_id, o.lease_token,
      o.notification_kind, o.urgency, o.safety_class, o.bundle_key
  )
  select coalesce(jsonb_agg(jsonb_build_object(
    'id', u.id,
    'household_id', u.household_id,
    'recipient_user_id', u.recipient_user_id,
    'type', u.type,
    'payload', u.payload,
    'dedup_key', u.dedup_key,
    'priority', u.priority,
    'attempts', u.attempts,
    'provider_retry_key', u.provider_retry_key,
    'business_expires_at', u.business_expires_at,
    'quota_reservation_id', u.quota_reservation_id,
    'lease_token', u.lease_token,
    'notification_kind', u.notification_kind,
    'urgency', u.urgency,
    'safety_class', u.safety_class,
    'bundle_key', u.bundle_key,
    'line_user_id', l.line_user_id
  ) order by u.attempts), '[]'::jsonb)
  into v_result
  from updated u
  left join private.line_user_links l
    on l.user_id = u.recipient_user_id and l.status = 'active';

  return v_result;
end;
$$;

revoke all on function public.server_tx_claim_notification_outbox_batch(text, int, int)
  from public, anon, authenticated;
grant execute on function public.server_tx_claim_notification_outbox_batch(text, int, int)
  to service_role;
