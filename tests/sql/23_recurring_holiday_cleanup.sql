-- WP11 gap-close: server_tx_materialize_recurring_batch,
-- server_tx_upsert_jp_holidays, server_tx_cleanup_expired_private_data
-- (20260819000090_recurring_holiday_cleanup_workers.sql).
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('23000000-0000-0000-0000-000000000001'),
  ('23000000-0000-0000-0000-000000000002');

set role service_role;

do $$
declare
  v_hh jsonb;
begin
  v_hh := public.server_tx_create_household('23000000-0000-0000-0000-000000000001', gen_random_uuid(), 'Cleanup Workers HH', 'Owner');
  insert into public.household_members (household_id, user_id, member_role)
  values ((v_hh->>'household_id')::uuid, '23000000-0000-0000-0000-000000000002', 'adult');
end;
$$;

-- ---------------------------------------------------------------------------
-- materialize-recurring: batch materializes every active rule, is
-- idempotent per Asia/Tokyo day, and does not touch inactive/future/expired
-- rules.
-- ---------------------------------------------------------------------------
do $$
declare
  v_hh_id uuid;
  v_owner uuid := '23000000-0000-0000-0000-000000000001';
  v_dinner_def uuid;
  v_rule jsonb;
  v_rule_id uuid;
  v_batch1 jsonb;
  v_batch2 jsonb;
  v_instance_count int;
begin
  select id into v_hh_id from public.households where name = 'Cleanup Workers HH';
  select id into v_dinner_def from public.task_definitions where household_id = v_hh_id and code = 'dinner';

  v_rule := public.server_tx_change_recurrence(
    v_owner, gen_random_uuid(), v_dinner_def, 3, 'default', 'fixed', v_owner, '18:00', 60, null
  );
  v_rule_id := (v_rule->>'rule_id')::uuid;

  -- change-recurrence already targeted-materializes today..+14d, so clear
  -- the instances it created to prove the *batch* driver (not the targeted
  -- call already exercised by tests/sql/18) is what (re-)populates them.
  delete from public.task_instances where recurrence_rule_id = v_rule_id;

  v_batch1 := public.server_tx_materialize_recurring_batch((now() at time zone 'Asia/Tokyo')::date);
  if (v_batch1->>'already_ran')::boolean is not false then
    raise exception 'FAIL materialize-recurring: first call for a given day must not report already_ran';
  end if;

  select count(*) into v_instance_count
  from public.task_instances
  where recurrence_rule_id = v_rule_id and status = 'todo';
  if v_instance_count = 0 then
    raise exception 'FAIL materialize-recurring: batch must materialize instances for an active rule';
  end if;

  -- Cron retry of the same Asia/Tokyo day must be a no-op, not a second
  -- materialization pass.
  v_batch2 := public.server_tx_materialize_recurring_batch((now() at time zone 'Asia/Tokyo')::date);
  if (v_batch2->>'already_ran')::boolean is not true then
    raise exception 'FAIL materialize-recurring: retry for the same day must report already_ran=true';
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- sync-jp-holidays: upsert is additive-only (existing rows never deleted
-- just because a fetch batch omits them) and updates name on conflict.
-- ---------------------------------------------------------------------------
do $$
declare
  v_before_count int;
  v_after_count int;
  v_name text;
begin
  insert into private.jp_holidays (local_date, name, source, source_fetched_at)
  values ('2099-01-01', 'Old Name', 'cao_csv', now() - interval '30 days')
  on conflict (local_date) do nothing;

  select count(*) into v_before_count from private.jp_holidays;

  perform public.server_tx_upsert_jp_holidays(
    jsonb_build_array(
      jsonb_build_object('date', '2099-01-01', 'name', 'New Name'),
      jsonb_build_object('date', '2099-01-02', 'name', 'Another Day')
    )
  );

  select count(*) into v_after_count from private.jp_holidays;
  if v_after_count < v_before_count + 1 then
    raise exception 'FAIL sync-jp-holidays: upsert must never delete pre-existing rows, only add/update (before=%, after=%)', v_before_count, v_after_count;
  end if;

  select name into v_name from private.jp_holidays where local_date = '2099-01-01';
  if v_name <> 'New Name' then
    raise exception 'FAIL sync-jp-holidays: conflicting local_date must update name in place, got %', v_name;
  end if;
