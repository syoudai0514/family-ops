-- WP9: send-notifications' outbox drain -- lease/reclaim/dead-letter for
-- private.notification_outbox (channel='line'), mirroring the
-- webhook_inbox/pending_actions lease pattern from
-- 20260819000041_line_inbox_and_pending_action_rpcs.sql /
-- 20260819000042_pending_action_execution_rpcs.sql, and reusing WP1's
-- existing quota reserve/commit/release/mark_ambiguous RPCs
-- (20260819000009_server_tx_functions.sql,
-- 20260819000015_line_quota_threshold_fix.sql) rather than re-implementing
-- quota accounting. docs/design/v6/06_LINE_INTEGRATION.md #10/#10A/#10B/#13;
-- 09_API_AND_EDGE_FUNCTIONS.md #6 "send-notifications", #18 "LINE quota
-- refresh".

-- ---------------------------------------------------------------------------
-- Pre-claim sweeps
-- ---------------------------------------------------------------------------
-- An expired scheduled message must never deliver late
-- (06_LINE_INTEGRATION.md #10B "expired scheduled reminder never delivers
-- late"), and an outbox row whose retry-key safety window (23h,
-- ENV_TEMPLATE.md LINE_RETRY_KEY_SAFETY_HOURS=23) has fully elapsed without
-- a definitive provider result can never call the provider again for that
-- key (#10B "after retry expiry, never call provider again for ambiguous
-- delivery"). Both are swept before any row becomes claimable so a worker
-- never wastes a claim slot on a row that must not be sent.
create or replace function private.fn_sweep_notification_outbox_expirations()
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  update private.notification_outbox
  set status = 'dead', last_error = 'business_expires_at passed while queued',
      lease_owner = null, lease_token = null, lease_until = null
  where status = 'queued'
    and business_expires_at is not null
    and business_expires_at <= now();

  update private.notification_outbox
  set status = 'delivery_unknown',
      last_error = 'provider_retry_expires_at passed before a definitive provider result',
      lease_owner = null, lease_token = null, lease_until = null
  where status in ('queued', 'sending')
    and provider_retry_expires_at is not null
    and provider_retry_expires_at <= now();
end;
$$;

revoke all on function private.fn_sweep_notification_outbox_expirations() from public;
revoke all on function private.fn_sweep_notification_outbox_expirations() from anon;
revoke all on function private.fn_sweep_notification_outbox_expirations() from authenticated;
grant execute on function private.fn_sweep_notification_outbox_expirations() to service_role;

-- ---------------------------------------------------------------------------
-- claim
-- ---------------------------------------------------------------------------
-- Assigns the fixed provider retry key on a row's *first* claim only
-- (docs/design/v6/06_LINE_INTEGRATION.md #10 "fixed provider retry key from
-- first attempt", #10B "retries keep identical recipient/body/key") --
-- coalesce() leaves an already-set key/first-attempt/expiry untouched on a
-- reclaim. Resolves the recipient's active LINE user id inline (private
-- schema is never reached from Edge Function Data API code, only through
-- public.server_tx_* -- docs/design/v6/15_DDL_CONTRACT.md #8) so the caller
-- can decide "no link -> definitive failure, never attempted" without a
-- second round trip.
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
      and (
        (status = 'queued' and next_attempt_at <= now())
        or (status = 'sending' and lease_until < now()) -- reclaim a dead worker's lease
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
      o.quota_reservation_id, o.lease_token
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
    'line_user_id', l.line_user_id
  ) order by u.attempts), '[]'::jsonb)
  into v_result
  from updated u
  left join private.line_user_links l
    on l.user_id = u.recipient_user_id and l.status = 'active';

  return v_result;
end;
$$;

revoke all on function public.server_tx_claim_notification_outbox_batch(text, int, int) from public;
revoke all on function public.server_tx_claim_notification_outbox_batch(text, int, int) from anon;
revoke all on function public.server_tx_claim_notification_outbox_batch(text, int, int) from authenticated;
grant execute on function public.server_tx_claim_notification_outbox_batch(text, int, int) to service_role;

