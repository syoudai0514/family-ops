-- WP8 (Routine LINE automation): the every-minute scheduler
-- (17_ROUTINE_LINE_AUTOMATION.md #13 "Scheduler worker"). This is the
-- transactional core public.server_tx_dispatch_routine_automation the
-- dispatch-routine-automation Edge Function calls once per invocation; the
-- Edge Function itself only checks the worker token and forwards `now()`
-- (same split as send-notifications/process-line-inbox: all business logic
-- lives in SQL, the Edge Function is a thin authenticated trigger).
--
-- MVP simplifications not pinned down verbatim by the doc (flagged per house
-- style; see docs/adr/0007 for the write-up):
--   - "conflict warningが既に計算済みなら追記" (#4) is omitted — no WP has ever
--     computed/stored a conflict result anywhere in this codebase (confirmed
--     by docs/adr/0006's own deferral of calendar conflict notifications).
--   - The weekly digest's Google Calendar occurrence merge (#3 "source 1.
--     Google Calendar rolling occurrence projection") is omitted; the
--     household-assignment (dropoff/pickup/special-prep) half of the digest
--     — the half #3's own "Calendar障害で家事担当まで送れなくなる設計にしない"
--     sentence insists must never depend on Calendar — is implemented in
--     full, plus the stale/reauth Calendar warning line.
--   - "特別準備task" detection uses routine_phase='morning' non-dropoff
--     active task_instances for the day as a generic FYI line, not a
--     dedicated category flag (no such flag exists in the schema).
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

      for v_adult in
        select user_id from public.household_members
        where household_id = v_sched.household_id and member_role = 'adult'
      loop
        select coalesce(np.daily_assignment_line, true) into v_line_ok
        from public.notification_preferences np
        where np.household_id = v_sched.household_id and np.user_id = v_adult.user_id;

        v_item := jsonb_build_object('title', '☀️ 今日の担当', 'body', v_body);
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

      v_weekly_lines := null;
      if v_is_sunday then
        v_next_monday := v_local_date + 1;
        v_weekly_lines := '';
        for v_day in
          select d::date as day
          from generate_series(v_next_monday, v_next_monday + 6, interval '1 day') as d
        loop
          declare
            v_d_dropoff text;
            v_d_pickup text;
            v_line text;
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
            if v_d_dropoff is not null or v_d_pickup is not null then
              v_line := to_char(v_day.day, 'MM/DD') || ' 送り:' || coalesce(v_d_dropoff, '-')
                || ' 迎え:' || coalesce(v_d_pickup, '-');
              v_weekly_lines := v_weekly_lines || case when v_weekly_lines = '' then '' else E'\n' end || v_line;
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

        v_body := '📅 今日の予定' || E'\n' || coalesce(v_own_titles, '（予定なし）')
          || coalesce(v_calendar_warning, '')
          || case when v_weekly_lines is not null then E'\n\n📅 来週の予定' || E'\n' || v_weekly_lines else '' end;

        select coalesce(np.weekly_digest_line, true) into v_line_ok
        from public.notification_preferences np
        where np.household_id = v_sched.household_id and np.user_id = v_adult.user_id;

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
