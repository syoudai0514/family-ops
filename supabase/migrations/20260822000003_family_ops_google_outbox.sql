-- UX v3.3: Family Ops -> Google Calendar is an asynchronous mirror.
--
-- The Family Ops task/recurrence records remain canonical.  This migration
-- deliberately records desired Google state in a private outbox; no task
-- mutation makes an HTTP call and a provider failure can therefore never
-- roll back a confirmed household mutation.

alter table public.calendar_connections
  add column if not exists is_family_write_target boolean not null default false;

create unique index if not exists calendar_connections_one_family_write_target
  on public.calendar_connections (household_id)
  where is_family_write_target;

-- Existing households used the single eligible calendar selected at OAuth
-- connection time.  Preserve that behaviour deterministically while making
-- the choice explicit for all later writes.
with first_active as (
  select distinct on (household_id) id
  from public.calendar_connections
  where active and not reauth_required
  order by household_id, created_at, id
)
update public.calendar_connections c
set is_family_write_target = true
from first_active f
where c.id = f.id
  and not exists (
    select 1 from public.calendar_connections already
    where already.household_id = c.household_id and already.is_family_write_target
  );

create or replace function private.fn_default_family_write_target()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.active and not new.reauth_required and not exists (
    select 1 from public.calendar_connections
    where household_id = new.household_id and is_family_write_target
  ) then
    new.is_family_write_target := true;
  end if;
  return new;
end;
$$;

drop trigger if exists calendar_connections_default_family_write_target on public.calendar_connections;
create trigger calendar_connections_default_family_write_target
  before insert on public.calendar_connections
  for each row execute function private.fn_default_family_write_target();

alter table public.task_instances
  add column if not exists calendar_visibility text not null default 'hidden'
    check (calendar_visibility in ('transport', 'special', 'hidden')),
  add column if not exists calendar_ends_at timestamptz null;

update public.task_instances ti
set calendar_visibility = td.calendar_visibility
from public.task_definitions td
where ti.task_definition_id = td.id
  and ti.household_id = td.household_id
  and ti.calendar_visibility = 'hidden';

create or replace function private.fn_copy_task_calendar_visibility()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.task_definition_id is not null then
    select calendar_visibility into new.calendar_visibility
    from public.task_definitions
    where household_id = new.household_id and id = new.task_definition_id;
  end if;
  -- Transport definitions are intentionally morning/evening phased but are
  -- the one routine-shaped domain that must still mirror to Google.
  if new.routine_phase in ('morning', 'evening') and new.calendar_visibility <> 'transport' then
    new.calendar_visibility := 'hidden';
  end if;
  return new;
end;
$$;

drop trigger if exists task_instances_copy_calendar_visibility on public.task_instances;
create trigger task_instances_copy_calendar_visibility
  before insert or update of task_definition_id, routine_phase on public.task_instances
  for each row execute function private.fn_copy_task_calendar_visibility();

alter table private.family_ops_calendar_mirrors
  add column if not exists desired_action text not null default 'upsert'
    check (desired_action in ('upsert', 'delete')),
  add column if not exists attempts integer not null default 0,
  add column if not exists next_attempt_at timestamptz not null default now(),
  add column if not exists lease_token uuid,
  add column if not exists lease_until timestamptz,
  add column if not exists provider_etag text;

alter table private.family_ops_calendar_mirrors
  drop constraint if exists family_ops_calendar_mirrors_sync_state_check;
alter table private.family_ops_calendar_mirrors
  add constraint family_ops_calendar_mirrors_sync_state_check
  check (sync_state in ('pending', 'processing', 'synced', 'failed', 'deleted'));

create index if not exists family_ops_calendar_mirrors_outbox_idx
  on private.family_ops_calendar_mirrors (sync_state, next_attempt_at)
  where sync_state in ('pending', 'failed');

-- P/M labels are household-stable slots, not a per-device "me" colour.
-- Membership ordering is immutable in normal operation and gives a
-- deterministic label even before a family chooses profile colours.
create or replace function private.family_ops_member_token(p_household_id uuid, p_user_id uuid)
returns text
language sql
stable
security definer
set search_path = ''
as $$
  select case ranked.position
    when 1 then 'P'
    when 2 then 'M'
    else '担当'
  end
  from (
    select hm.user_id, row_number() over (order by hm.joined_at, hm.user_id)::integer as position
    from public.household_members hm
    where hm.household_id = p_household_id
  ) ranked
  where ranked.user_id = p_user_id;
