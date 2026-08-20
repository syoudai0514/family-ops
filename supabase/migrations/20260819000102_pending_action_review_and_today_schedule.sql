-- Sol re-review #3 fix (P1-1/P1-2): docs/design/v6/02_UX_AND_SCREENS.md #3
-- names two Today screen priorities this repo had backend support for but
-- no PWA read surface at all:
--
--   Priority 1: 今/次の予定 (calendar occurrences + household schedule +
--   assignment/calendar conflict warning)
--   Priority 2: 自分の判断待ち, which explicitly lists "LINEから作ったpending
--   action" alongside received requests -- process-line-inbox already
--   creates private.pending_actions rows and replies "内容はアプリでご確認
--   ください" (docs/adr/0009), but nothing let the PWA read/confirm/cancel
--   them, making that reply a dead end (Sol's exact finding).
--
-- Three new read/mutation RPCs, all following the existing house pattern
-- (security invoker, empty search_path, service_role-only grant, called
-- from a verify_jwt=true Edge Function via _shared/auth.ts:requireUserActor
-- -- see docs/adr/0011 for the full write-up):
--
--   1. server_tx_list_pending_actions -- the actor's own non-terminal draft/
--      confirmed/queued/executing pending actions (never another
--      household member's -- draft LINE input is private until it becomes
--      a shared task/shopping item, matching "Partner cannot see
--      sender-private raw text").
--   2. server_tx_get_today_schedule -- today's calendar occurrences (timed,
--      non-transparent, non-cancelled -- excluding all-day per the review's
--      explicit display rule) plus today's assigned/due task_instances,
--      each annotated with has_conflict.
--
-- server_tx_confirm_pending_action / server_tx_cancel_pending_action
-- already exist (20260819000041) and need no change -- only a new
-- verify_jwt=true Edge Function wrapper each, calling them with the exact
-- same (p_actor_id, p_pending_action_id) shape process-line-inbox's own
-- postback handler already uses.
--
-- Conflict semantics: rather than re-deriving the busy-attribution
-- predicate a second time (the exact thing Sol's finding warns against --
-- "Do not reimplement busy attribution in the browser... match the LINE
-- digest conflict computation"), private.fn_conflict_task_count
-- (20260819000091) is refactored here to delegate its own per-task overlap
-- test to a new private.fn_calendar_conflict_exists helper, and
-- server_tx_get_today_schedule below calls that SAME helper per assignment.
-- One predicate, two call sites, zero drift risk between the LINE digest's
-- conflict count and the PWA's per-item conflict flag.

-- ---------------------------------------------------------------------------
-- 1) private.fn_calendar_conflict_exists: the one true "does this
--    assignee/due_at pair overlap a busy calendar occurrence" predicate,
--    extracted verbatim from fn_conflict_task_count's own WHERE EXISTS
--    clause (07_GOOGLE_CALENDAR.md #10/#13; busy attribution exclusively
--    via public.calendar_occurrence_busy_members, never
--    creator_mapped_user_id).
-- ---------------------------------------------------------------------------
create or replace function private.fn_calendar_conflict_exists(
  p_household_id uuid,
  p_assignee_id uuid,
  p_due_at timestamptz,
  p_conflict_window_minutes int
) returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select exists (
    select 1
    from public.calendar_event_occurrences occ
    join public.calendar_connections cc
      on cc.household_id = occ.household_id and cc.id = occ.calendar_connection_id
    join public.calendar_occurrence_busy_members bm
      on bm.household_id = occ.household_id
     and bm.calendar_connection_id = occ.calendar_connection_id
     and bm.occurrence_key = occ.occurrence_key
    where occ.household_id = p_household_id
      and cc.active
      and bm.user_id = p_assignee_id
      and occ.status <> 'cancelled'
      and coalesce(occ.transparency, 'opaque') <> 'transparent'
      and occ.all_day_start is null
      and occ.starts_at is not null
      and p_due_at is not null
      and occ.starts_at < p_due_at + make_interval(mins => coalesce(p_conflict_window_minutes, 60))
      and coalesce(occ.ends_at, occ.starts_at) > p_due_at - make_interval(mins => coalesce(p_conflict_window_minutes, 60))
  );
$$;

revoke all on function private.fn_calendar_conflict_exists(uuid, uuid, timestamptz, int) from public;
revoke all on function private.fn_calendar_conflict_exists(uuid, uuid, timestamptz, int) from anon;
revoke all on function private.fn_calendar_conflict_exists(uuid, uuid, timestamptz, int) from authenticated;
grant execute on function private.fn_calendar_conflict_exists(uuid, uuid, timestamptz, int) to service_role;

-- ---------------------------------------------------------------------------
-- 2) fn_conflict_task_count: CREATE OR REPLACE to delegate its per-task
--    overlap test to the helper above, so the LINE digest's conflict COUNT
--    and the PWA's per-item conflict FLAG are provably the same predicate.
--    No behavior change -- the WHERE EXISTS clause is identical, just
--    factored out.
-- ---------------------------------------------------------------------------
create or replace function private.fn_conflict_task_count(
  p_household_id uuid,
  p_range_start date,
  p_range_end date,
  p_assignee_id uuid
) returns int
language sql
stable
security invoker
set search_path = ''
as $$
  select count(distinct ti.id)::int
  from public.task_instances ti
  left join public.recurrence_rules rr
    on rr.household_id = ti.household_id and rr.id = ti.recurrence_rule_id
  where ti.household_id = p_household_id
    and ti.scheduled_date between p_range_start and p_range_end
    and ti.planned_assignee_id is not null
    and (p_assignee_id is null or ti.planned_assignee_id = p_assignee_id)
    and ti.status in ('todo', 'in_progress')
    and ti.due_at is not null
    and private.fn_calendar_conflict_exists(
      ti.household_id, ti.planned_assignee_id, ti.due_at, coalesce(rr.conflict_window_minutes, 60)
    );
