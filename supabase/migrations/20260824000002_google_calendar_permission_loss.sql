-- Permission loss is not refresh-token loss.  Calendar API 403 is checked
-- against calendarList by the Edge worker; this migration records that
-- decision atomically and stops any already-queued provider work.

alter table private.family_ops_calendar_mirrors
  drop constraint if exists family_ops_calendar_mirrors_sync_state_check;
alter table private.family_ops_calendar_mirrors
  add constraint family_ops_calendar_mirrors_sync_state_check
  check (sync_state in ('pending', 'processing', 'synced', 'failed', 'deleted', 'blocked'));

alter table private.family_ops_calendar_target_deletions
  drop constraint if exists family_ops_calendar_target_deletions_sync_state_check;
alter table private.family_ops_calendar_target_deletions
  add constraint family_ops_calendar_target_deletions_sync_state_check
  check (sync_state in ('pending', 'processing', 'deleted', 'failed', 'blocked'));

create table if not exists private.family_ops_calendar_orphaned_mirrors (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  calendar_connection_id uuid not null references public.calendar_connections(id) on delete cascade,
  projection_key text not null,
  provider_event_id text not null,
  reason text not null,
  observed_at timestamptz not null default now(),
  unique (calendar_connection_id, projection_key, provider_event_id)
);
revoke all on private.family_ops_calendar_orphaned_mirrors from public, anon, authenticated;

-- Preserve the OAuth v2 API while separating an absent calendar from a
-- credential that truly needs a new grant.  The v2 body performs all state,
-- credential and candidate work atomically; this wrapper only clears the
-- legacy row-level reauth marker from inactive historical candidates after a
-- successful OAuth completion.
alter function public.server_tx_complete_google_oauth_v2(text, text, text, int, text[], jsonb)
  rename to server_tx_complete_google_oauth_v2_legacy;