$$;

-- Queue exactly one stable projection. Transport has one key per local day;
-- a special task has one key per task instance.  No title or title/date
-- lookup appears anywhere in this path.
create or replace function private.enqueue_family_ops_calendar_projection(
  p_household_id uuid,
  p_task_definition_id uuid,
  p_local_date date,
  p_task_instance_id uuid
)
returns void
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_visibility text;
  v_connection_id uuid;
  v_projection_key text;
  v_kind text;
  v_desired_action text := 'upsert';
begin
  if p_household_id is null or p_local_date is null then return; end if;

  if p_task_definition_id is not null then
    select calendar_visibility into v_visibility
    from public.task_definitions
    where household_id = p_household_id and id = p_task_definition_id;
  else
    select calendar_visibility into v_visibility
    from public.task_instances
    where household_id = p_household_id and id = p_task_instance_id;
  end if;
  if coalesce(v_visibility, 'hidden') = 'hidden' then return; end if;

  select id into v_connection_id
  from public.calendar_connections
  where household_id = p_household_id
    and is_family_write_target and active and not reauth_required
  order by created_at, id
  limit 1;
  if v_connection_id is null then return; end if;

  if v_visibility = 'transport' then
    v_kind := 'transport';
    v_projection_key := 'transport:' || p_local_date::text;
    -- A day with neither canonical assignee has no mirror.  Completed
    -- history remains untouched; only the provider mirror is removed.
    if not exists (
      select 1
      from public.task_instances ti
      join public.task_definitions td
        on td.household_id = ti.household_id and td.id = ti.task_definition_id
      where ti.household_id = p_household_id
        and ti.scheduled_date = p_local_date
        and ti.status <> 'cancelled'
        and td.calendar_visibility = 'transport'
        and ti.planned_assignee_id is not null
    ) then
      v_desired_action := 'delete';
    end if;
  else
    v_kind := 'special';
    v_projection_key := 'special:' || p_task_instance_id::text;
    if not exists (
      select 1 from public.task_instances
      where household_id = p_household_id and id = p_task_instance_id
        and status <> 'cancelled' and calendar_visibility = 'special'
    ) then
      v_desired_action := 'delete';
    end if;
  end if;

  insert into private.family_ops_calendar_mirrors (
    household_id, projection_key, kind, local_date, task_instance_id,
    calendar_connection_id, desired_action, sync_state, attempts,
    next_attempt_at, lease_token, lease_until, last_error
  ) values (
    p_household_id, v_projection_key, v_kind, p_local_date,
    case when v_kind = 'special' then p_task_instance_id else null end,
    v_connection_id, v_desired_action, 'pending', 0, now(), null, null, null
  )
  on conflict (household_id, projection_key) do update
  set calendar_connection_id = excluded.calendar_connection_id,
      kind = excluded.kind,
      local_date = excluded.local_date,
      task_instance_id = excluded.task_instance_id,
      desired_action = excluded.desired_action,
      sync_state = 'pending', attempts = 0, next_attempt_at = now(),
      lease_token = null, lease_until = null, last_error = null,
      updated_at = now();
end;
$$;

create or replace function private.fn_enqueue_family_ops_calendar_task()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if tg_op = 'DELETE' then
    perform private.enqueue_family_ops_calendar_projection(
      old.household_id, old.task_definition_id, old.scheduled_date, old.id
    );
    return old;
  end if;

  if tg_op = 'UPDATE' and old.scheduled_date is distinct from new.scheduled_date then
    perform private.enqueue_family_ops_calendar_projection(
      old.household_id, old.task_definition_id, old.scheduled_date, old.id
    );
  end if;
  perform private.enqueue_family_ops_calendar_projection(
    new.household_id, new.task_definition_id, new.scheduled_date, new.id
  );
  return new;
end;
$$;

drop trigger if exists task_instances_enqueue_family_ops_calendar on public.task_instances;
create trigger task_instances_enqueue_family_ops_calendar
  after insert or delete or update of task_definition_id, scheduled_date,
    planned_assignee_id, due_at, calendar_ends_at, calendar_visibility, status
  on public.task_instances
  for each row execute function private.fn_enqueue_family_ops_calendar_task();