$$;

revoke all on function private.fn_conflict_task_count(uuid, date, date, uuid) from public;
revoke all on function private.fn_conflict_task_count(uuid, date, date, uuid) from anon;
revoke all on function private.fn_conflict_task_count(uuid, date, date, uuid) from authenticated;
grant execute on function private.fn_conflict_task_count(uuid, date, date, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 3) server_tx_list_pending_actions: Today Priority 2's "LINEから作った
--    pending action". Actor-scoped only (never household-wide) -- a draft
--    is the sender's own private natural-language input until confirmed
--    into a real task/shopping item.
-- ---------------------------------------------------------------------------
create or replace function public.server_tx_list_pending_actions(
  p_actor_id uuid
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_result jsonb;
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

  select coalesce(jsonb_agg(jsonb_build_object(
    'id', pa.id,
    'action_type', pa.action_type,
    'normalized_payload', pa.normalized_payload,
    'status', pa.status,
    'source', pa.source,
    'expires_at', pa.expires_at,
    'created_at', pa.created_at
  ) order by pa.created_at desc), '[]'::jsonb)
  into v_result
  from private.pending_actions pa
  where pa.actor_id = p_actor_id
    and pa.status in ('draft', 'confirmed', 'queued', 'executing')
    and pa.expires_at > now();

  return v_result;
end;
$$;

revoke all on function public.server_tx_list_pending_actions(uuid) from public;
revoke all on function public.server_tx_list_pending_actions(uuid) from anon;
revoke all on function public.server_tx_list_pending_actions(uuid) from authenticated;
grant execute on function public.server_tx_list_pending_actions(uuid) to service_role;

-- ---------------------------------------------------------------------------
-- 4) server_tx_get_today_schedule: Today Priority 1's "今/次の予定". Returns
--    already-filtered, already-conflict-annotated data so the frontend does
--    zero calendar-domain filtering/computation of its own -- it only
--    renders what this RPC returns.
-- ---------------------------------------------------------------------------
create or replace function public.server_tx_get_today_schedule(
  p_actor_id uuid
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_today date := (now() at time zone 'Asia/Tokyo')::date;
  v_calendar_connected boolean;
  v_calendar_stale boolean;
  v_occurrences jsonb;
  v_assignments jsonb;
  v_result jsonb;
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

  -- Calendar-stale/reauth warning (17_ROUTINE_LINE_AUTOMATION.md #3's own
  -- "60分以上古い、またはreauth_required" threshold, reused here for the
  -- same warning concept applied to Today instead of the weekly digest).
  select
    bool_or(cc.active),
    bool_or(cc.active and (
      cc.reauth_required
      or cc.last_incremental_sync_at is null
      or cc.last_incremental_sync_at < now() - interval '60 minutes'
    ))
  into v_calendar_connected, v_calendar_stale
  from public.calendar_connections cc
  where cc.household_id = v_household_id;

  -- Timed, non-transparent, non-cancelled occurrences touching today only
  -- (display rule per the re-review: exclude all-day/transparent, unlike
  -- fn_calendar_day_lines's own digest-display exclusion set, which is
  -- deliberately broader for that different screen).
  select coalesce(jsonb_agg(jsonb_build_object(
    'occurrence_key', occ.occurrence_key,
    'title', occ.title,
    'starts_at', occ.starts_at,
    'ends_at', occ.ends_at,
    'busy_user_ids', (
      select coalesce(jsonb_agg(bm.user_id), '[]'::jsonb)
      from public.calendar_occurrence_busy_members bm
      where bm.household_id = occ.household_id
        and bm.calendar_connection_id = occ.calendar_connection_id
        and bm.occurrence_key = occ.occurrence_key
    )
  ) order by occ.starts_at), '[]'::jsonb)
  into v_occurrences
  from public.calendar_event_occurrences occ
  join public.calendar_connections cc
    on cc.household_id = occ.household_id and cc.id = occ.calendar_connection_id
  where occ.household_id = v_household_id
    and cc.active
    and occ.status <> 'cancelled'
    and occ.all_day_start is null
    and occ.starts_at is not null
    and coalesce(occ.transparency, 'opaque') <> 'transparent'
    and (occ.starts_at at time zone 'Asia/Tokyo')::date = v_today;

  -- Today's assigned, due, still-actionable tasks (dropoff/pickup and any
  -- other timed task) in chronological order, each annotated with the SAME
  -- conflict predicate the LINE digest count uses.
  select coalesce(jsonb_agg(jsonb_build_object(
    'task_instance_id', ti.id,
    'title', ti.title,
    'category', ti.category,
    'due_at', ti.due_at,
    'planned_assignee_id', ti.planned_assignee_id,
    'has_conflict', private.fn_calendar_conflict_exists(
      ti.household_id, ti.planned_assignee_id, ti.due_at, coalesce(rr.conflict_window_minutes, 60)
    )
  ) order by ti.due_at), '[]'::jsonb)
  into v_assignments
  from public.task_instances ti
  left join public.recurrence_rules rr
    on rr.household_id = ti.household_id and rr.id = ti.recurrence_rule_id
  where ti.household_id = v_household_id
    and ti.scheduled_date = v_today
    and ti.status in ('todo', 'in_progress')
    and ti.due_at is not null
    and ti.planned_assignee_id is not null;

  v_result := jsonb_build_object(
    'household_id', v_household_id,
    'local_date', v_today,
    'calendar_connected', coalesce(v_calendar_connected, false),
    'calendar_stale', coalesce(v_calendar_stale, false),
    'occurrences', v_occurrences,
    'assignments', v_assignments
  );

  return v_result;
end;
$$;

revoke all on function public.server_tx_get_today_schedule(uuid) from public;
revoke all on function public.server_tx_get_today_schedule(uuid) from anon;
revoke all on function public.server_tx_get_today_schedule(uuid) from authenticated;
grant execute on function public.server_tx_get_today_schedule(uuid) to service_role;
