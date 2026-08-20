-- LINE quota atomic reservation: soft budget 180, reserve 20, app hard cap
-- 200 independent of provider plan. docs/design/v6/03_DOMAIN_AND_DATA_MODEL.md #16;
-- fixtures/LINE_QUOTA_ATOMIC_CASES.json (sequential logic; see
-- scripts/run_concurrency_tests.sh for the true-parallel LQA01/LQA02 races)
\set ON_ERROR_STOP on

insert into auth.users (id) values ('c0000000-0000-0000-0000-000000000001');

set role service_role;

do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_out1 uuid;
  v_out2 uuid;
  v_out3 uuid;
  v_r jsonb;
begin
  v_hh := public.server_tx_create_household('c0000000-0000-0000-0000-000000000001', gen_random_uuid(), 'Quota HH', 'Owner');
  v_hh_id := (v_hh->>'household_id')::uuid;

  -- LQA03: provider_limit=5000 must not raise the effective hard limit above 200
  insert into private.line_quota_state (billing_month, provider_limit, provider_consumed)
  values (date_trunc('month', now())::date, 5000, 0)
  on conflict (billing_month) do update set provider_limit = excluded.provider_limit, provider_consumed = excluded.provider_consumed;

  insert into private.notification_outbox (id, household_id, recipient_user_id, channel, type, payload, dedup_key, priority)
  values (gen_random_uuid(), v_hh_id, 'c0000000-0000-0000-0000-000000000001', 'line', 'test', '{}'::jsonb, 'dedup-1', 'normal')
  returning id into v_out1;

  v_r := public.server_tx_reserve_line_quota(v_out1, 'normal');
  if (v_r->>'effective_hard_limit')::int <> 200 then
    raise exception 'FAIL quota: effective_hard_limit must stay 200 even when provider_limit=5000, got %', v_r->>'effective_hard_limit';
  end if;
  if not (v_r->>'permitted')::boolean then
    raise exception 'FAIL quota: first normal reservation at usage=0 should be permitted';
  end if;

  -- v6 review fix (P2): reserve now validates p_priority against the
  -- outbox row's own stored priority — a mismatch must be rejected rather
  -- than trusted from the caller.
  begin
    perform public.server_tx_reserve_line_quota(v_out1, 'critical');
    raise exception 'FAIL quota: reserve must reject a priority that does not match notification_outbox.priority';
  exception
    when others then
      if sqlerrm <> 'INVALID_INPUT' then
        raise exception 'FAIL quota: expected INVALID_INPUT for a priority mismatch, got %', sqlerrm;
      end if;
  end;

  -- LQA04: effective_usage formula = max(provider_consumed, local_counted_success) + active_reserved
  update private.line_quota_state
  set provider_consumed = 195, local_counted_success = 180
  where billing_month = date_trunc('month', now())::date;

  insert into private.notification_outbox (id, household_id, recipient_user_id, channel, type, payload, dedup_key, priority)
  values (gen_random_uuid(), v_hh_id, 'c0000000-0000-0000-0000-000000000001', 'line', 'test', '{}'::jsonb, 'dedup-2', 'normal')
  returning id into v_out2;

  -- one active reservation already exists (v_out1's, still 'reserved');
  -- expected_effective_usage = max(195,180) + 1(existing reservation) = 196
  v_r := public.server_tx_reserve_line_quota(v_out2, 'normal');
  if (v_r->>'effective_usage_before')::int <> 196 then
    raise exception 'FAIL quota: expected effective_usage_before=196 (max(195,180)+1 active reservation), got %', v_r->>'effective_usage_before';
  end if;
  -- 196 + 1 = 197 <= 180(threshold)? no -> must be denied for normal priority
  if (v_r->>'permitted')::boolean then
    raise exception 'FAIL quota: normal reservation must be denied once usage would exceed the 180 soft budget';
  end if;

  -- critical can still get a permit up to the hard cap (200) — a distinct
  -- notification_outbox row, since priority is fixed per row (P2 fix), not
  -- something a retry can escalate on the same row.
  insert into private.notification_outbox (id, household_id, recipient_user_id, channel, type, payload, dedup_key, priority)
  values (gen_random_uuid(), v_hh_id, 'c0000000-0000-0000-0000-000000000001', 'line', 'test', '{}'::jsonb, 'dedup-3', 'critical')
  returning id into v_out3;

  v_r := public.server_tx_reserve_line_quota(v_out3, 'critical');
  if not (v_r->>'permitted')::boolean then
    raise exception 'FAIL quota: critical reservation must be permitted while usage(196)+1=197 <= 200';
  end if;
end;
$$;

-- ambiguous outcome (LQA06): stays counted against budget, not released
do $$
declare
  v_reservation_id uuid;
  v_billing_month date := date_trunc('month', now())::date;
begin
  select id into v_reservation_id
  from private.line_quota_reservations
  where billing_month = v_billing_month and status = 'reserved'
  order by reserved_at desc
  limit 1;

  perform public.server_tx_mark_line_quota_ambiguous(v_reservation_id);

  if (select status from private.line_quota_reservations where id = v_reservation_id) <> 'ambiguous' then
    raise exception 'FAIL quota: mark_ambiguous did not set status=ambiguous';
  end if;

  if (
    select count(*) from private.line_quota_reservations
    where billing_month = v_billing_month and status in ('reserved', 'ambiguous')
  ) < 1 then
    raise exception 'FAIL quota: ambiguous reservation must still count as active (LQA06)';
  end if;
end;
$$;

-- commit reduces future headroom via local_counted_success, release frees it
do $$
declare
  v_reservation_id uuid;
  v_billing_month date := date_trunc('month', now())::date;
  v_before int;
  v_after int;
begin
  select local_counted_success into v_before from private.line_quota_state where billing_month = v_billing_month;

  select id into v_reservation_id
  from private.line_quota_reservations
  where billing_month = v_billing_month and status = 'reserved'
  limit 1;

  perform public.server_tx_commit_line_quota_reservation(v_reservation_id);

  select local_counted_success into v_after from private.line_quota_state where billing_month = v_billing_month;
  if v_after <> v_before + 1 then
    raise exception 'FAIL quota: commit must increment local_counted_success by 1';
  end if;

  if (select status from private.line_quota_reservations where id = v_reservation_id) <> 'committed' then
    raise exception 'FAIL quota: commit must set status=committed';
  end if;
end;
$$;

-- v6 review fix (P2): commit/release/reserve/mark_ambiguous idempotency and
-- correct state transitions.
do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_out uuid;
  v_r1 jsonb;
  v_r2 jsonb;
  v_reservation_id uuid;
  v_before int;
  v_after int;
begin
  insert into auth.users (id) values ('c0000000-0000-0000-0000-000000000002');
  v_hh := public.server_tx_create_household('c0000000-0000-0000-0000-000000000002', gen_random_uuid(), 'Quota Idempotency HH', 'Owner');
  v_hh_id := (v_hh->>'household_id')::uuid;

  -- earlier do-blocks in this file already pushed the real "current month"
  -- quota state close to its cap; reset it so this sub-test's reserve calls
  -- are predictably permitted.
  update private.notification_outbox
  set quota_reservation_id = null
  where quota_reservation_id in (
    select id from private.line_quota_reservations where billing_month = date_trunc('month', now())::date
  );
  delete from private.line_quota_reservations where billing_month = date_trunc('month', now())::date;
  update private.line_quota_state
  set provider_consumed = 0, local_counted_success = 0
  where billing_month = date_trunc('month', now())::date;

  insert into private.notification_outbox (id, household_id, recipient_user_id, channel, type, payload, dedup_key)
  values (gen_random_uuid(), v_hh_id, 'c0000000-0000-0000-0000-000000000002', 'line', 'test', '{}'::jsonb, 'idem-1')
  returning id into v_out;

  -- reserve is idempotent per notification_outbox_id: retrying the same
  -- outbox row must return the same reservation, not error or re-decide.
  v_r1 := public.server_tx_reserve_line_quota(v_out, 'normal');
  v_r2 := public.server_tx_reserve_line_quota(v_out, 'normal');
  if (v_r1->>'reservation_id') <> (v_r2->>'reservation_id') then
    raise exception 'FAIL quota-idempotency: retried reserve for the same outbox row must return the same reservation_id';
  end if;
  if not (v_r2->>'replay')::boolean then
    raise exception 'FAIL quota-idempotency: retried reserve must report replay=true';
  end if;

  v_reservation_id := (v_r1->>'reservation_id')::uuid;

  select local_counted_success into v_before
  from private.line_quota_state where billing_month = date_trunc('month', now())::date;

  -- double-commit must not double-increment local_counted_success
  perform public.server_tx_commit_line_quota_reservation(v_reservation_id);
  perform public.server_tx_commit_line_quota_reservation(v_reservation_id);

  select local_counted_success into v_after
  from private.line_quota_state where billing_month = date_trunc('month', now())::date;
  if v_after <> v_before + 1 then
    raise exception 'FAIL quota-idempotency: double-commit must only increment local_counted_success once (before=%, after=%)', v_before, v_after;
  end if;

  -- releasing a committed reservation is an invalid transition, not silently accepted
  begin
    perform public.server_tx_release_line_quota_reservation(v_reservation_id);
    raise exception 'FAIL quota-idempotency: releasing an already-committed reservation must be rejected';
  exception
    when others then
      if sqlerrm <> 'INVALID_STATE_TRANSITION' then
        raise exception 'FAIL quota-idempotency: expected INVALID_STATE_TRANSITION, got %', sqlerrm;
      end if;
  end;

  -- double-release is idempotent (no error), unlike an invalid transition
  declare
    v_out2 uuid;
    v_reservation2 uuid;
  begin
    insert into private.notification_outbox (id, household_id, recipient_user_id, channel, type, payload, dedup_key)
    values (gen_random_uuid(), v_hh_id, 'c0000000-0000-0000-0000-000000000002', 'line', 'test', '{}'::jsonb, 'idem-2')
    returning id into v_out2;

    v_r1 := public.server_tx_reserve_line_quota(v_out2, 'normal');
    v_reservation2 := (v_r1->>'reservation_id')::uuid;

    perform public.server_tx_release_line_quota_reservation(v_reservation2);
    perform public.server_tx_release_line_quota_reservation(v_reservation2); -- must not raise

    if (select status from private.line_quota_reservations where id = v_reservation2) <> 'released' then
      raise exception 'FAIL quota-idempotency: reservation must remain released after double-release';
    end if;
  end;
end;
$$;

-- v6 re-review fix (P2): threshold formula with a non-default soft_budget,
-- proving reminder=min(soft_budget,hard_limit-reserve) actually differs
-- from normal=hard_limit-reserve when the two aren't numerically coincident.
-- Runs last in this file and clears the shared real-world billing_month's
-- reservations first, since every earlier block in this file shares that
-- same month key.
do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_month date := date_trunc('month', now())::date;
  v_out_reminder uuid;
  v_out_normal uuid;
  v_r jsonb;
begin
  insert into auth.users (id) values ('c0000000-0000-0000-0000-000000000003');
  v_hh := public.server_tx_create_household('c0000000-0000-0000-0000-000000000003', gen_random_uuid(), 'Nondefault Budget HH', 'Owner');
  v_hh_id := (v_hh->>'household_id')::uuid;

  update private.notification_outbox
  set quota_reservation_id = null
  where quota_reservation_id in (select id from private.line_quota_reservations where billing_month = v_month);
  delete from private.line_quota_reservations where billing_month = v_month;

  -- soft_budget=170, reserve=20, app_hard_cap=200 -> hard_limit-reserve=180
  -- reminder threshold = min(170,180) = 170; normal threshold = 180
  insert into private.line_quota_state (billing_month, provider_limit, provider_consumed, local_counted_success, soft_budget, reserve)
  values (v_month, 200, 175, 0, 170, 20)
  on conflict (billing_month) do update set
    provider_limit = excluded.provider_limit, provider_consumed = excluded.provider_consumed,
    local_counted_success = excluded.local_counted_success, soft_budget = excluded.soft_budget, reserve = excluded.reserve;

  -- effective_usage=175; reminder: 175+1=176 > 170 -> denied
  insert into private.notification_outbox (id, household_id, recipient_user_id, channel, type, payload, dedup_key, priority)
  values (gen_random_uuid(), v_hh_id, 'c0000000-0000-0000-0000-000000000003', 'line', 'test', '{}'::jsonb, 'nondefault-reminder', 'reminder')
  returning id into v_out_reminder;
  v_r := public.server_tx_reserve_line_quota(v_out_reminder, 'reminder');
  if (v_r->>'threshold')::int <> 170 then
    raise exception 'FAIL quota: non-default soft_budget=170 must yield reminder threshold=170, got %', v_r->>'threshold';
  end if;
  if (v_r->>'permitted')::boolean then
    raise exception 'FAIL quota: reminder at usage=175 must be denied against threshold=170 (175+1=176>170)';
  end if;

  -- effective_usage still 175 (denied reminder created no reservation);
  -- normal: 175+1=176 <= 180 -> permitted
  insert into private.notification_outbox (id, household_id, recipient_user_id, channel, type, payload, dedup_key, priority)
  values (gen_random_uuid(), v_hh_id, 'c0000000-0000-0000-0000-000000000003', 'line', 'test', '{}'::jsonb, 'nondefault-normal', 'normal')
  returning id into v_out_normal;
  v_r := public.server_tx_reserve_line_quota(v_out_normal, 'normal');
  if (v_r->>'threshold')::int <> 180 then
    raise exception 'FAIL quota: non-default reserve=20/hard_cap=200 must yield normal threshold=180, got %', v_r->>'threshold';
  end if;
  if not (v_r->>'permitted')::boolean then
    raise exception 'FAIL quota: normal at usage=175 must be permitted against threshold=180 (175+1=176<=180)';
  end if;
end;
$$;

reset role;

select 'line_quota_reservation: PASS' as result;