-- When a write target is selected (or reselected), reconcile the already
-- materialised rolling horizon instead of relying on a future mutation.
create or replace function public.server_tx_reconcile_family_ops_calendar(
  p_household_id uuid,
  p_start_date date default (now() at time zone 'Asia/Tokyo')::date,
  p_end_date date default ((now() at time zone 'Asia/Tokyo')::date + 60)
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_task record;
  v_count integer := 0;
begin
  if p_household_id is null or p_start_date is null or p_end_date is null or p_end_date < p_start_date then
    raise exception 'INVALID_INPUT';
  end if;
  for v_task in
    select id, household_id, task_definition_id, scheduled_date
    from public.task_instances
    where household_id = p_household_id
      and scheduled_date between p_start_date and p_end_date
      and calendar_visibility in ('transport', 'special')
  loop
    perform private.enqueue_family_ops_calendar_projection(
      v_task.household_id, v_task.task_definition_id, v_task.scheduled_date, v_task.id
    );
    v_count := v_count + 1;
  end loop;
  return jsonb_build_object('queued_task_count', v_count);
end;
$$;

revoke all on function public.server_tx_reconcile_family_ops_calendar(uuid, date, date) from public, anon, authenticated;
grant execute on function public.server_tx_reconcile_family_ops_calendar(uuid, date, date) to service_role;

create or replace function private.fn_reconcile_family_ops_calendar_target()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
begin
  if new.is_family_write_target and new.active and not new.reauth_required
     and (tg_op = 'INSERT' or not old.is_family_write_target or not old.active or old.reauth_required) then
    perform public.server_tx_reconcile_family_ops_calendar(new.household_id);
  end if;
  return new;
end;
$$;

drop trigger if exists calendar_connections_reconcile_family_ops_target on public.calendar_connections;
create trigger calendar_connections_reconcile_family_ops_target
  after insert or update of is_family_write_target, active, reauth_required on public.calendar_connections
  for each row execute function private.fn_reconcile_family_ops_calendar_target();

-- Claim one mirror and materialise its provider payload from canonical data.
-- This is intentionally separate from mutation transactions.
create or replace function public.server_tx_claim_family_ops_calendar_mirror(
  p_worker_id text,
  p_lease_seconds integer default 120
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_mirror private.family_ops_calendar_mirrors%rowtype;
  v_lease uuid := gen_random_uuid();
  v_dropoff uuid;
  v_pickup uuid;
  v_task public.task_instances%rowtype;
  v_title text;
  v_payload jsonb;
  v_event_id text;
begin
  if coalesce(p_worker_id, '') = '' then raise exception 'INVALID_INPUT'; end if;
  select * into v_mirror
  from private.family_ops_calendar_mirrors
  where (sync_state in ('pending', 'failed') and next_attempt_at <= now())
     or (sync_state = 'processing' and lease_until < now())
  order by next_attempt_at, updated_at
  for update skip locked
  limit 1;
  if not found then return null; end if;

  update private.family_ops_calendar_mirrors
  set sync_state = 'processing', lease_token = v_lease,
      lease_until = now() + make_interval(secs => greatest(coalesce(p_lease_seconds, 120), 30)),
      attempts = attempts + 1, updated_at = now()
  where household_id = v_mirror.household_id and projection_key = v_mirror.projection_key
  returning * into v_mirror;

  v_event_id := coalesce(v_mirror.provider_event_id,
    'fo' || substr(md5(v_mirror.household_id::text || ':' || v_mirror.projection_key), 1, 32));

  if v_mirror.desired_action = 'delete' then
    return jsonb_build_object(
      'household_id', v_mirror.household_id, 'projection_key', v_mirror.projection_key,
      'calendar_connection_id', v_mirror.calendar_connection_id, 'lease_token', v_lease,
      'action', 'delete', 'provider_event_id', v_mirror.provider_event_id,
      'deterministic_event_id', v_event_id
    );
  end if;

  if v_mirror.kind = 'transport' then
    select ti.planned_assignee_id into v_dropoff
    from public.task_instances ti join public.task_definitions td
      on td.household_id = ti.household_id and td.id = ti.task_definition_id
    where ti.household_id = v_mirror.household_id and ti.scheduled_date = v_mirror.local_date
      and ti.status <> 'cancelled' and td.code = 'dropoff'
    order by ti.updated_at desc, ti.id desc limit 1;
    select ti.planned_assignee_id into v_pickup
    from public.task_instances ti join public.task_definitions td
      on td.household_id = ti.household_id and td.id = ti.task_definition_id
    where ti.household_id = v_mirror.household_id and ti.scheduled_date = v_mirror.local_date
      and ti.status <> 'cancelled' and td.code = 'pickup'
    order by ti.updated_at desc, ti.id desc limit 1;
    if v_dropoff is null and v_pickup is null then
      return jsonb_build_object(
        'household_id', v_mirror.household_id, 'projection_key', v_mirror.projection_key,
        'calendar_connection_id', v_mirror.calendar_connection_id, 'lease_token', v_lease,
        'action', 'delete', 'provider_event_id', v_mirror.provider_event_id,
        'deterministic_event_id', v_event_id
      );
    end if;
    v_title := '送 ' || coalesce(private.family_ops_member_token(v_mirror.household_id, v_dropoff), '未定')
      || ' ｜ 迎 ' || coalesce(private.family_ops_member_token(v_mirror.household_id, v_pickup), '未定');
    v_payload := jsonb_build_object(
      'id', v_event_id, 'summary', v_title,
      'start', jsonb_build_object('date', v_mirror.local_date::text),
      'end', jsonb_build_object('date', (v_mirror.local_date + 1)::text),
      'transparency', 'transparent'
    );
  else
    select * into v_task from public.task_instances
    where household_id = v_mirror.household_id and id = v_mirror.task_instance_id;
    if not found or v_task.status = 'cancelled' or v_task.calendar_visibility <> 'special' then
      return jsonb_build_object(
        'household_id', v_mirror.household_id, 'projection_key', v_mirror.projection_key,
        'calendar_connection_id', v_mirror.calendar_connection_id, 'lease_token', v_lease,
        'action', 'delete', 'provider_event_id', v_mirror.provider_event_id,
        'deterministic_event_id', v_event_id
      );
    end if;
    if v_task.due_at is not null and v_task.calendar_ends_at is null then
      -- A due time alone is not an event duration.  Never invent an end
      -- time; the producer must provide one before this timed mirror writes.
      raise exception 'CALENDAR_EVENT_END_REQUIRED';
    end if;
    if v_task.calendar_ends_at is not null and v_task.calendar_ends_at <= v_task.due_at then
      raise exception 'INVALID_INPUT';
    end if;
    if v_task.due_at is null then
      v_payload := jsonb_build_object(
        'id', v_event_id, 'summary', v_task.title,
        'start', jsonb_build_object('date', v_task.scheduled_date::text),
        'end', jsonb_build_object('date', (v_task.scheduled_date + 1)::text),
        'transparency', 'transparent'
      );
    else
      v_payload := jsonb_build_object(
        'id', v_event_id, 'summary', v_task.title,
        'start', jsonb_build_object('dateTime', v_task.due_at, 'timeZone', 'Asia/Tokyo'),
        'end', jsonb_build_object('dateTime', v_task.calendar_ends_at, 'timeZone', 'Asia/Tokyo')
      );
    end if;
  end if;

  v_payload := v_payload || jsonb_build_object('extendedProperties', jsonb_build_object('private', jsonb_build_object(
    'familyOpsMirror', 'true', 'familyOpsProjectionKey', v_mirror.projection_key,
    'familyOpsKind', v_mirror.kind,
    'familyOpsTaskInstanceId', coalesce(v_mirror.task_instance_id::text, '')
  )));
  return jsonb_build_object(
    'household_id', v_mirror.household_id, 'projection_key', v_mirror.projection_key,
    'calendar_connection_id', v_mirror.calendar_connection_id, 'lease_token', v_lease,
    'action', 'upsert', 'provider_event_id', v_mirror.provider_event_id,
    'deterministic_event_id', v_event_id, 'event', v_payload
  );
end;
$$;

create or replace function public.server_tx_complete_family_ops_calendar_mirror(
  p_household_id uuid, p_projection_key text, p_lease_token uuid,
  p_provider_event_id text, p_provider_etag text, p_deleted boolean
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
begin
  update private.family_ops_calendar_mirrors
  set provider_event_id = coalesce(p_provider_event_id, provider_event_id),
      provider_etag = coalesce(p_provider_etag, provider_etag),
      sync_state = case when p_deleted then 'deleted' else 'synced' end,
      desired_action = case when p_deleted then 'delete' else 'upsert' end,
      lease_token = null, lease_until = null, last_error = null, updated_at = now()
  where household_id = p_household_id and projection_key = p_projection_key
    and sync_state = 'processing' and lease_token = p_lease_token;
  if not found then raise exception 'GOOGLE_SYNC_LEASE_LOST'; end if;
  return jsonb_build_object('ok', true);
end;
$$;

create or replace function public.server_tx_fail_family_ops_calendar_mirror(
  p_household_id uuid, p_projection_key text, p_lease_token uuid, p_error text
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
begin
  update private.family_ops_calendar_mirrors
  set sync_state = 'failed', lease_token = null, lease_until = null,
      last_error = left(coalesce(p_error, 'unknown'), 1000),
      next_attempt_at = now() + make_interval(secs => (2 ^ least(attempts, 6))::integer * 30),
      updated_at = now()
  where household_id = p_household_id and projection_key = p_projection_key
    and sync_state = 'processing' and lease_token = p_lease_token;
  if not found then raise exception 'GOOGLE_SYNC_LEASE_LOST'; end if;
  return jsonb_build_object('ok', true);
end;
$$;

revoke all on function public.server_tx_claim_family_ops_calendar_mirror(text, integer) from public, anon, authenticated;
revoke all on function public.server_tx_complete_family_ops_calendar_mirror(uuid, text, uuid, text, text, boolean) from public, anon, authenticated;
revoke all on function public.server_tx_fail_family_ops_calendar_mirror(uuid, text, uuid, text) from public, anon, authenticated;
grant execute on function public.server_tx_claim_family_ops_calendar_mirror(text, integer) to service_role;
grant execute on function public.server_tx_complete_family_ops_calendar_mirror(uuid, text, uuid, text, text, boolean) to service_role;
grant execute on function public.server_tx_fail_family_ops_calendar_mirror(uuid, text, uuid, text) to service_role;

-- Projection rebuilds retain a stable link to generated provider events.
-- The marker comes from the outbound mapping, never from a human title.
create or replace function private.fn_mark_family_ops_calendar_occurrence()
returns trigger
language plpgsql
security definer
set search_path = ''
as $$
declare v_mirror private.family_ops_calendar_mirrors%rowtype;
begin
  select * into v_mirror
  from private.family_ops_calendar_mirrors
  where household_id = new.household_id
    and calendar_connection_id = new.calendar_connection_id
    and provider_event_id = new.google_event_id
    and sync_state <> 'deleted'
  limit 1;
  new.family_ops_mirror := found;
  new.family_ops_kind := case when found then v_mirror.kind else null end;
  new.family_ops_task_instance_id := case when found then v_mirror.task_instance_id else null end;
  return new;
end;
$$;

drop trigger if exists calendar_occurrences_mark_family_ops_mirror on public.calendar_event_occurrences;
create trigger calendar_occurrences_mark_family_ops_mirror
  before insert or update of google_event_id, calendar_connection_id on public.calendar_event_occurrences
  for each row execute function private.fn_mark_family_ops_calendar_occurrence();

-- Private helpers are trigger/worker implementation details. PostgreSQL
-- grants EXECUTE to PUBLIC by default, so revoke it explicitly rather than
-- relying on schema visibility.
revoke all on function private.fn_default_family_write_target() from public, anon, authenticated;
revoke all on function private.fn_copy_task_calendar_visibility() from public, anon, authenticated;
revoke all on function private.family_ops_member_token(uuid, uuid) from public, anon, authenticated;
revoke all on function private.enqueue_family_ops_calendar_projection(uuid, uuid, date, uuid) from public, anon, authenticated;
revoke all on function private.fn_enqueue_family_ops_calendar_task() from public, anon, authenticated;
revoke all on function private.fn_reconcile_family_ops_calendar_target() from public, anon, authenticated;
revoke all on function private.fn_mark_family_ops_calendar_occurrence() from public, anon, authenticated;