create or replace function public.server_tx_complete_google_oauth_v2(
  p_state_hash text,
  p_google_subject text,
  p_encrypted_refresh_token text,
  p_encryption_version int,
  p_scopes text[],
  p_calendar_candidates jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_result jsonb;
  v_household_id uuid;
  v_previous_target_id uuid;
begin
  -- Keep this before the legacy completion clears a target whose calendar is
  -- absent from the refreshed candidate list.  A later explicit selection
  -- then correctly has no old target to delete, so we must preserve the old
  -- provider ids here for audit and prevent the stale outbox work from being
  -- accidentally retried.
  select id into v_previous_target_id
  from public.calendar_connections
  where household_id = (
      select household_id from private.google_oauth_states where state_hash = p_state_hash
    )
    and provider = 'google'
    and is_family_write_target
  for update;

  v_result := public.server_tx_complete_google_oauth_v2_legacy(
    p_state_hash, p_google_subject, p_encrypted_refresh_token,
    p_encryption_version, p_scopes, p_calendar_candidates
  );
  v_household_id := (v_result ->> 'household_id')::uuid;

  if v_previous_target_id is not null
     and exists (
       select 1 from public.calendar_connections
       where id = v_previous_target_id and not active
     ) then
    -- Google did not return this explicit target after a successful OAuth
    -- exchange.  We no longer have authority to delete its events, so retain
    -- their stable ids as orphaned mirrors rather than pretending a later
    -- target switch can clean them up.
    insert into private.family_ops_calendar_orphaned_mirrors (
      household_id, calendar_connection_id, projection_key, provider_event_id, reason
    )
    select household_id, calendar_connection_id, projection_key, provider_event_id,
      'calendar missing or no longer eligible after OAuth refresh'
    from private.family_ops_calendar_mirrors
    where calendar_connection_id = v_previous_target_id
      and provider_event_id is not null
    on conflict (calendar_connection_id, projection_key, provider_event_id)
      do update set reason = excluded.reason, observed_at = now();

    update private.family_ops_calendar_mirrors
    set sync_state = 'blocked', lease_token = null, lease_until = null,
        last_error = 'calendar missing or no longer eligible after OAuth refresh', updated_at = now()
    where calendar_connection_id = v_previous_target_id
      and sync_state in ('pending', 'processing', 'failed');

    update private.family_ops_calendar_target_deletions
    set sync_state = 'blocked', lease_token = null, lease_until = null,
        last_error = 'calendar missing or no longer eligible after OAuth refresh', updated_at = now()
    where calendar_connection_id = v_previous_target_id
      and sync_state in ('pending', 'processing', 'failed');
  end if;

  -- A successful OAuth completion proves the shared credential is healthy.
  -- Missing historical candidates stay inactive, but they must not make the
  -- settings page indefinitely request another OAuth connection.
  update public.calendar_connections
  set reauth_required = false
  where household_id = v_household_id
    and provider = 'google'
    and not active;

  return v_result;
end;
$$;

revoke all on function public.server_tx_complete_google_oauth_v2(text, text, text, int, text[], jsonb) from public, anon, authenticated;
grant execute on function public.server_tx_complete_google_oauth_v2(text, text, text, int, text[], jsonb) to service_role;
revoke all on function public.server_tx_complete_google_oauth_v2_legacy(text, text, text, int, text[], jsonb) from public, anon, authenticated;

create or replace function public.server_tx_revalidate_google_calendar_eligibility(
  p_calendar_connection_id uuid,
  p_is_eligible boolean,
  p_reason text
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_connection public.calendar_connections%rowtype;
  v_was_target boolean := false;
begin
  if p_calendar_connection_id is null or p_is_eligible is null then
    raise exception 'INVALID_INPUT';
  end if;

  select * into v_connection
  from public.calendar_connections
  where id = p_calendar_connection_id and provider = 'google'
  for update;
  if not found then
    raise exception 'INVALID_INPUT';
  end if;

  if p_is_eligible then
    insert into private.google_sync_state (calendar_connection_id, last_error)
    values (v_connection.id, left(coalesce(p_reason, 'Google Calendar 403 rechecked as eligible'), 1000))
    on conflict (calendar_connection_id) do update
      set last_error = excluded.last_error;
    return jsonb_build_object('eligible', true, 'deactivated', false);
  end if;

  v_was_target := v_connection.is_family_write_target;
  if v_was_target then
    -- We cannot safely delete after Google has removed write permission. Keep
    -- a stable-id audit record instead; a normal eligible target switch still
    -- uses family_ops_calendar_target_deletions to delete old mirrors first.
    insert into private.family_ops_calendar_orphaned_mirrors (
      household_id, calendar_connection_id, projection_key, provider_event_id, reason
    )
    select household_id, calendar_connection_id, projection_key, provider_event_id,
      left(coalesce(p_reason, 'calendar eligibility lost'), 1000)
    from private.family_ops_calendar_mirrors
    where calendar_connection_id = v_connection.id
      and provider_event_id is not null
    on conflict (calendar_connection_id, projection_key, provider_event_id)
      do update set reason = excluded.reason, observed_at = now();
  end if;

  update public.calendar_connections
  set active = false,
      -- This is a calendar-level eligibility loss, not invalid_grant.
      reauth_required = false,
      is_family_write_target = false
  where id = v_connection.id;

  update private.google_sync_jobs
  set status = 'dead', lease_owner = null, lease_token = null, lease_until = null,
      reasons = reasons || jsonb_build_array(jsonb_build_object('error', coalesce(p_reason, 'calendar eligibility lost')))
  where calendar_connection_id = v_connection.id
    and status in ('queued', 'processing');

  update private.family_ops_calendar_mirrors
  set sync_state = 'blocked', lease_token = null, lease_until = null,
      last_error = left(coalesce(p_reason, 'calendar eligibility lost'), 1000), updated_at = now()
  where calendar_connection_id = v_connection.id
    and sync_state in ('pending', 'processing', 'failed');

  update private.family_ops_calendar_target_deletions
  set sync_state = 'blocked', lease_token = null, lease_until = null,
      last_error = left(coalesce(p_reason, 'calendar eligibility lost'), 1000), updated_at = now()
  where calendar_connection_id = v_connection.id
    and sync_state in ('pending', 'processing', 'failed');

  insert into private.google_sync_state (calendar_connection_id, last_error)
  values (v_connection.id, left(coalesce(p_reason, 'calendar eligibility lost'), 1000))
  on conflict (calendar_connection_id) do update
    set last_error = excluded.last_error;

  return jsonb_build_object('eligible', false, 'deactivated', true, 'was_family_write_target', v_was_target);
end;
$$;

revoke all on function public.server_tx_revalidate_google_calendar_eligibility(uuid, boolean, text) from public, anon, authenticated;
grant execute on function public.server_tx_revalidate_google_calendar_eligibility(uuid, boolean, text) to service_role;
