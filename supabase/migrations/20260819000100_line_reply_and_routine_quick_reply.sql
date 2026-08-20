-- P1-3 / P1-4 fix (independent design review by "Sol"): LINE routine
-- messages carry no actionable buttons, and process-line-inbox never uses
-- LINE's free Reply API for its own webhook-triggered confirmations. See
-- docs/adr/0009-line-quick-reply-and-reply-first-delivery.md for the full
-- write-up; this migration is the DB-side half of that fix. The
-- Edge-Function half lives in supabase/functions/process-line-inbox/index.ts,
-- supabase/functions/send-notifications/index.ts, and the new
-- supabase/functions/_shared/lineMessaging.ts.
--
-- docs/adr/0007 decision 5 already named this exact gap ("LINE quick-reply/
-- postback buttons themselves are not sent") as a flagged P1. This migration
-- does NOT edit 20260819000082_dispatch_routine_automation_rpc.sql (owned by
-- a parallel P1-1/P1-2 fix) or 20260819000081_routine_session_helpers_and_
-- reassignment.sql directly -- instead it CREATE OR REPLACEs the one
-- function both files funnel every routine LINE send through,
-- private.fn_claim_and_enqueue_routine_notification, following the same
-- "amend an existing function in place via a later migration" house style
-- ADR 0007 itself cites (WP3 amending WP1's
-- private.materialize_recurrence_rule in 20260819000023).

-- ---------------------------------------------------------------------------
-- 1) private.fn_claim_and_enqueue_routine_notification: attach session
--    context to session-bearing items.
-- ---------------------------------------------------------------------------
-- Every schedule_kind that has a routine_checkin_sessions row
-- (dropoff/pickup checklist+checkin, nonpickup_evening checklist+checkin)
-- already get-or-creates (checklist branches) or FOR UPDATE-selects
-- (checkin branches) that session's 'open' row in
-- 20260819000082_dispatch_routine_automation_rpc.sql BEFORE calling this
-- function, in the same transaction -- so the lookup below always finds it
-- when one exists, without needing dispatch's own call sites to change.
-- daily_assignment and both nonworkday_* schedule kinds have no session
-- (nonworkday_checkin reads task_instances directly, per #7A) and are left
-- exactly as before: an item with no 'session_id' key.
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
  v_session_type text;
  v_session_id uuid;
  v_item jsonb := p_item;
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
    v_session_type := case p_schedule_kind
      when 'dropoff_checklist' then 'dropoff'
      when 'dropoff_checkin' then 'dropoff'
      when 'pickup_checklist' then 'pickup'
      when 'pickup_checkin' then 'pickup'
      when 'nonpickup_evening_checklist' then 'nonpickup_evening'
      when 'nonpickup_evening_checkin' then 'nonpickup_evening'
      else null
    end;

    if v_session_type is not null then
      select id into v_session_id
      from public.routine_checkin_sessions
      where household_id = p_household_id and session_type = v_session_type
        and scheduled_date = p_scheduled_local_date and assignee_id = p_recipient_user_id
        and status = 'open'
      order by created_at desc
      limit 1;

      if v_session_id is not null then
        -- send-notifications reads item.session_id to build the
        -- 全部完了/今回は不要 LINE quick-reply postback buttons and the
        -- {APP_BASE_URL}/checkin/{session_id} deep link
        -- (06_LINE_INTEGRATION.md #8 "No bearer credential in URL" --
        -- session_id is an opaque canonical id, same as the existing
        -- postback contract already uses).
        v_item := v_item || jsonb_build_object('session_id', v_session_id, 'session_type', v_session_type);
      end if;
    end if;

    insert into private.notification_outbox
      (household_id, recipient_user_id, channel, type, payload, dedup_key, priority)
    values
      (p_household_id, p_recipient_user_id, 'line', 'routine',
       jsonb_build_object('items', jsonb_build_array(v_item)),
       p_dedup_minute_key, coalesce(p_priority, 'normal'))
    on conflict (recipient_user_id, channel, dedup_key) do update
      set payload = jsonb_set(
        private.notification_outbox.payload, '{items}',
        coalesce(private.notification_outbox.payload -> 'items', '[]'::jsonb) || jsonb_build_array(v_item)
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
-- 2) server_tx_enqueue_immediate_line_push: the push-fallback path for
--    process-line-inbox's reply-first confirmations (P1-4).
-- ---------------------------------------------------------------------------
-- 06_LINE_INTEGRATION.md #10A "Reply": "use Reply API first ... Reply
-- messages do not consume counted monthly push allowance." process-line-inbox
-- (via the new _shared/lineMessaging.ts helper) attempts LINE's Reply API
-- directly and, ONLY when that is unavailable/fails, calls this RPC to
-- enqueue a normal, quota-counted, immediate-priority outbox row -- reusing
-- send-notifications' existing claim/quota-reserve/push/retry machinery
-- rather than duplicating any of it or ever calling the LINE push endpoint
-- from process-line-inbox itself. This is the ONLY path into
-- private.notification_outbox this migration adds outside the routine
-- dispatcher; it never touches private.line_quota_reservations or any
-- quota RPC directly (06_LINE_INTEGRATION.md #10A step-by-step "before
-- counted push" sequence lives entirely in send-notifications, unchanged).
--
-- p_dedup_key should be caller-supplied and derived from the triggering
-- webhook event (process-line-inbox passes a key derived from
-- provider_event_id) so that redelivery of the same webhook event naturally
-- collapses to the same outbox row via the table's existing
-- unique(recipient_user_id, channel, dedup_key) constraint, instead of
-- sending the fallback confirmation twice. A caller that has no natural key
-- gets a random one (never bundles, never collides) rather than failing.
create or replace function public.server_tx_enqueue_immediate_line_push(
  p_household_id uuid,
  p_recipient_user_id uuid,
  p_text text,
  p_dedup_key text default null
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_dedup text := coalesce(p_dedup_key, 'line-reply-fallback:' || gen_random_uuid()::text);
  v_id uuid;
begin
  if p_household_id is null or p_recipient_user_id is null or coalesce(p_text, '') = '' then
    raise exception 'INVALID_INPUT';
  end if;
  if not exists (
    select 1 from public.household_members
    where household_id = p_household_id and user_id = p_recipient_user_id
  ) then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  insert into private.notification_outbox
    (household_id, recipient_user_id, channel, type, payload, dedup_key, priority, business_expires_at)
  values
    (p_household_id, p_recipient_user_id, 'line', 'line_reply_fallback',
     jsonb_build_object('items', jsonb_build_array(jsonb_build_object('title', p_text))),
     v_dedup, 'normal', now() + interval '1 hour')
  on conflict (recipient_user_id, channel, dedup_key) do nothing
  returning id into v_id;

  if v_id is null then
    -- Redelivered webhook event with the same derived dedup key: the
    -- original fallback row (or a prior send of it) already exists --
    -- report success without a second row (P1-4 "concurrent webhook retry
    -- does not double-send" for this best-effort path).
    select id into v_id from private.notification_outbox
    where recipient_user_id = p_recipient_user_id and channel = 'line' and dedup_key = v_dedup;
  end if;

  return jsonb_build_object('ok', true, 'notification_outbox_id', v_id);
end;
$$;

revoke all on function public.server_tx_enqueue_immediate_line_push(uuid, uuid, text, text) from public;
revoke all on function public.server_tx_enqueue_immediate_line_push(uuid, uuid, text, text) from anon;
revoke all on function public.server_tx_enqueue_immediate_line_push(uuid, uuid, text, text) from authenticated;
grant execute on function public.server_tx_enqueue_immediate_line_push(uuid, uuid, text, text) to service_role;
