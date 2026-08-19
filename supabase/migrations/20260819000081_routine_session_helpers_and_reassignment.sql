-- WP8 (Routine LINE automation): session get-or-create/supersede helpers,
-- shared by dispatch-routine-automation (20260819000082) and by this
-- migration's own amendment of server_tx_reassign_task_once (WP3,
-- 20260819000025) to close the exact gap that migration's own header
-- comment flagged: "routine_checkin_sessions ... does not yet have a
-- WP3-owned write path." Same house-style precedent as WP3 amending WP1's
-- private.materialize_recurrence_rule in place
-- (20260819000023_recurrence_role_resolver.sql) rather than forking a
-- parallel function.

-- ---------------------------------------------------------------------------
-- private.jp_holidays is the workday/non-workday source
-- (17_ROUTINE_LINE_AUTOMATION.md #2 "is_nonworkday = weekend OR
-- private.jp_holidays row").
-- ---------------------------------------------------------------------------
create or replace function private.fn_is_nonworkday(p_local_date date)
returns boolean
language sql
stable
security invoker
set search_path = ''
as $$
  select extract(isodow from p_local_date)::int in (6, 7)
    or exists (select 1 from private.jp_holidays where local_date = p_local_date);
$$;

revoke all on function private.fn_is_nonworkday(date) from public;
revoke all on function private.fn_is_nonworkday(date) from anon;
revoke all on function private.fn_is_nonworkday(date) from authenticated;
grant execute on function private.fn_is_nonworkday(date) to service_role;

-- ---------------------------------------------------------------------------
-- Get-or-create/reopen a dropoff|pickup|nonpickup_evening session for
-- (household, session_type, scheduled_date, assignee) and (re)populate its
-- item set from currently-active matching task_instances.
--
-- p_anchor_task_instance_id: the dropoff/pickup task_instance itself for
-- those two session types (always included as an item when active); null
-- for nonpickup_evening (17_ROUTINE_LINE_AUTOMATION.md #5 "dropoff task
-- instance自身", #6 has the equivalent for pickup, #7 has no anchor).
--
-- Returns null (creates nothing) when there would be zero active items —
-- #5/#6 always have the anchor so this only actually happens for
-- nonpickup_evening (#7 "20:00時点で0件なら通知なし、sessionも作成しなくてよい",
-- fixture SL-10).
--
-- 15A "A->B->A same-day session": reopening a 'superseded' row (rather than
-- inserting a second row, which the table's own
-- unique(household_id, session_type, scheduled_date, assignee_id) forbids
-- anyway) bumps assignment_generation and clears superseded_at, matching
-- "reuse/lock old superseded A row ... status=open, assignment_generation++
-- ... no second A insert" verbatim.
create or replace function private.fn_get_or_create_routine_session(
  p_household_id uuid,
  p_session_type text,
  p_scheduled_date date,
  p_assignee_id uuid,
  p_phase text,
  p_anchor_task_instance_id uuid
)
returns uuid
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_candidate_ids uuid[];
  v_session_id uuid;
  v_status text;
begin
  if p_assignee_id is null then
    return null;
  end if;

  select coalesce(array_agg(id), '{}') into v_candidate_ids
  from (
    select id from public.task_instances
    where household_id = p_household_id and id = p_anchor_task_instance_id
      and status in ('todo', 'in_progress')
    union
    select id from public.task_instances
    where household_id = p_household_id and scheduled_date = p_scheduled_date
      and routine_phase = p_phase and planned_assignee_id = p_assignee_id
      and status in ('todo', 'in_progress')
      and (p_anchor_task_instance_id is null or id <> p_anchor_task_instance_id)
  ) candidates;

  if array_length(v_candidate_ids, 1) is null then
    return null;
  end if;

  select id, status into v_session_id, v_status
  from public.routine_checkin_sessions
  where household_id = p_household_id and session_type = p_session_type
    and scheduled_date = p_scheduled_date and assignee_id = p_assignee_id
  for update;

  if not found then
    insert into public.routine_checkin_sessions
      (household_id, session_type, scheduled_date, assignee_id, status, assignment_generation)
    values (p_household_id, p_session_type, p_scheduled_date, p_assignee_id, 'open', 1)
    returning id into v_session_id;
  elsif v_status = 'superseded' then
    update public.routine_checkin_sessions
    set status = 'open', superseded_at = null, opened_at = now(),
        submitted_at = null, assignment_generation = assignment_generation + 1
    where id = v_session_id;
  end if;
  -- open/submitted/auto_closed: reuse as-is; a live dispatch re-check may
  -- still add newly-materialized items below.

  insert into public.routine_checkin_session_items
    (household_id, session_id, task_instance_id, display_order)
  select p_household_id, v_session_id, cid,
    row_number() over (order by td.sort_order, ti.created_at)
  from unnest(v_candidate_ids) as cid
  join public.task_instances ti on ti.household_id = p_household_id and ti.id = cid
  left join public.task_definitions td on td.household_id = p_household_id and td.id = ti.task_definition_id
  on conflict (session_id, task_instance_id) do nothing;

  return v_session_id;
end;
$$;

revoke all on function private.fn_get_or_create_routine_session(uuid, text, date, uuid, text, uuid) from public;
revoke all on function private.fn_get_or_create_routine_session(uuid, text, date, uuid, text, uuid) from anon;
revoke all on function private.fn_get_or_create_routine_session(uuid, text, date, uuid, text, uuid) from authenticated;
grant execute on function private.fn_get_or_create_routine_session(uuid, text, date, uuid, text, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- Supersede whatever open/submitted/auto_closed session currently exists for
-- this (household, session_type, scheduled_date, assignee) key, if any.
-- ---------------------------------------------------------------------------
create or replace function private.fn_supersede_routine_session(
  p_household_id uuid,
  p_session_type text,
  p_scheduled_date date,
  p_assignee_id uuid
)
returns void
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if p_assignee_id is null then
    return;
  end if;

  update public.routine_checkin_sessions
  set status = 'superseded', superseded_at = now()
  where household_id = p_household_id and session_type = p_session_type
    and scheduled_date = p_scheduled_date and assignee_id = p_assignee_id
    and status in ('open', 'submitted', 'auto_closed');
end;
$$;

revoke all on function private.fn_supersede_routine_session(uuid, text, date, uuid) from public;
revoke all on function private.fn_supersede_routine_session(uuid, text, date, uuid) from anon;
revoke all on function private.fn_supersede_routine_session(uuid, text, date, uuid) from authenticated;
grant execute on function private.fn_supersede_routine_session(uuid, text, date, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- Claim-then-bundle: the exact-once dispatch primitive #10/"bundle" +
-- "scheduled send" describe, shared by every schedule_kind branch in
-- dispatch-routine-automation (20260819000082).
--
-- Claims private.scheduled_dispatch_receipts's semantic-one-send-guard row
-- first (household_id, schedule_kind, scheduled_local_date,
-- recipient_user_id) — a second call for the identical logical slot
-- (same-minute cron retry, or a same-day schedule_version edit after
-- today's row already exists) hits that unique constraint and does nothing
-- further, satisfying #10's "same-day schedule edit ... 既にその日/週の
-- receiptがある場合、時刻変更後も自動再送しない" and SL-02/SL-15's cron-retry
-- dedup in one gate.
--
-- Only when newly claimed does it touch private.notification_outbox, and
-- only when p_line_enabled — #11 "userがroutine checklistをOFFにしてもPWA
-- task/sessionは残る": the caller always does its session/task work
-- unconditionally (this function is not in that path at all), but the LINE
-- push itself is gated per-recipient by notification_preferences. The
-- receipt is claimed either way, so re-enabling the preference later that
-- same day never causes a backfired resend — matching #13A's "quota
-- fallbackしてもscheduled_dispatch_receiptは「business dispatch済み」として維持"
-- principle applied to the preference-off case too.
--
-- Bundling: multiple schedule_kinds due at the same recipient + local
-- minute (e.g. daily_assignment + dropoff_checklist, both defaulting to
-- 07:00 — #4 "07:00 bundling") each independently claim their own receipt
-- row (different schedule_kind => different unique key) but upsert into the
-- SAME notification_outbox row via the ON CONFLICT on
-- (recipient_user_id, channel, dedup_key), appending into payload.items —
-- the exact shape send-notifications' buildBundledText already renders
-- (20260819000070's bridge trigger established this same
-- one-row-many-items convention for the event-driven case).
create or replace function private.fn_claim_and_enqueue_routine_notification(
  p_household_id uuid,
  p_schedule_kind text,
  p_scheduled_local_date date,
  p_recipient_user_id uuid,
  p_dispatch_slot_key text,
  p_priority text,
  p_item jsonb,
  p_dedup_minute_key text,
  p_line_enabled boolean
)
returns boolean
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_receipt_id uuid;
  v_outbox_id uuid;
begin
  insert into private.scheduled_dispatch_receipts
    (household_id, schedule_kind, scheduled_local_date, recipient_user_id, dispatch_slot_key)
  values (p_household_id, p_schedule_kind, p_scheduled_local_date, p_recipient_user_id, p_dispatch_slot_key)
  on conflict (household_id, schedule_kind, scheduled_local_date, recipient_user_id) do nothing
  returning id into v_receipt_id;

  if v_receipt_id is null then
    return false;
  end if;

  if coalesce(p_line_enabled, true) then
    insert into private.notification_outbox
      (household_id, recipient_user_id, channel, type, payload, dedup_key, priority)
    values
      (p_household_id, p_recipient_user_id, 'line', 'routine',
       jsonb_build_object('items', jsonb_build_array(p_item)),
       p_dedup_minute_key, coalesce(p_priority, 'normal'))
    on conflict (recipient_user_id, channel, dedup_key) do update
      set payload = jsonb_set(
        private.notification_outbox.payload, '{items}',
        coalesce(private.notification_outbox.payload -> 'items', '[]'::jsonb) || jsonb_build_array(p_item)
      )
    returning id into v_outbox_id;

    update private.scheduled_dispatch_receipts
    set notification_outbox_id = v_outbox_id
    where id = v_receipt_id;
  end if;

  return true;
end;
$$;

revoke all on function private.fn_claim_and_enqueue_routine_notification(uuid, text, date, uuid, text, text, jsonb, text, boolean) from public;
revoke all on function private.fn_claim_and_enqueue_routine_notification(uuid, text, date, uuid, text, text, jsonb, text, boolean) from anon;
revoke all on function private.fn_claim_and_enqueue_routine_notification(uuid, text, date, uuid, text, text, jsonb, text, boolean) from authenticated;
grant execute on function private.fn_claim_and_enqueue_routine_notification(uuid, text, date, uuid, text, text, jsonb, text, boolean) to service_role;

-- ---------------------------------------------------------------------------
-- reassign-task-once amendment (#15 "after scheduled notification: ...
-- assignment change event; old/new assignee notification outbox; active
-- routine session supersede/rebuild; old assignee future check-in reminder
-- suppression").
--
-- Scope decision (genuine gap, not pinned down verbatim by the doc — flagged
-- per house style, see docs/adr/0007): this amendment only reacts when the
-- reassigned task is TODAY's canonical 'dropoff' or 'pickup' task_instance
-- (identified via task_definitions.code, same identification #17's own
-- resolver migration 20260819000023 already uses). reassign-task-once
-- itself (per its own header comment) can reassign ANY origin='recurring'
-- instance on any date; a future-dated reassignment has no session to
-- supersede yet (sessions are only ever created at same-day dispatch), and a
-- non-dropoff/pickup chore reassignment does not change the dropoff/pickup
-- session identity the LINE check-in loop is keyed on. Reassigning 'pickup'
-- also flips which of the (exactly two, MVP-only) adults is the non-pickup
-- one, so this amendment supersedes/rebuilds the nonpickup_evening session
-- for both adults too; it does NOT retroactively move any individual
-- nonpickup_adult-strategy chore instance's planned_assignee_id (no
-- migration anywhere cascades a role-strategy re-resolution across already
-- materialized task_instances — see 20260819000023's own header comment,
-- "if role cannot resolve, leave unassigned", never "re-resolve on
-- assignment change"), so the rebuilt nonpickup_evening session reflects
-- whatever those instances' planned_assignee_id already says, same as every
-- other dispatch-time read in this WP.
create or replace function public.server_tx_reassign_task_once(
  p_actor_id uuid,
  p_operation_id uuid,
  p_task_id uuid,
  p_new_assignee_user_id uuid
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_request_hash text;
  v_receipt record;
  v_household_id uuid;
  v_task record;
  v_task_code text;
  v_old_assignee uuid;
  v_result jsonb;
  v_today date;
  v_other_adult uuid;
  v_old_nonpickup uuid;
  v_new_nonpickup uuid;
  v_item jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_task_id is null or p_new_assignee_user_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to(
      'reassign-task-once|' || p_task_id::text || '|' || p_new_assignee_user_id::text,
      'UTF8'
    )),
    'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'reassign-task-once', v_request_hash)
    on conflict (actor_id, operation_id) do nothing;

    if found then
      exit;
    end if;

    select * into v_receipt
    from private.mutation_receipts
    where actor_id = p_actor_id and operation_id = p_operation_id
    for update;

    if found then
      if v_receipt.request_hash <> v_request_hash then
        raise exception 'IDEMPOTENCY_CONFLICT';
      end if;
      return v_receipt.result_payload;
    end if;
  end loop;

  select household_id into v_household_id
  from public.household_members
  where user_id = p_actor_id;

  if v_household_id is null then
    raise exception 'NOT_HOUSEHOLD_MEMBER';
  end if;

  if not exists (
    select 1 from public.household_members
    where household_id = v_household_id and user_id = p_new_assignee_user_id
  ) then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  select * into v_task
  from public.task_instances
  where household_id = v_household_id and id = p_task_id
  for update;

  if not found then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;
  if v_task.origin <> 'recurring' then
    raise exception 'INVALID_INPUT';
  end if;
  if v_task.status not in ('todo', 'in_progress') then
    raise exception 'TASK_TERMINAL';
  end if;

  v_old_assignee := v_task.planned_assignee_id;

  update public.task_instances
  set planned_assignee_id = p_new_assignee_user_id
  where household_id = v_household_id and id = p_task_id;

  insert into public.task_events
    (household_id, task_instance_id, actor_id, event_type, payload, source, idempotency_key)
  values
    (v_household_id, p_task_id, p_actor_id, 'reassigned_once',
     jsonb_build_object('old_assignee_id', v_old_assignee, 'new_assignee_id', p_new_assignee_user_id),
     'pwa', p_operation_id::text || ':reassigned_once');

  v_today := (now() at time zone 'Asia/Tokyo')::date;

  if v_task.scheduled_date = v_today then
    select td.code into v_task_code
    from public.task_definitions td
    where td.household_id = v_household_id and td.id = v_task.task_definition_id;

    if v_task_code = 'dropoff' then
      perform private.fn_supersede_routine_session(v_household_id, 'dropoff', v_today, v_old_assignee);
      perform private.fn_get_or_create_routine_session(
        v_household_id, 'dropoff', v_today, p_new_assignee_user_id, 'morning', p_task_id
      );
    elsif v_task_code = 'pickup' then
      perform private.fn_supersede_routine_session(v_household_id, 'pickup', v_today, v_old_assignee);
      perform private.fn_get_or_create_routine_session(
        v_household_id, 'pickup', v_today, p_new_assignee_user_id, 'evening', p_task_id
      );

      -- Non-pickup identity flips with pickup (MVP: exactly two adults).
      if v_old_assignee is not null then
        select user_id into v_old_nonpickup
        from public.household_members
        where household_id = v_household_id and user_id <> v_old_assignee
        limit 1;
      end if;
      select user_id into v_new_nonpickup
      from public.household_members
      where household_id = v_household_id and user_id <> p_new_assignee_user_id
      limit 1;

      if v_old_nonpickup is not null then
        perform private.fn_supersede_routine_session(v_household_id, 'nonpickup_evening', v_today, v_old_nonpickup);
      end if;
      if v_new_nonpickup is not null then
        perform private.fn_get_or_create_routine_session(
          v_household_id, 'nonpickup_evening', v_today, v_new_nonpickup, 'evening', null
        );
      end if;
    end if;

    -- #15 "assignment change event を双方へnotification outbox ... 即時送信済み"
    -- — sent immediately here (not deferred to the next scheduled dispatch),
    -- one dedicated outbox row per recipient keyed by this operation so a
    -- receipt replay never double-sends the change notice.
    if v_task_code in ('dropoff', 'pickup') then
      v_item := jsonb_build_object(
        'title', case when v_task_code = 'dropoff' then '📣 送り担当が変更されました' else '📣 迎え担当が変更されました' end,
        'body', '今日の' || case when v_task_code = 'dropoff' then '送り' else '迎え' end || '担当が変更されました。'
      );
      if v_old_assignee is not null then
        insert into private.notification_outbox
          (household_id, recipient_user_id, channel, type, payload, dedup_key, priority)
        values
          (v_household_id, v_old_assignee, 'line', 'routine_reassignment',
           jsonb_build_object('items', jsonb_build_array(v_item)),
           'routine-reassign:' || p_operation_id::text || ':old', 'normal')
        on conflict (recipient_user_id, channel, dedup_key) do nothing;
      end if;
      insert into private.notification_outbox
        (household_id, recipient_user_id, channel, type, payload, dedup_key, priority)
      values
        (v_household_id, p_new_assignee_user_id, 'line', 'routine_reassignment',
         jsonb_build_object('items', jsonb_build_array(v_item)),
         'routine-reassign:' || p_operation_id::text || ':new', 'normal')
      on conflict (recipient_user_id, channel, dedup_key) do nothing;
    end if;
  end if;

  v_result := jsonb_build_object('ok', true, 'task_id', p_task_id, 'new_assignee_user_id', p_new_assignee_user_id);

  update private.mutation_receipts
  set result_type = 'task_instance', result_id = p_task_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_reassign_task_once(uuid, uuid, uuid, uuid) from public;
revoke all on function public.server_tx_reassign_task_once(uuid, uuid, uuid, uuid) from anon;
revoke all on function public.server_tx_reassign_task_once(uuid, uuid, uuid, uuid) from authenticated;
grant execute on function public.server_tx_reassign_task_once(uuid, uuid, uuid, uuid) to service_role;
