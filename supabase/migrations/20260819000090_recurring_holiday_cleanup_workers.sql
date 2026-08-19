-- WP11 gap-close: three normative daily/weekly cron workers were specified
-- (docs/design/v6/09_API_AND_EDGE_FUNCTIONS.md #13/#14/#19,
-- 01_ARCHITECTURE.md's CRON diagram) but never built by any prior WP —
-- confirmed by cross-checking the deployed 49 functions against the
-- vendored 52-function matrix (materialize-recurring, sync-jp-holidays,
-- cleanup-expired-private-data were the only three normative names still
-- missing). These are load-bearing for functionality the user explicitly
-- requested ("定時通知"/"土日祝処理"): without materialize-recurring, the
-- recurrence engine's rolling window never advances past whatever the rule
-- was created/last touched; without sync-jp-holidays, the holiday cache
-- WP8's dispatcher already reads goes stale; cleanup-expired-private-data is
-- the retention sweep #14 specifies for several tables already accumulating
-- rows (raw_inputs, link tokens, webhook/notification queues, Google
-- staging/tombstones/watch metadata).

-- ---------------------------------------------------------------------------
-- #13 Recurrence worker: daily 00:10 Asia/Tokyo, today..+14d, all active
-- rules. private.materialize_recurrence_rule (WP1, amended WP3) already does
-- the single-rule work and is itself idempotent (upserts by stable logical
-- key) — this just drives it across every currently-active rule, once per
-- calendar day, using private.worker_run_receipts the same way WP8's
-- dispatcher uses private.scheduled_dispatch_receipts for its own slots.
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_materialize_recurring_batch(
  p_today date
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_rule record;
  v_materialized int := 0;
  v_failed int := 0;
begin
  if p_today is null then
    raise exception 'INVALID_INPUT';
  end if;

  insert into private.worker_run_receipts (worker_kind, logical_slot_key)
  values ('materialize-recurring', p_today::text)
  on conflict (worker_kind, logical_slot_key) do nothing;

  if not found then
    -- Already ran (or is running) for this Asia/Tokyo day — cron retry
    -- within the same day is a no-op, matching every other scheduled-worker
    -- idempotency guard in this codebase.
    return jsonb_build_object('already_ran', true, 'materialized', 0, 'failed', 0);
  end if;

  for v_rule in
    select id, household_id
    from public.recurrence_rules
    where active = true
      and effective_from <= p_today
      and (effective_to is null or effective_to >= p_today)
  loop
    begin
      perform private.materialize_recurrence_rule(
        v_rule.household_id, v_rule.id, p_today, p_today + 14
      );
      v_materialized := v_materialized + 1;
    exception when others then
      -- One bad rule must never abort the whole daily batch for every other
      -- household — log via the return payload (the Edge Function logs
      -- server-side) and continue.
      v_failed := v_failed + 1;
    end;
  end loop;

  update private.worker_run_receipts
  set completed_at = now(),
      result = jsonb_build_object('materialized', v_materialized, 'failed', v_failed)
  where worker_kind = 'materialize-recurring' and logical_slot_key = p_today::text;

  return jsonb_build_object('already_ran', false, 'materialized', v_materialized, 'failed', v_failed);
end;
$$;

revoke all on function public.server_tx_materialize_recurring_batch(date) from public;
revoke all on function public.server_tx_materialize_recurring_batch(date) from anon;
revoke all on function public.server_tx_materialize_recurring_batch(date) from authenticated;
grant execute on function public.server_tx_materialize_recurring_batch(date) to service_role;

-- ---------------------------------------------------------------------------
-- #19 Japan holiday sync: weekly Sunday 03:00 JST, upsert-only (#19
-- "partial/failure never deletes known future rows" — the CSV fetch/parse
-- happens in the Edge Function; this RPC only ever inserts/updates rows it
-- was actually given, never deletes anything private.jp_holidays already
-- has).
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_upsert_jp_holidays(
  p_holidays jsonb,
  p_source text default 'cao_csv'
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_count int;
begin
  if p_holidays is null or jsonb_typeof(p_holidays) <> 'array' then
    raise exception 'INVALID_INPUT';
  end if;

  with rows as (
    select
      (elem ->> 'date')::date as local_date,
      elem ->> 'name' as name
    from jsonb_array_elements(p_holidays) as elem
  )
  insert into private.jp_holidays (local_date, name, source, source_fetched_at)
  select local_date, name, p_source, now()
  from rows
  where local_date is not null and name is not null
  on conflict (local_date) do update
    set name = excluded.name,
        source = excluded.source,
        source_fetched_at = excluded.source_fetched_at;

  get diagnostics v_count = row_count;
  return jsonb_build_object('upserted', v_count);
end;
$$;

revoke all on function public.server_tx_upsert_jp_holidays(jsonb, text) from public;
revoke all on function public.server_tx_upsert_jp_holidays(jsonb, text) from anon;
revoke all on function public.server_tx_upsert_jp_holidays(jsonb, text) from authenticated;
grant execute on function public.server_tx_upsert_jp_holidays(jsonb, text) to service_role;

-- ---------------------------------------------------------------------------
-- #14 Cleanup: fixed retention sweep. Every rule below is taken directly
-- from 09_API_AND_EDGE_FUNCTIONS.md #14's list. The one rule requiring a
-- documented interpretation rather than a literal transcription is the
-- cancelled-recurring-exception tombstone ("retain while parent recurring
-- event is canonical-active or until projection horizon passes exception,
-- whichever is later"): implemented here as retain-if-EITHER the parent
-- event (matched via calendar_events_cache.recurring_event_id ->
-- another row's google_event_id in the same calendar_connection_id) is
-- still present and not itself a tombstone, OR the tombstone's own
-- updated_at is within the same 30-day floor already given to ordinary
-- deleted tombstones (a defensible, conservative reading — a genuinely
-- future exception is caught by the "parent still active" arm; the 30-day
-- floor prevents deleting a very-recently-superseded exception before any
-- consumer had a chance to observe its tombstone, mirroring the ordinary
-- tombstone's own grace period exactly).
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_cleanup_expired_private_data(
  p_now timestamptz default now()
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_raw_inputs int;
  v_line_link_tokens int;
  v_household_invites int;
  v_webhook_redacted int;
  v_webhook_deleted int;
  v_notification_sent int;
  v_notification_dead int;
  v_google_staging int;
  v_google_write_ops int;
  v_google_watch int;
  v_calendar_tombstones_deleted int;
  v_calendar_tombstones_cancelled_exc int;
begin
  delete from private.raw_inputs where expires_at <= p_now;
  get diagnostics v_raw_inputs = row_count;

  delete from private.line_link_tokens
  where (used_at is not null or expires_at <= p_now) and coalesce(used_at, expires_at) <= p_now - interval '7 days';
  get diagnostics v_line_link_tokens = row_count;

  delete from private.household_invites
  where (used_at is not null or expires_at <= p_now) and coalesce(used_at, expires_at) <= p_now - interval '30 days';
  get diagnostics v_household_invites = row_count;

  -- webhook_inbox: redact payload for done/dead rows older than 14d (still
  -- keep the row itself for the attempt/status audit trail), then hard
  -- delete dead rows once they're 30d old (matching "dead metadata: 30d").
  -- 'done' rows have no separate deletion rule specified, so they are kept
  -- indefinitely (payload already redacted) — only their payload shrinks.
  update private.webhook_inbox
  set payload = '{}'::jsonb
  where status in ('done', 'dead')
    and payload <> '{}'::jsonb
    and coalesce(processed_at, received_at) <= p_now - interval '14 days';
  get diagnostics v_webhook_redacted = row_count;

  delete from private.webhook_inbox
  where status = 'dead' and coalesce(processed_at, received_at) <= p_now - interval '30 days';
  get diagnostics v_webhook_deleted = row_count;

  delete from private.notification_outbox
  where status = 'sent' and coalesce(sent_at, created_at) <= p_now - interval '30 days';
  get diagnostics v_notification_sent = row_count;

  delete from private.notification_outbox
  where status = 'dead' and created_at <= p_now - interval '90 days';
  get diagnostics v_notification_dead = row_count;

  delete from private.google_event_staging where received_at <= p_now - interval '24 hours';
  get diagnostics v_google_staging = row_count;

  -- google_write_operations has no explicit retention rule in #14; a
  -- terminal (succeeded/dead) row past the same 30-day floor used for other
  -- terminal-state queue rows is a reasonable, conservative default so this
  -- table doesn't grow unbounded — 'pending'/'conflict' rows are never
  -- touched (still in-flight or awaiting resolution).
  delete from private.google_write_operations
  where status in ('succeeded', 'dead') and updated_at <= p_now - interval '30 days';
  get diagnostics v_google_write_ops = row_count;

  delete from private.google_watch_channels
  where status in ('stopped', 'expired') and updated_at <= p_now - interval '30 days';
  get diagnostics v_google_watch = row_count;

  delete from public.calendar_events_cache
  where tombstone_kind = 'deleted' and updated_at <= p_now - interval '30 days';
  get diagnostics v_calendar_tombstones_deleted = row_count;

  delete from public.calendar_events_cache ce
  where ce.tombstone_kind = 'cancelled_exception'
    and ce.updated_at <= p_now - interval '30 days'
    and not exists (
      select 1
      from public.calendar_events_cache parent
      where parent.calendar_connection_id = ce.calendar_connection_id
        and parent.google_event_id = ce.recurring_event_id
        and parent.tombstone_kind is null
    );
  get diagnostics v_calendar_tombstones_cancelled_exc = row_count;

  return jsonb_build_object(
    'raw_inputs', v_raw_inputs,
    'line_link_tokens', v_line_link_tokens,
    'household_invites', v_household_invites,
    'webhook_payload_redacted', v_webhook_redacted,
    'webhook_dead_deleted', v_webhook_deleted,
    'notification_sent_deleted', v_notification_sent,
    'notification_dead_deleted', v_notification_dead,
    'google_staging_deleted', v_google_staging,
    'google_write_operations_deleted', v_google_write_ops,
    'google_watch_channels_deleted', v_google_watch,
    'calendar_tombstones_deleted', v_calendar_tombstones_deleted,
    'calendar_cancelled_exception_tombstones_deleted', v_calendar_tombstones_cancelled_exc
  );
end;
$$;

revoke all on function public.server_tx_cleanup_expired_private_data(timestamptz) from public;
revoke all on function public.server_tx_cleanup_expired_private_data(timestamptz) from anon;
revoke all on function public.server_tx_cleanup_expired_private_data(timestamptz) from authenticated;
grant execute on function public.server_tx_cleanup_expired_private_data(timestamptz) to service_role;
