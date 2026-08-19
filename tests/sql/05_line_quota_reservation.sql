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
  v_r jsonb;
begin
  v_hh := public.server_tx_create_household('c0000000-0000-0000-0000-000000000001', gen_random_uuid(), 'Quota HH', 'Owner');
  v_hh_id := (v_hh->>'household_id')::uuid;

  -- LQA03: provider_limit=5000 must not raise the effective hard limit above 200
  insert into private.line_quota_state (billing_month, provider_limit, provider_consumed)
  values (date_trunc('month', now())::date, 5000, 0)
  on conflict (billing_month) do update set provider_limit = excluded.provider_limit, provider_consumed = excluded.provider_consumed;

  insert into private.notification_outbox (id, household_id, recipient_user_id, channel, type, payload, dedup_key)
  values (gen_random_uuid(), v_hh_id, 'c0000000-0000-0000-0000-000000000001', 'line', 'test', '{}'::jsonb, 'dedup-1')
  returning id into v_out1;

  v_r := public.server_tx_reserve_line_quota(v_out1, 'normal');
  if (v_r->>'effective_hard_limit')::int <> 200 then
    raise exception 'FAIL quota: effective_hard_limit must stay 200 even when provider_limit=5000, got %', v_r->>'effective_hard_limit';
  end if;
  if not (v_r->>'permitted')::boolean then
    raise exception 'FAIL quota: first normal reservation at usage=0 should be permitted';
  end if;

  -- LQA04: effective_usage formula = max(provider_consumed, local_counted_success) + active_reserved
  update private.line_quota_state
  set provider_consumed = 195, local_counted_success = 180
  where billing_month = date_trunc('month', now())::date;

  insert into private.notification_outbox (id, household_id, recipient_user_id, channel, type, payload, dedup_key)
  values (gen_random_uuid(), v_hh_id, 'c0000000-0000-0000-0000-000000000001', 'line', 'test', '{}'::jsonb, 'dedup-2')
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

  -- critical can still get a permit up to the hard cap (200)
  v_r := public.server_tx_reserve_line_quota(v_out2, 'critical');
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

reset role;

select 'line_quota_reservation: PASS' as result;
