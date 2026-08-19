-- WP7C: Google Calendar sync queue — queued/processing/done/dead state
-- machine with lease/reclaim/coalesce.
-- docs/design/v6/07_GOOGLE_CALENDAR.md #4-#6; 10_WORK_PACKAGES.md WP7C.
-- Table private.google_sync_jobs (WP1) already enforces via CHECK + a
-- partial unique index that at most one queued-or-processing job exists per
-- calendar_connection_id, and that lease columns are set iff status =
-- 'processing'. These RPCs are the only writers of that table.

-- Coalescing enqueue: one active (queued|processing) job per calendar
-- connection at a time. A second enqueue request while one is queued just
-- appends its reason; while one is processing, it sets rerun_requested so
-- the worker loops again after finishing instead of a second job racing it.
create or replace function private.google_enqueue_sync(
  p_calendar_connection_id uuid,
  p_reason text
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_job record;
  v_new_id uuid;
  v_reason jsonb := to_jsonb(coalesce(p_reason, 'unspecified'));
begin
  if p_calendar_connection_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  select * into v_job
  from private.google_sync_jobs
  where calendar_connection_id = p_calendar_connection_id
    and status in ('queued', 'processing')
  for update;

  if found then
    if v_job.status = 'queued' then
      update private.google_sync_jobs
      set reasons = reasons || jsonb_build_array(v_reason),
          next_attempt_at = least(next_attempt_at, now())
      where id = v_job.id;
    else
      update private.google_sync_jobs
      set rerun_requested = true,
          reasons = reasons || jsonb_build_array(v_reason)
      where id = v_job.id;
    end if;
    return jsonb_build_object('job_id', v_job.id, 'status', v_job.status, 'coalesced', true);
  end if;

  insert into private.google_sync_jobs (calendar_connection_id, status, reasons)
  values (p_calendar_connection_id, 'queued', jsonb_build_array(v_reason))
  returning id into v_new_id;

  return jsonb_build_object('job_id', v_new_id, 'status', 'queued', 'coalesced', false);
end;
$$;

revoke all on function private.google_enqueue_sync(uuid, text) from public;
revoke all on function private.google_enqueue_sync(uuid, text) from anon;
revoke all on function private.google_enqueue_sync(uuid, text) from authenticated;
grant execute on function private.google_enqueue_sync(uuid, text) to service_role;

-- Thin service_role-only wrapper: webhook admission, watch renewal overlap,
-- ensure-calendar-fresh (manual/staleness trigger) and periodic 30m sweep
-- all funnel through this one entry point.
create or replace function public.server_tx_enqueue_google_sync(
  p_calendar_connection_id uuid,
  p_reason text
)
returns jsonb
language sql
security invoker
set search_path = ''
as $$
  select private.google_enqueue_sync(p_calendar_connection_id, p_reason);
$$;

revoke all on function public.server_tx_enqueue_google_sync(uuid, text) from public;
revoke all on function public.server_tx_enqueue_google_sync(uuid, text) from anon;
revoke all on function public.server_tx_enqueue_google_sync(uuid, text) from authenticated;
grant execute on function public.server_tx_enqueue_google_sync(uuid, text) to service_role;

-- Claims the oldest due queued job, or reclaims a job whose lease expired
-- (worker crash) without ever running two workers on the same job
-- concurrently: `for update skip locked` means a second concurrent claim
-- call simply skips a row already locked by the first.
create or replace function public.server_tx_claim_google_sync_job(
  p_worker_id text,
  p_lease_seconds int default 120
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_job_id uuid;
  v_job record;
  v_lease_token uuid := gen_random_uuid();
begin
  if p_worker_id is null or length(p_worker_id) = 0 then
    raise exception 'INVALID_INPUT';
  end if;

  select id into v_job_id
  from private.google_sync_jobs
  where (status = 'queued' and next_attempt_at <= now())
     or (status = 'processing' and lease_until < now())
  order by next_attempt_at
  for update skip locked
  limit 1;

  if v_job_id is null then
    return null;
  end if;

  update private.google_sync_jobs
  set status = 'processing',
      lease_owner = p_worker_id,
      lease_token = v_lease_token,
      lease_until = now() + make_interval(secs => coalesce(p_lease_seconds, 120)),
      attempts = attempts + 1
  where id = v_job_id
  returning * into v_job;

  return jsonb_build_object(
    'job_id', v_job.id,
    'lease_token', v_lease_token,
    'calendar_connection_id', v_job.calendar_connection_id,
    'reasons', v_job.reasons,
    'rerun_requested', v_job.rerun_requested,
    'attempts', v_job.attempts
  );
end;
$$;

revoke all on function public.server_tx_claim_google_sync_job(text, int) from public;
revoke all on function public.server_tx_claim_google_sync_job(text, int) from anon;
revoke all on function public.server_tx_claim_google_sync_job(text, int) from authenticated;
grant execute on function public.server_tx_claim_google_sync_job(text, int) to service_role;

-- Completes a claimed job. Guards against a lease that was already reclaimed
-- by another worker (lease_token mismatch / no longer 'processing') so a
-- slow worker can never clobber a newer worker's outcome for the same job.
create or replace function public.server_tx_complete_google_sync_job(
  p_job_id uuid,
  p_lease_token uuid,
  p_success boolean,
  p_error text
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_job record;
  v_max_attempts constant int := 5;
begin
  select * into v_job
  from private.google_sync_jobs
  where id = p_job_id
  for update;

  if not found then
    raise exception 'INVALID_INPUT';
  end if;

  if v_job.status <> 'processing' or v_job.lease_token is distinct from p_lease_token then
    raise exception 'GOOGLE_SYNC_LEASE_LOST';
  end if;

  if p_success then
    if v_job.rerun_requested then
      update private.google_sync_jobs
      set status = 'queued', lease_owner = null, lease_token = null, lease_until = null,
          rerun_requested = false, next_attempt_at = now(), reasons = '[]'::jsonb
      where id = p_job_id;
      return jsonb_build_object('status', 'queued', 'requeued_for_rerun', true);
    end if;

    update private.google_sync_jobs
    set status = 'done', lease_owner = null, lease_token = null, lease_until = null,
        reasons = '[]'::jsonb
    where id = p_job_id;
    return jsonb_build_object('status', 'done');
  end if;

  if v_job.attempts >= v_max_attempts then
    update private.google_sync_jobs
    set status = 'dead', lease_owner = null, lease_token = null, lease_until = null,
        reasons = reasons || jsonb_build_array(jsonb_build_object('error', coalesce(p_error, 'unknown')))
    where id = p_job_id;
    return jsonb_build_object('status', 'dead');
  end if;

  update private.google_sync_jobs
  set status = 'queued', lease_owner = null, lease_token = null, lease_until = null,
      next_attempt_at = now() + make_interval(secs => (2 ^ least(v_job.attempts, 6))::int * 30),
      reasons = reasons || jsonb_build_array(jsonb_build_object('error', coalesce(p_error, 'unknown')))
  where id = p_job_id;
  return jsonb_build_object('status', 'queued', 'retry_scheduled', true);
end;
$$;

revoke all on function public.server_tx_complete_google_sync_job(uuid, uuid, boolean, text) from public;
revoke all on function public.server_tx_complete_google_sync_job(uuid, uuid, boolean, text) from anon;
revoke all on function public.server_tx_complete_google_sync_job(uuid, uuid, boolean, text) from authenticated;
grant execute on function public.server_tx_complete_google_sync_job(uuid, uuid, boolean, text) to service_role;

-- Periodic 30m sweep (enqueue-periodic-google-sync worker): every active,
-- non-reauth calendar connection whose last incremental sync is stale gets
-- coalesce-enqueued for reason 'periodic'.
create or replace function public.server_tx_enqueue_periodic_google_sync(p_stale_minutes int default 30)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_conn record;
  v_count int := 0;
begin
  for v_conn in
    select id
    from public.calendar_connections
    where active and not reauth_required
      and (last_incremental_sync_at is null
           or last_incremental_sync_at < now() - make_interval(mins => coalesce(p_stale_minutes, 30)))
  loop
    perform private.google_enqueue_sync(v_conn.id, 'periodic');
    v_count := v_count + 1;
  end loop;

  return jsonb_build_object('enqueued_count', v_count);
end;
$$;

revoke all on function public.server_tx_enqueue_periodic_google_sync(int) from public;
revoke all on function public.server_tx_enqueue_periodic_google_sync(int) from anon;
revoke all on function public.server_tx_enqueue_periodic_google_sync(int) from authenticated;
grant execute on function public.server_tx_enqueue_periodic_google_sync(int) to service_role;

-- ensure-calendar-fresh (app-triggered, user-facing): resolves the actor's
-- household calendar connection and, if stale, coalesce-enqueues a sync.
-- Always returns current staleness so the UI can mark the Calendar section
-- stale per #14 without waiting on the sync to finish.
create or replace function public.server_tx_ensure_calendar_fresh(
  p_actor_id uuid,
  p_stale_minutes int default 5
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_conn record;
  v_stale boolean;
  v_enqueued boolean := false;
begin
  if p_actor_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  select household_id into v_household_id
  from public.household_members
  where user_id = p_actor_id;

  if v_household_id is null then
    raise exception 'NOT_HOUSEHOLD_MEMBER';
  end if;

  select * into v_conn
  from public.calendar_connections
  where household_id = v_household_id and active
  order by created_at
  limit 1;

  if not found then
    return jsonb_build_object('calendar_connection_id', null, 'stale', true, 'enqueued', false, 'reauth_required', false);
  end if;

  v_stale := v_conn.last_incremental_sync_at is null
    or v_conn.last_incremental_sync_at < now() - make_interval(mins => coalesce(p_stale_minutes, 5));

  if v_stale and not v_conn.reauth_required then
    perform private.google_enqueue_sync(v_conn.id, 'manual');
    v_enqueued := true;
  end if;

  return jsonb_build_object(
    'calendar_connection_id', v_conn.id,
    'stale', v_stale,
    'enqueued', v_enqueued,
    'reauth_required', v_conn.reauth_required,
    'last_incremental_sync_at', v_conn.last_incremental_sync_at
  );
end;
$$;

revoke all on function public.server_tx_ensure_calendar_fresh(uuid, int) from public;
revoke all on function public.server_tx_ensure_calendar_fresh(uuid, int) from anon;
revoke all on function public.server_tx_ensure_calendar_fresh(uuid, int) from authenticated;
grant execute on function public.server_tx_ensure_calendar_fresh(uuid, int) to service_role;
