-- WP8 follow-up: closes Sol's design-review P1-1 and P1-2 findings against
-- 20260819000082_dispatch_routine_automation_rpc.sql. That migration's own
-- header comment documented two MVP simplifications as intentionally
-- deferred; this migration removes both:
--
--   P1-1: the weekly digest (and non-workday 09:00 daily section) now merges
--   all five 17_ROUTINE_LINE_AUTOMATION.md #3 sources — Google Calendar
--   rolling occurrence projection, dropoff/pickup assignment (incl.
--   once-reassignment, already live), special-preparation tasks (already
--   live, kept as-is per the original migration's own documented choice),
--   and due request/shopping/manual-task highlights (#3 source 5, #7A
--   "shared ToDo/shopping/request highlights").
--
--   P1-2: daily_assignment (07:00) and nonworkday_morning_digest (09:00,
--   both today and next-week sections) now append a
--   "⚠ 担当と予定の重なり" conflict-count line when a timed, non-transparent,
--   non-cancelled Google Calendar occurrence overlaps a task's due_at +/-
--   its configured conflict_window_minutes for the same user the occurrence
--   is classified busy for (public.calendar_occurrence_busy_members —
--   never public.calendar_event_occurrences.creator_mapped_user_id, per
--   Sol's explicit callout and 07_GOOGLE_CALENDAR.md #10/#13). Gated by
--   notification_preferences.conflict_line per recipient; the underlying
--   private.fn_conflict_task_count() computation itself is never gated —
--   only the LINE text is.
--
-- See docs/adr/0008-routine-digest-calendar-merge-and-conflict-warning.md
-- for the design-detail decisions this amendment had to make where the doc
-- does not pin exact wording/criteria down (due-highlight "importance",
-- conflict aggregation scope, per-instance conflict window default for
-- origin='manual' tasks).

-- ---------------------------------------------------------------------------
-- private.fn_calendar_day_lines: Google Calendar occurrences (source 1)
-- that touch a given household local date, rendered as digest bullet
-- lines. Restricted to the household's *active* calendar connection(s) so a
-- revoked/replaced connection's stale rows never resurface. Deliberately
-- does not filter transparency/all-day here (that filter is specific to
-- *conflict* detection per 07_GOOGLE_CALENDAR.md #10 "timed event only" —
-- the digest display itself shows every non-cancelled occurrence, exactly
-- like #14 "Sunday weekly digest uses occurrence projection" does not
-- mention a transparency exclusion for display).
-- ---------------------------------------------------------------------------
create or replace function private.fn_calendar_day_lines(
  p_household_id uuid,
  p_day date
) returns text
language sql
stable
security invoker
set search_path = ''
as $$
  select string_agg(line, E'\n' order by sort_key, line)
  from (
    select
      case when occ.all_day_start is not null
        then '・' || coalesce(occ.title, '(無題の予定)')
        else '・' || to_char(occ.starts_at at time zone 'Asia/Tokyo', 'HH24:MI') || ' ' || coalesce(occ.title, '(無題の予定)')
      end as line,
      case when occ.all_day_start is not null
        then '00:00'
        else to_char(occ.starts_at at time zone 'Asia/Tokyo', 'HH24:MI')
      end as sort_key
    from public.calendar_event_occurrences occ
    join public.calendar_connections cc
      on cc.household_id = occ.household_id and cc.id = occ.calendar_connection_id
    where occ.household_id = p_household_id
      and cc.active
      and occ.status <> 'cancelled'
      and (
        (occ.all_day_start is not null
          and p_day >= occ.all_day_start and p_day < occ.all_day_end_exclusive)
        or (occ.all_day_start is null and occ.starts_at is not null
          and p_day between (occ.starts_at at time zone 'Asia/Tokyo')::date
                         and (coalesce(occ.ends_at, occ.starts_at) at time zone 'Asia/Tokyo')::date)
      )
  ) lines;
$$;

revoke all on function private.fn_calendar_day_lines(uuid, date) from public;
revoke all on function private.fn_calendar_day_lines(uuid, date) from anon;
revoke all on function private.fn_calendar_day_lines(uuid, date) from authenticated;
grant execute on function private.fn_calendar_day_lines(uuid, date) to service_role;

-- ---------------------------------------------------------------------------
-- private.fn_due_highlight_lines: source 5 "due dateのあるrequest/shopping/
-- manual taskのうち重要表示対象" for [p_range_start, p_range_end] inclusive
-- (household local dates). "重要表示対象" is not defined more precisely
-- anywhere in the v6 docs (see ADR 0008 decision 1) — this implementation
-- takes it to mean "has a due_at falling in the digest's own relevant
-- window and is still actionable (not completed/cancelled/purchased/
-- declined/etc.)".
--
-- p_exclude_assignee_id, when not null, drops a manual task_instance
-- highlight whose planned_assignee_id is that user (already shown verbatim
-- in that user's own "今日の予定" task list — this is the load-bearing half
-- of the P1-1 no-duplicate-line requirement) and drops a request highlight
-- whose linked_task_instance_id resolves to a task_instance also assigned
-- to that user for that day (same reasoning, via the one real cross-table
-- link the schema has: public.requests.linked_task_instance_id).
-- public.shopping_items has no linked task_instance column at all, so no
-- shopping highlight can ever duplicate a task line — nothing to dedup
-- there. Pass p_exclude_assignee_id null for the shared/household-wide
-- weekly section, where no single viewer's own-task list exists to collide
-- with.
-- ---------------------------------------------------------------------------
create or replace function private.fn_due_highlight_lines(
  p_household_id uuid,
  p_range_start date,
  p_range_end date,
  p_exclude_assignee_id uuid
) returns text
language sql
stable
security invoker
set search_path = ''
as $$
  with manual_hl as (
    select
      '・' || ti.title
        || coalesce(' (期限' || to_char(ti.due_at at time zone 'Asia/Tokyo', 'MM/DD HH24:MI') || ')', '') as line,
      ti.due_at as sort_ts
    from public.task_instances ti
    where ti.household_id = p_household_id
      and ti.origin = 'manual'
      and ti.status in ('todo', 'in_progress')
      and ti.due_at is not null
      and (ti.due_at at time zone 'Asia/Tokyo')::date between p_range_start and p_range_end
      and (p_exclude_assignee_id is null or ti.planned_assignee_id is distinct from p_exclude_assignee_id)
  ),
  request_hl as (
    select
      '・' || r.shared_title
        || coalesce(' (期限' || to_char(r.due_at at time zone 'Asia/Tokyo', 'MM/DD HH24:MI') || ')', '') as line,
      r.due_at as sort_ts
    from public.requests r
    left join public.task_instances lti
      on lti.household_id = r.household_id and lti.id = r.linked_task_instance_id
    where r.household_id = p_household_id
      and r.status in ('pending', 'accepted')
      and r.due_at is not null
      and (r.due_at at time zone 'Asia/Tokyo')::date between p_range_start and p_range_end
      and not (
        p_exclude_assignee_id is not null
        and lti.id is not null
        and lti.status in ('todo', 'in_progress')
        and lti.planned_assignee_id = p_exclude_assignee_id
      )
  ),
  shopping_hl as (
    select
      '・' || si.title
        || coalesce(' (期限' || to_char(si.due_at at time zone 'Asia/Tokyo', 'MM/DD HH24:MI') || ')', '') as line,
      si.due_at as sort_ts
    from public.shopping_items si
    where si.household_id = p_household_id
      and si.status in ('wanted', 'assigned', 'ordered')
      and si.due_at is not null
      and (si.due_at at time zone 'Asia/Tokyo')::date between p_range_start and p_range_end
  )
  select string_agg(line, E'\n' order by sort_ts, line)
  from (
    select * from manual_hl
    union all
    select * from request_hl
    union all
    select * from shopping_hl
  ) x;
$$;

revoke all on function private.fn_due_highlight_lines(uuid, date, date, uuid) from public;
revoke all on function private.fn_due_highlight_lines(uuid, date, date, uuid) from anon;
revoke all on function private.fn_due_highlight_lines(uuid, date, date, uuid) from authenticated;
grant execute on function private.fn_due_highlight_lines(uuid, date, date, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- private.fn_conflict_task_count: P1-2. Counts distinct task_instances in
-- [p_range_start, p_range_end] whose planned assignee (optionally narrowed
-- to p_assignee_id; null = household-wide, any assignee) has a timed,
-- non-transparent, non-cancelled Google Calendar occurrence overlapping
-- their task's due_at +/- the applicable conflict window, per
-- 07_GOOGLE_CALENDAR.md #10 ("planned assignee / due_at / conflict window
-- default 60m per rule" on the task side; "occurrence busy member contains
-- same user / non-transparent / timed event only" on the calendar side).
--
-- Busy attribution is exclusively via public.calendar_occurrence_busy_
-- members — never public.calendar_event_occurrences.creator_mapped_
-- user_id — per Sol's review and #13 "Busy member is separate table and
-- never derived from creator automatically".
--
-- Conflict window: origin='recurring' task_instances inherit their rule's
-- recurrence_rules.conflict_window_minutes; origin='manual' (and any other)
-- task_instances have no per-instance equivalent column in the schema, so
-- this uses the same 60-minute default recurrence_rules itself defaults to
-- (see ADR 0008 decision 2).
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
    and exists (
      select 1
      from public.calendar_event_occurrences occ
      join public.calendar_connections cc
        on cc.household_id = occ.household_id and cc.id = occ.calendar_connection_id
      join public.calendar_occurrence_busy_members bm
        on bm.household_id = occ.household_id
       and bm.calendar_connection_id = occ.calendar_connection_id
       and bm.occurrence_key = occ.occurrence_key
      where occ.household_id = ti.household_id
        and cc.active
        and bm.user_id = ti.planned_assignee_id
        and occ.status <> 'cancelled'
        and coalesce(occ.transparency, 'opaque') <> 'transparent'
        and occ.all_day_start is null
        and occ.starts_at is not null
        and occ.starts_at < ti.due_at + make_interval(mins => coalesce(rr.conflict_window_minutes, 60))
        and coalesce(occ.ends_at, occ.starts_at) > ti.due_at - make_interval(mins => coalesce(rr.conflict_window_minutes, 60))
    );
$$;

revoke all on function private.fn_conflict_task_count(uuid, date, date, uuid) from public;
revoke all on function private.fn_conflict_task_count(uuid, date, date, uuid) from anon;
revoke all on function private.fn_conflict_task_count(uuid, date, date, uuid) from authenticated;
grant execute on function private.fn_conflict_task_count(uuid, date, date, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- public.server_tx_dispatch_routine_automation: full create-or-replace
-- amendment (same house-style precedent as WP3 amending
-- private.materialize_recurrence_rule / this WP's own 20260819000081
-- amending server_tx_reassign_task_once). Every branch other than
-- daily_assignment and nonworkday_morning_digest is byte-for-byte
-- unchanged from 20260819000082.
-- ---------------------------------------------------------------------------
create or replace function public.server_tx_dispatch_routine_automation(
  p_now_utc timestamptz,
  p_row_limit int default 2000
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_local_now timestamp;
  v_local_date date;
  v_local_time time;
  v_local_hhmm text;
  v_is_nonworkday boolean;
  v_is_sunday boolean;
  v_sched record;
  v_claimed_count int := 0;
  v_evaluated_count int := 0;
  -- per-branch scratch
  v_adult record;
  v_dropoff_ti record;
  v_pickup_ti record;
  v_session_id uuid;
  v_item jsonb;
  v_body text;
  v_slot text;
  v_line_ok boolean;
  v_dropoff_name text;
  v_pickup_name text;
  v_prep_titles text;
  v_incomplete_titles text;
  v_incomplete_count int;
  v_adult_count int;
  v_other_adult uuid;
  v_conn record;
  v_calendar_warning text;
  v_next_monday date;
  v_weekly_lines text;
  v_day record;
  v_own_titles text;
  v_dedup text;
  -- P1-1/P1-2 additions
  v_cal_lines text;
  v_hl_lines text;
  v_conflict_ok boolean;
  v_daily_conflict_count int;
  v_today_conflict_count int;
  v_weekly_conflict_count int;
  v_day_dropoff_pickup text;
  v_day_prep text;
  v_day_hl text;
  v_day_cal text;
  v_day_block text;
  v_weekday_label text;
begin
  if p_now_utc is null then
    raise exception 'INVALID_INPUT';
  end if;

  v_local_now := (p_now_utc at time zone 'Asia/Tokyo');
  v_local_date := v_local_now::date;
  v_local_time := date_trunc('minute', v_local_now)::time;
  v_local_hhmm := to_char(v_local_now, 'HH24:MI');
  v_is_nonworkday := private.fn_is_nonworkday(v_local_date);
  v_is_sunday := extract(isodow from v_local_date)::int = 7;

  -- ---------------------------------------------------------------------
  -- Weekly Google sync preflight (#3 "Calendar freshness"): fires 10
  -- minutes ahead of each household's own nonworkday_morning_digest time,
  -- Sundays only, once per (household, upcoming-week) via
  -- private.worker_run_receipts — worker logic, not a user-facing schedule
  -- row, per #3's own "preflightはuser-facing schedule rowではなくworker logic".
  -- ---------------------------------------------------------------------
  if v_is_sunday then
    v_next_monday := v_local_date + 1;
    for v_sched in
      select hrs.household_id
      from public.household_routine_schedules hrs
      where hrs.schedule_kind = 'nonworkday_morning_digest' and hrs.enabled
        and hrs.local_time = (v_local_time + interval '10 minutes')::time
      limit p_row_limit
    loop
      begin
        insert into private.worker_run_receipts (worker_kind, logical_slot_key)
        values ('weekly_digest_preflight', v_sched.household_id::text || ':' || v_next_monday::text);
      exception when unique_violation then
        continue; -- already enqueued this week for this household
      end;

      select cc.id into v_conn
      from public.calendar_connections cc
      where cc.household_id = v_sched.household_id and cc.active
      order by cc.created_at
      limit 1;
      if found then
        perform private.google_enqueue_sync(v_conn.id, 'weekly_digest_preflight');
      end if;
    end loop;
  end if;

  -- ---------------------------------------------------------------------
  -- Due schedules for this exact local minute, applicability-filtered
  -- (#2 "Non-workday suppresses all weekday role schedules").
  -- ---------------------------------------------------------------------
  for v_sched in
    select hrs.household_id, hrs.schedule_kind, hrs.schedule_version
    from public.household_routine_schedules hrs
    where hrs.enabled and hrs.local_time = v_local_time
      and (
        (v_is_nonworkday and hrs.schedule_kind in ('nonworkday_morning_digest', 'nonworkday_checkin'))
        or (not v_is_nonworkday and hrs.schedule_kind not in ('nonworkday_morning_digest', 'nonworkday_checkin'))
      )
    order by hrs.household_id
    limit p_row_limit
  loop
    v_evaluated_count := v_evaluated_count + 1;
    v_slot := v_sched.schedule_kind || ':' || v_local_hhmm || ':v' || v_sched.schedule_version;

    -- ===================================================================
    if v_sched.schedule_kind = 'daily_assignment' then
      select ti.id, ti.planned_assignee_id into v_dropoff_ti
      from public.task_instances ti join public.task_definitions td
        on td.household_id = ti.household_id and td.id = ti.task_definition_id
      where ti.household_id = v_sched.household_id and ti.scheduled_date = v_local_date
        and td.code = 'dropoff' and ti.status in ('todo', 'in_progress')
      limit 1;
      select ti.id, ti.planned_assignee_id into v_pickup_ti
      from public.task_instances ti join public.task_definitions td
        on td.household_id = ti.household_id and td.id = ti.task_definition_id
      where ti.household_id = v_sched.household_id and ti.scheduled_date = v_local_date
        and td.code = 'pickup' and ti.status in ('todo', 'in_progress')
      limit 1;

      select coalesce(p.display_name, '担当者') into v_dropoff_name
      from public.profiles p where p.user_id = v_dropoff_ti.planned_assignee_id;
      select coalesce(p.display_name, '担当者') into v_pickup_name
      from public.profiles p where p.user_id = v_pickup_ti.planned_assignee_id;

      select string_agg('・' || ti.title, E'\n') into v_prep_titles
      from public.task_instances ti join public.task_definitions td
        on td.household_id = ti.household_id and td.id = ti.task_definition_id
      where ti.household_id = v_sched.household_id and ti.scheduled_date = v_local_date
        and ti.routine_phase = 'morning' and td.code <> 'dropoff'
        and ti.status in ('todo', 'in_progress');

      v_body := '送り：' || coalesce(v_dropoff_name, '未定') || ' / 迎え：' || coalesce(v_pickup_name, '未定')
        || case when v_prep_titles is not null then E'\n\n' || v_prep_titles else '' end;

      -- P1-2: household-wide conflict count for today, computed once and
      -- never gated (only the appended text below is gated per recipient).
      -- A calendar-side failure here must never block the household-task
      -- half of the message (14. Failure behavior / #3 "Calendar障害で家事
      -- 担当まで送れなくなる設計にしない").
      begin
        v_daily_conflict_count := private.fn_conflict_task_count(v_sched.household_id, v_local_date, v_local_date, null);
      exception when others then
        v_daily_conflict_count := 0;
      end;

      for v_adult in
        select user_id from public.household_members
        where household_id = v_sched.household_id and member_role = 'adult'
      loop
        select coalesce(np.daily_assignment_line, true), coalesce(np.conflict_line, true)
          into v_line_ok, v_conflict_ok
        from public.notification_preferences np
        where np.household_id = v_sched.household_id and np.user_id = v_adult.user_id;

        v_item := jsonb_build_object(
          'title', '☀️ 今日の担当',
          'body', v_body || case
            when v_daily_conflict_count > 0 and coalesce(v_conflict_ok, true)
              then E'\n\n⚠ 担当と予定の重なり ' || v_daily_conflict_count || E'件\n→ Family Opsで確認'
            else ''
          end
        );
        v_dedup := 'routine-min:' || v_sched.household_id::text || ':' || v_adult.user_id::text
          || ':' || v_local_date::text || ':' || v_local_hhmm;
        if private.fn_claim_and_enqueue_routine_notification(
          v_sched.household_id, v_sched.schedule_kind, v_local_date, v_adult.user_id,
          v_slot, 'normal', v_item, v_dedup, coalesce(v_line_ok, true)
        ) then
          v_claimed_count := v_claimed_count + 1;
        end if;
      end loop;

    -- ===================================================================
    elsif v_sched.schedule_kind = 'dropoff_checklist' or v_sched.schedule_kind = 'pickup_checklist' then
      declare
        v_code text := case when v_sched.schedule_kind = 'dropoff_checklist' then 'dropoff' else 'pickup' end;
        v_phase text := case when v_sched.schedule_kind = 'dropoff_checklist' then 'morning' else 'evening' end;
        v_session_type text := case when v_sched.schedule_kind = 'dropoff_checklist' then 'dropoff' else 'pickup' end;
        v_ti record;
        v_items_text text;
      begin
        select ti.id, ti.planned_assignee_id into v_ti
        from public.task_instances ti join public.task_definitions td
          on td.household_id = ti.household_id and td.id = ti.task_definition_id
        where ti.household_id = v_sched.household_id and ti.scheduled_date = v_local_date
          and td.code = v_code and ti.status in ('todo', 'in_progress')
        limit 1;

        if v_ti.id is not null and v_ti.planned_assignee_id is not null then
          v_session_id := private.fn_get_or_create_routine_session(
            v_sched.household_id, v_session_type, v_local_date, v_ti.planned_assignee_id, v_phase, v_ti.id
          );

          select string_agg('□ ' || t.title, E'\n' order by rcsi.display_order) into v_items_text
          from public.routine_checkin_session_items rcsi
          join public.task_instances t on t.household_id = v_sched.household_id and t.id = rcsi.task_instance_id
          where rcsi.household_id = v_sched.household_id and rcsi.session_id = v_session_id;

          select coalesce(np.routine_checklist_line, true) into v_line_ok
          from public.notification_preferences np
          where np.household_id = v_sched.household_id and np.user_id = v_ti.planned_assignee_id;

          v_item := jsonb_build_object(
            'title', case when v_code = 'dropoff' then '🎒 朝のチェック' else '🧸 お迎え後のチェック' end,
            'body', coalesce(v_items_text, '')
          );
          v_dedup := 'routine-min:' || v_sched.household_id::text || ':' || v_ti.planned_assignee_id::text
            || ':' || v_local_date::text || ':' || v_local_hhmm;
          if private.fn_claim_and_enqueue_routine_notification(
            v_sched.household_id, v_sched.schedule_kind, v_local_date, v_ti.planned_assignee_id,
            v_slot, 'normal', v_item, v_dedup, coalesce(v_line_ok, true)
          ) then
            v_claimed_count := v_claimed_count + 1;
          end if;
        end if;
        -- no dropoff/pickup task or unassigned today -> nothing to do
        -- (SL-04/SL-05: never a hardcoded weekday send).
      end;

    -- ===================================================================
    elsif v_sched.schedule_kind = 'dropoff_checkin' or v_sched.schedule_kind = 'pickup_checkin' then
      declare
        v_code text := case when v_sched.schedule_kind = 'dropoff_checkin' then 'dropoff' else 'pickup' end;
        v_session_type text := case when v_sched.schedule_kind = 'dropoff_checkin' then 'dropoff' else 'pickup' end;
        v_sess record;
      begin
        -- Driven directly by the currently-open session, NOT by re-querying
        -- today's dropoff/pickup task_instance's own live status — that
        -- anchor task is itself one of the session's items and is very
        -- often already 'completed' by check-in time (that is the whole
        -- point of the reminder), so filtering on its status here would
        -- wrongly skip every session whose anchor finished before its
        -- OTHER items did. At most one session can be 'open' for a given
        -- (household, session_type, date) at a time (supersede keeps that
        -- invariant), so this is unambiguous.
        select id, assignee_id, status into v_sess
        from public.routine_checkin_sessions
        where household_id = v_sched.household_id and session_type = v_session_type
          and scheduled_date = v_local_date and status = 'open'
        for update;

        if found then
          select string_agg('・' || t.title, E'\n') into v_incomplete_titles
          from public.routine_checkin_session_items rcsi
          join public.task_instances t on t.household_id = v_sched.household_id and t.id = rcsi.task_instance_id
          where rcsi.household_id = v_sched.household_id and rcsi.session_id = v_sess.id
            and t.status in ('todo', 'in_progress');

          if v_incomplete_titles is null then
            -- #5 "全required item completed ... reminderを送らない。session auto_closed可"
            update public.routine_checkin_sessions set status = 'auto_closed' where id = v_sess.id;
          else
            select coalesce(np.routine_checkin_prompt_line, true) into v_line_ok
            from public.notification_preferences np
            where np.household_id = v_sched.household_id and np.user_id = v_sess.assignee_id;

            v_item := jsonb_build_object(
              'title', '📝 ' || case when v_code = 'dropoff' then '朝' else 'お迎え後' end || 'のチェックをお願いします',
              'body', 'まだ未完了:' || E'\n' || v_incomplete_titles
            );
            v_dedup := 'routine-min:' || v_sched.household_id::text || ':' || v_sess.assignee_id::text
              || ':' || v_local_date::text || ':' || v_local_hhmm;
            if private.fn_claim_and_enqueue_routine_notification(
              v_sched.household_id, v_sched.schedule_kind, v_local_date, v_sess.assignee_id,
              v_slot, 'reminder', v_item, v_dedup, coalesce(v_line_ok, true)
            ) then
              v_claimed_count := v_claimed_count + 1;
            end if;
          end if;
        end if;
      end;

    -- ===================================================================
    elsif v_sched.schedule_kind = 'nonpickup_evening_checklist' then
      select ti.planned_assignee_id into v_pickup_ti
      from public.task_instances ti join public.task_definitions td
        on td.household_id = ti.household_id and td.id = ti.task_definition_id
      where ti.household_id = v_sched.household_id and ti.scheduled_date = v_local_date
        and td.code = 'pickup' and ti.status in ('todo', 'in_progress')
      limit 1;

      select count(*) into v_adult_count
      from public.household_members
      where household_id = v_sched.household_id and member_role = 'adult';

      if v_pickup_ti.planned_assignee_id is null then
        -- #6 exception: "pickup assignee null -> no role auto-guess; both
        -- receive one unassigned warning" (SL-21). The per-recipient claim
        -- gate on schedule_kind+date already dedups this to once per day.
        for v_adult in
          select user_id from public.household_members
          where household_id = v_sched.household_id and member_role = 'adult'
        loop
          v_item := jsonb_build_object('title', '⚠ 迎え担当が未設定です', 'body', 'Family Opsで迎え担当を設定してください。');
          v_dedup := 'routine-min:' || v_sched.household_id::text || ':' || v_adult.user_id::text
            || ':' || v_local_date::text || ':' || v_local_hhmm;
          if private.fn_claim_and_enqueue_routine_notification(
            v_sched.household_id, v_sched.schedule_kind, v_local_date, v_adult.user_id,
            v_slot, 'normal', v_item, v_dedup, true
          ) then
            v_claimed_count := v_claimed_count + 1;
          end if;
        end loop;
      elsif v_adult_count = 2 then
        select user_id into v_other_adult
        from public.household_members
        where household_id = v_sched.household_id and member_role = 'adult'
          and user_id <> v_pickup_ti.planned_assignee_id
        limit 1;

        v_session_id := private.fn_get_or_create_routine_session(
          v_sched.household_id, 'nonpickup_evening', v_local_date, v_other_adult, 'evening', null
        );

        if v_session_id is not null then
          select string_agg('□ ' || t.title, E'\n' order by rcsi.display_order) into v_own_titles
          from public.routine_checkin_session_items rcsi
          join public.task_instances t on t.household_id = v_sched.household_id and t.id = rcsi.task_instance_id
          where rcsi.household_id = v_sched.household_id and rcsi.session_id = v_session_id;

          select coalesce(np.routine_checklist_line, true) into v_line_ok
          from public.notification_preferences np
          where np.household_id = v_sched.household_id and np.user_id = v_other_adult;

          v_item := jsonb_build_object('title', '🌙 今夜のチェック', 'body', coalesce(v_own_titles, ''));
          v_dedup := 'routine-min:' || v_sched.household_id::text || ':' || v_other_adult::text
            || ':' || v_local_date::text || ':' || v_local_hhmm;
          if private.fn_claim_and_enqueue_routine_notification(
            v_sched.household_id, v_sched.schedule_kind, v_local_date, v_other_adult,
            v_slot, 'normal', v_item, v_dedup, coalesce(v_line_ok, true)
          ) then
            v_claimed_count := v_claimed_count + 1;
          end if;
        end if;
        -- v_session_id null -> zero items -> #7 "0件なら通知なし、sessionも
        -- 作成しなくてよい" (SL-10).
      end if;
      -- adult_count <> 2 -> #6/SL-22 "do not guess; settings warning" (no
      -- LINE dispatch content is specified for this case).

    -- ===================================================================
    elsif v_sched.schedule_kind = 'nonpickup_evening_checkin' then
      -- Driven directly by the currently-open nonpickup_evening session (see
      -- the identical dropoff_checkin/pickup_checkin comment above for why
      -- this must not re-derive the recipient from today's pickup
      -- task_instance's own live status — it is very often already
      -- 'completed' by 22:00, which is not evidence the nonpickup adult's
      -- own items are done too).
      declare
        v_sess record;
      begin
        select id, assignee_id, status into v_sess
        from public.routine_checkin_sessions
        where household_id = v_sched.household_id and session_type = 'nonpickup_evening'
          and scheduled_date = v_local_date and status = 'open'
        for update;

        if found then
          select string_agg('・' || t.title, E'\n') into v_incomplete_titles
          from public.routine_checkin_session_items rcsi
          join public.task_instances t on t.household_id = v_sched.household_id and t.id = rcsi.task_instance_id
          where rcsi.household_id = v_sched.household_id and rcsi.session_id = v_sess.id
            and t.status in ('todo', 'in_progress');

          if v_incomplete_titles is null then
            update public.routine_checkin_sessions set status = 'auto_closed' where id = v_sess.id;
          else
            select coalesce(np.routine_checkin_prompt_line, true) into v_line_ok
            from public.notification_preferences np
            where np.household_id = v_sched.household_id and np.user_id = v_sess.assignee_id;

            v_item := jsonb_build_object('title', '📝 夜の実績確認', 'body', 'まだ未完了:' || E'\n' || v_incomplete_titles);
            v_dedup := 'routine-min:' || v_sched.household_id::text || ':' || v_sess.assignee_id::text
              || ':' || v_local_date::text || ':' || v_local_hhmm;
            if private.fn_claim_and_enqueue_routine_notification(
              v_sched.household_id, v_sched.schedule_kind, v_local_date, v_sess.assignee_id,
              v_slot, 'reminder', v_item, v_dedup, coalesce(v_line_ok, true)
            ) then
              v_claimed_count := v_claimed_count + 1;
            end if;
          end if;
        end if;
      end;

    -- ===================================================================
    elsif v_sched.schedule_kind = 'nonworkday_morning_digest' then
      select cc.last_incremental_sync_at, cc.reauth_required into v_conn
      from public.calendar_connections cc
      where cc.household_id = v_sched.household_id and cc.active
      order by cc.created_at
      limit 1;

      v_calendar_warning := null;
      if found and (v_conn.reauth_required
        or v_conn.last_incremental_sync_at is null
        or v_conn.last_incremental_sync_at < now() - interval '60 minutes') then
        v_calendar_warning := E'\n\n⚠ Google予定を最新化できていません';
      end if;

      -- P1-1 source 1 (today) + P1-2 today conflict count. A Calendar-side
      -- read failure must never block the rest of the digest, so both are
      -- wrapped defensively even though they are plain local SELECTs.
      begin
        v_cal_lines := private.fn_calendar_day_lines(v_sched.household_id, v_local_date);
      exception when others then
        v_cal_lines := null;
      end;
      begin
        v_today_conflict_count := private.fn_conflict_task_count(v_sched.household_id, v_local_date, v_local_date, null);
      exception when others then
        v_today_conflict_count := 0;
      end;

      v_weekly_lines := null;
      v_weekly_conflict_count := 0;
      if v_is_sunday then
        v_next_monday := v_local_date + 1;
        begin
          v_weekly_conflict_count := private.fn_conflict_task_count(
            v_sched.household_id, v_next_monday, v_next_monday + 6, null
          );
        exception when others then
          v_weekly_conflict_count := 0;
        end;

        v_weekly_lines := '';
        for v_day in
          select d::date as day
          from generate_series(v_next_monday, v_next_monday + 6, interval '1 day') as d
        loop
          declare
            v_d_dropoff text;
            v_d_pickup text;
          begin
            select coalesce(p.display_name, '未定') into v_d_dropoff
            from public.task_instances ti
            join public.task_definitions td on td.household_id = ti.household_id and td.id = ti.task_definition_id
            left join public.profiles p on p.user_id = ti.planned_assignee_id
            where ti.household_id = v_sched.household_id and ti.scheduled_date = v_day.day
              and td.code = 'dropoff' and ti.status in ('todo', 'in_progress')
            limit 1;
            select coalesce(p.display_name, '未定') into v_d_pickup
            from public.task_instances ti
            join public.task_definitions td on td.household_id = ti.household_id and td.id = ti.task_definition_id
            left join public.profiles p on p.user_id = ti.planned_assignee_id
            where ti.household_id = v_sched.household_id and ti.scheduled_date = v_day.day
              and td.code = 'pickup' and ti.status in ('todo', 'in_progress')
            limit 1;

            v_day_dropoff_pickup := null;
            if v_d_dropoff is not null or v_d_pickup is not null then
              v_day_dropoff_pickup := '送り:' || coalesce(v_d_dropoff, '-') || ' 迎え:' || coalesce(v_d_pickup, '-');
            end if;

            -- source 4: special-preparation tasks, same generic-FYI shape
            -- the original migration used for the 07:00 daily message.
            select string_agg('・' || ti.title, E'\n') into v_day_prep
            from public.task_instances ti
            join public.task_definitions td on td.household_id = ti.household_id and td.id = ti.task_definition_id
            where ti.household_id = v_sched.household_id and ti.scheduled_date = v_day.day
              and ti.routine_phase = 'morning' and td.code <> 'dropoff'
              and ti.status in ('todo', 'in_progress');

            -- source 5: due request/shopping/manual-task highlights for
            -- this single day. No per-viewer own-task list exists in the
            -- shared weekly section, so no dedup exclusion applies here.
            begin
              v_day_hl := private.fn_due_highlight_lines(v_sched.household_id, v_day.day, v_day.day, null);
            exception when others then
              v_day_hl := null;
            end;

            -- source 1: Google Calendar occurrences touching this day
            -- (multi-day events recur on every day they span, per fn_
            -- calendar_day_lines' own day-membership predicate).
            begin
              v_day_cal := private.fn_calendar_day_lines(v_sched.household_id, v_day.day);
            exception when others then
              v_day_cal := null;
            end;

            if v_day_dropoff_pickup is not null or v_day_prep is not null
               or v_day_hl is not null or v_day_cal is not null then
              v_weekday_label := (array['月', '火', '水', '木', '金', '土', '日'])[extract(isodow from v_day.day)::int];
              v_day_block := to_char(v_day.day, 'MM/DD') || '(' || v_weekday_label || ')'
                || case when v_day_dropoff_pickup is not null then E'\n' || v_day_dropoff_pickup else '' end
                || case when v_day_prep is not null then E'\n' || v_day_prep else '' end
                || case when v_day_hl is not null then E'\n' || v_day_hl else '' end
                || case when v_day_cal is not null then E'\n' || v_day_cal else '' end;
              v_weekly_lines := v_weekly_lines || case when v_weekly_lines = '' then '' else E'\n\n' end || v_day_block;
            end if;
          end;
        end loop;
        if v_weekly_lines = '' then
          v_weekly_lines := null;
        end if;
      end if;

      for v_adult in
        select user_id from public.household_members
        where household_id = v_sched.household_id and member_role = 'adult'
      loop
        select string_agg('・' || t.title, E'\n') into v_own_titles
        from public.task_instances t
        where t.household_id = v_sched.household_id and t.scheduled_date = v_local_date
          and t.planned_assignee_id = v_adult.user_id and t.status in ('todo', 'in_progress');

        -- source 5 for today, excluding anything already shown verbatim in
        -- v_own_titles above (P1-1's no-duplicate-line requirement).
        begin
          v_hl_lines := private.fn_due_highlight_lines(v_sched.household_id, v_local_date, v_local_date, v_adult.user_id);
        exception when others then
          v_hl_lines := null;
        end;

        select coalesce(np.weekly_digest_line, true), coalesce(np.conflict_line, true)
          into v_line_ok, v_conflict_ok
        from public.notification_preferences np
        where np.household_id = v_sched.household_id and np.user_id = v_adult.user_id;

        v_body := '📅 今日の予定' || E'\n' || coalesce(v_own_titles, '（予定なし）')
          || case when v_cal_lines is not null then E'\n\n🗓 今日のカレンダー' || E'\n' || v_cal_lines else '' end
          || case when v_hl_lines is not null then E'\n\n📌 期限のある共有タスク' || E'\n' || v_hl_lines else '' end
          || coalesce(v_calendar_warning, '')
          || case
               when v_today_conflict_count > 0 and coalesce(v_conflict_ok, true)
                 then E'\n\n⚠ 担当と予定の重なり ' || v_today_conflict_count || E'件\n→ Family Opsで確認'
               else ''
             end
          || case
               when v_weekly_lines is not null
                 then E'\n\n📅 来週の予定' || E'\n' || v_weekly_lines
                   || case
                        when v_weekly_conflict_count > 0 and coalesce(v_conflict_ok, true)
                          then E'\n\n⚠ 担当と予定の重なり ' || v_weekly_conflict_count || E'件\n→ Family Opsで確認'
                        else ''
                      end
               else ''
             end;

        v_item := jsonb_build_object('title', case when v_is_sunday then '📅 今日・来週の予定' else '📅 今日の予定' end, 'body', v_body);
        v_dedup := 'routine-min:' || v_sched.household_id::text || ':' || v_adult.user_id::text
          || ':' || v_local_date::text || ':' || v_local_hhmm;
        if private.fn_claim_and_enqueue_routine_notification(
          v_sched.household_id, v_sched.schedule_kind, v_local_date, v_adult.user_id,
          v_slot, 'normal', v_item, v_dedup, coalesce(v_line_ok, true)
        ) then
          v_claimed_count := v_claimed_count + 1;
        end if;
      end loop;

    -- ===================================================================
    elsif v_sched.schedule_kind = 'nonworkday_checkin' then
      for v_adult in
        select user_id from public.household_members
        where household_id = v_sched.household_id and member_role = 'adult'
      loop
        select string_agg('・' || t.title, E'\n') into v_incomplete_titles
        from public.task_instances t
        where t.household_id = v_sched.household_id and t.scheduled_date = v_local_date
          and t.planned_assignee_id = v_adult.user_id and t.status in ('todo', 'in_progress');

        -- #7A "one recipient has no incomplete item -> suppress only that
        -- recipient's 20:00 delivery" (SL-V6-04).
        if v_incomplete_titles is not null then
          select coalesce(np.routine_checkin_prompt_line, true) into v_line_ok
          from public.notification_preferences np
          where np.household_id = v_sched.household_id and np.user_id = v_adult.user_id;

          v_item := jsonb_build_object('title', '📝 今日の実績確認', 'body', 'まだ未完了:' || E'\n' || v_incomplete_titles);
          v_dedup := 'routine-min:' || v_sched.household_id::text || ':' || v_adult.user_id::text
            || ':' || v_local_date::text || ':' || v_local_hhmm;
          if private.fn_claim_and_enqueue_routine_notification(
            v_sched.household_id, v_sched.schedule_kind, v_local_date, v_adult.user_id,
            v_slot, 'reminder', v_item, v_dedup, coalesce(v_line_ok, true)
          ) then
            v_claimed_count := v_claimed_count + 1;
          end if;
        end if;
      end loop;
    end if;
  end loop;

  return jsonb_build_object(
    'local_date', v_local_date, 'local_time', v_local_hhmm,
    'is_nonworkday', v_is_nonworkday, 'schedules_evaluated', v_evaluated_count,
    'notifications_claimed', v_claimed_count
  );
end;
$$;

revoke all on function public.server_tx_dispatch_routine_automation(timestamptz, int) from public;
revoke all on function public.server_tx_dispatch_routine_automation(timestamptz, int) from anon;
revoke all on function public.server_tx_dispatch_routine_automation(timestamptz, int) from authenticated;
grant execute on function public.server_tx_dispatch_routine_automation(timestamptz, int) to service_role;