end;
$$;

-- ---------------------------------------------------------------------------
-- cleanup-expired-private-data: spot-check the clearest, least ambiguous
-- retention rules across several tables in one pass (quota/lease mechanics
-- for these queues are already covered by their own WP-specific test
-- files; this only exercises the deletion/redaction thresholds themselves).
-- ---------------------------------------------------------------------------
do $$
declare
  v_hh_id uuid;
  v_owner uuid := '23000000-0000-0000-0000-000000000001';
  v_result jsonb;
  v_raw_expired_id uuid;
  v_raw_fresh_id uuid;
  v_webhook_id uuid;
  v_outbox_sent_id uuid;
  v_outbox_recent_sent_id uuid;
begin
  select id into v_hh_id from public.households where name = 'Cleanup Workers HH';

  -- raw_inputs: one already expired, one still fresh.
  insert into private.raw_inputs (id, household_id, author_user_id, kind, raw_text, expires_at)
  values (gen_random_uuid(), v_hh_id, v_owner, 'natural_language', 'expired', now() - interval '1 hour')
  returning id into v_raw_expired_id;
  insert into private.raw_inputs (id, household_id, author_user_id, kind, raw_text, expires_at)
  values (gen_random_uuid(), v_hh_id, v_owner, 'natural_language', 'fresh', now() + interval '1 hour')
  returning id into v_raw_fresh_id;

  -- webhook_inbox: a 'done' row old enough for payload redaction but not
  -- for deletion (only 'dead' rows are ever hard-deleted by this sweep).
  insert into private.webhook_inbox (id, provider, provider_event_id, payload, status, received_at, processed_at)
  values (gen_random_uuid(), 'line', 'cleanup-test-evt-1', '{"secret":"payload"}'::jsonb, 'done', now() - interval '20 days', now() - interval '20 days')
  returning id into v_webhook_id;

  -- notification_outbox: one 'sent' row past the 30d floor, one recent.
  insert into private.notification_outbox (id, household_id, recipient_user_id, channel, type, payload, dedup_key, status, sent_at)
  values (gen_random_uuid(), v_hh_id, v_owner, 'line', 'test', '{}'::jsonb, 'cleanup-sent-old', 'sent', now() - interval '40 days')
  returning id into v_outbox_sent_id;
  insert into private.notification_outbox (id, household_id, recipient_user_id, channel, type, payload, dedup_key, status, sent_at)
  values (gen_random_uuid(), v_hh_id, v_owner, 'line', 'test', '{}'::jsonb, 'cleanup-sent-recent', 'sent', now() - interval '1 day')
  returning id into v_outbox_recent_sent_id;

  v_result := public.server_tx_cleanup_expired_private_data(now());

  if exists (select 1 from private.raw_inputs where id = v_raw_expired_id) then
    raise exception 'FAIL cleanup: expired raw_inputs row must be deleted';
  end if;
  if not exists (select 1 from private.raw_inputs where id = v_raw_fresh_id) then
    raise exception 'FAIL cleanup: unexpired raw_inputs row must be kept';
  end if;

  if (select payload from private.webhook_inbox where id = v_webhook_id) <> '{}'::jsonb then
    raise exception 'FAIL cleanup: a done webhook_inbox row older than 14d must have its payload redacted';
  end if;
  if not exists (select 1 from private.webhook_inbox where id = v_webhook_id) then
    raise exception 'FAIL cleanup: a done (non-dead) webhook_inbox row must never be hard-deleted by this sweep';
  end if;

  if exists (select 1 from private.notification_outbox where id = v_outbox_sent_id) then
    raise exception 'FAIL cleanup: a sent notification_outbox row older than 30d must be deleted';
  end if;
  if not exists (select 1 from private.notification_outbox where id = v_outbox_recent_sent_id) then
    raise exception 'FAIL cleanup: a recently-sent notification_outbox row must be kept';
  end if;

  if (v_result->>'raw_inputs')::int < 1 then
    raise exception 'FAIL cleanup: result payload must report at least one raw_inputs deletion';
  end if;
end;
$$;

reset role;

select '23_recurring_holiday_cleanup: PASS' as result;