-- ---------------------------------------------------------------------------
-- complete (2xx, or 409-same-retry-key reconciled -- both "accepted")
-- ---------------------------------------------------------------------------
create or replace function public.server_tx_complete_notification_outbox_item(
  p_id uuid,
  p_lease_token uuid
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_row record;
begin
  if p_id is null or p_lease_token is null then
    raise exception 'INVALID_INPUT';
  end if;

  select * into v_row
  from private.notification_outbox
  where id = p_id and lease_token = p_lease_token and status = 'sending'
  for update;

  if not found then
    return jsonb_build_object('ok', false); -- lease already reclaimed elsewhere
  end if;

  update private.notification_outbox
  set status = 'sent', sent_at = now(),
      lease_owner = null, lease_token = null, lease_until = null
  where id = p_id;

  if v_row.quota_reservation_id is not null then
    perform public.server_tx_commit_line_quota_reservation(v_row.quota_reservation_id);
  end if;

  return jsonb_build_object('ok', true, 'status', 'sent');
end;
$$;

revoke all on function public.server_tx_complete_notification_outbox_item(uuid, uuid) from public;
revoke all on function public.server_tx_complete_notification_outbox_item(uuid, uuid) from anon;
revoke all on function public.server_tx_complete_notification_outbox_item(uuid, uuid) from authenticated;
grant execute on function public.server_tx_complete_notification_outbox_item(uuid, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- fail -- one entrypoint, four documented outcomes
-- (docs/design/v6/06_LINE_INTEGRATION.md #10A "Result" list / #10A "429" /
-- #10B "Rules"):
--   'definitive'    permanent provider rejection (bad recipient, blocked,
--                   malformed) -- never retry; release any reservation.
--   'quota_fallback' at/over effective hard limit or an explicit
--                   monthly-limit 429 -- "quota unavailable => fallback +
--                   in-app history"; release any reservation, never dead.
--   'ambiguous'     timeout/5xx -- delivery truly unknown; mark the quota
--                   reservation ambiguous (stays counted, LQA06) and keep
--                   retrying the SAME key until provider_retry_expires_at,
--                   after which -> delivery_unknown (terminal, no more
--                   provider calls).
--   'transient'     rate-limited but definitely-not-sent 429, or a network
--                   error before any response -- reservation is untouched
--                   (still 'reserved', so a retried claim's quota state
--                   needs no new reservation) and the SAME retry key is
--                   reused; falls to 'dead' (+release) once max attempts or
--                   the retry-key window is exhausted, whichever first.
create or replace function public.server_tx_fail_notification_outbox_item(
  p_id uuid,
  p_lease_token uuid,
  p_error text,
  p_outcome text,
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
  v_reservation_status text;
  v_new_status text;
begin
  if p_id is null or p_lease_token is null then
    raise exception 'INVALID_INPUT';
  end if;
  if p_outcome not in ('definitive', 'quota_fallback', 'ambiguous', 'transient') then
    raise exception 'INVALID_INPUT';
  end if;

  select * into v_row
  from private.notification_outbox
  where id = p_id and lease_token = p_lease_token and status = 'sending'
  for update;

  if not found then
    return jsonb_build_object('ok', false); -- lease already reclaimed elsewhere
  end if;

  if v_row.quota_reservation_id is not null then
    select status into v_reservation_status
    from private.line_quota_reservations
    where id = v_row.quota_reservation_id
    for update;
  end if;

  if p_outcome in ('definitive', 'quota_fallback') then
    if v_row.quota_reservation_id is not null and v_reservation_status in ('reserved', 'ambiguous') then
      perform public.server_tx_release_line_quota_reservation(v_row.quota_reservation_id);
    end if;
    v_new_status := case when p_outcome = 'definitive' then 'dead' else 'fallback' end;
    update private.notification_outbox
    set status = v_new_status, last_error = p_error,
        lease_owner = null, lease_token = null, lease_until = null
    where id = p_id;
    return jsonb_build_object('ok', true, 'status', v_new_status);
  end if;

  if p_outcome = 'ambiguous' and v_row.quota_reservation_id is not null and v_reservation_status = 'reserved' then
    perform public.server_tx_mark_line_quota_ambiguous(v_row.quota_reservation_id);
  end if;

  -- Shared tail for 'ambiguous' and 'transient': retry-window/attempt-cap
  -- exhaustion decides the terminal state; otherwise requeue with the same
  -- retry key intact (only lease/next_attempt_at/attempts-derived backoff
  -- change -- provider_retry_key/provider_first_attempt_at/
  -- provider_retry_expires_at are never touched here).
  if v_row.provider_retry_expires_at is not null and v_row.provider_retry_expires_at <= now() then
    v_new_status := 'delivery_unknown';
    update private.notification_outbox
    set status = v_new_status, last_error = p_error,
        lease_owner = null, lease_token = null, lease_until = null
    where id = p_id;
  elsif p_outcome = 'transient' and v_row.attempts >= coalesce(p_max_attempts, 5) then
    if v_row.quota_reservation_id is not null and v_reservation_status in ('reserved', 'ambiguous') then
      perform public.server_tx_release_line_quota_reservation(v_row.quota_reservation_id);
    end if;
    v_new_status := 'dead';
    update private.notification_outbox
    set status = v_new_status, last_error = p_error,
        lease_owner = null, lease_token = null, lease_until = null
    where id = p_id;
  else
    v_new_status := 'queued';
    update private.notification_outbox
    set status = v_new_status, last_error = p_error,
        next_attempt_at = now() + make_interval(secs => coalesce(p_retry_delay_seconds, 60) * v_row.attempts),
        lease_owner = null, lease_token = null, lease_until = null
    where id = p_id;
  end if;

  return jsonb_build_object('ok', true, 'status', v_new_status);
end;
$$;

revoke all on function public.server_tx_fail_notification_outbox_item(uuid, uuid, text, text, int, int) from public;
revoke all on function public.server_tx_fail_notification_outbox_item(uuid, uuid, text, text, int, int) from anon;
revoke all on function public.server_tx_fail_notification_outbox_item(uuid, uuid, text, text, int, int) from authenticated;
grant execute on function public.server_tx_fail_notification_outbox_item(uuid, uuid, text, text, int, int) to service_role;

-- ---------------------------------------------------------------------------
-- provider quota usage refresh (docs/design/v6/09_API_AND_EDGE_FUNCTIONS.md
-- #18 "LINE quota refresh": "refresh target monthly limit + total sent
-- usage at least every 15m while LINE outbox exists")
-- ---------------------------------------------------------------------------
create or replace function public.server_tx_refresh_line_quota_provider_usage(
  p_provider_limit int,
  p_provider_consumed int
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_billing_month date := date_trunc('month', (now() at time zone 'Asia/Tokyo'))::date;
begin
  if p_provider_limit is null or p_provider_limit < 0
     or p_provider_consumed is null or p_provider_consumed < 0 then
    raise exception 'INVALID_INPUT';
  end if;

  insert into private.line_quota_state (billing_month, provider_limit, provider_consumed, last_provider_refresh_at)
  values (v_billing_month, p_provider_limit, p_provider_consumed, now())
  on conflict (billing_month) do update set
    provider_limit = excluded.provider_limit,
    provider_consumed = excluded.provider_consumed,
    last_provider_refresh_at = now();

  return jsonb_build_object('billing_month', v_billing_month, 'refreshed_at', now());
end;
$$;

revoke all on function public.server_tx_refresh_line_quota_provider_usage(int, int) from public;
revoke all on function public.server_tx_refresh_line_quota_provider_usage(int, int) from anon;
revoke all on function public.server_tx_refresh_line_quota_provider_usage(int, int) from authenticated;
grant execute on function public.server_tx_refresh_line_quota_provider_usage(int, int) to service_role;

-- Read-only staleness check so the Edge Function can decide whether a
-- refresh call is due without ever touching private.line_quota_state
-- directly (15_DDL_CONTRACT.md #8). Never inserts -- a month with no rows
-- yet reports 'stale' (last_provider_refresh_at null) so the very first run
-- of a month always attempts one real refresh before sending anything.
create or replace function public.server_tx_get_line_quota_refresh_state()
returns jsonb
language sql
stable
security invoker
set search_path = ''
as $$
  select coalesce(
    (
      select jsonb_build_object(
        'billing_month', billing_month,
        'provider_limit', provider_limit,
        'provider_consumed', provider_consumed,
        'local_counted_success', local_counted_success,
        'last_provider_refresh_at', last_provider_refresh_at,
        'stale', (last_provider_refresh_at is null or last_provider_refresh_at <= now() - interval '15 minutes')
      )
      from private.line_quota_state
      where billing_month = date_trunc('month', (now() at time zone 'Asia/Tokyo'))::date
    ),
    jsonb_build_object(
      'billing_month', date_trunc('month', (now() at time zone 'Asia/Tokyo'))::date,
      'provider_limit', null,
      'provider_consumed', null,
      'local_counted_success', 0,
      'last_provider_refresh_at', null,
      'stale', true
    )
  );
$$;

revoke all on function public.server_tx_get_line_quota_refresh_state() from public;
revoke all on function public.server_tx_get_line_quota_refresh_state() from anon;
revoke all on function public.server_tx_get_line_quota_refresh_state() from authenticated;
grant execute on function public.server_tx_get_line_quota_refresh_state() to service_role;
