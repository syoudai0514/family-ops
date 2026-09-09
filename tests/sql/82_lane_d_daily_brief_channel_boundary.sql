\set ON_ERROR_STOP on
begin;
set role service_role;

do $$
declare
  u uuid := gen_random_uuid();
  hh uuid;
  v_today date := (now() at time zone 'Asia/Tokyo')::date;
  v_line text;
  v_canonical text;
  v_schedule jsonb;
begin
  insert into auth.users(id) values(u);
  hh := (public.server_tx_create_household(
    u,
    gen_random_uuid(),
    'Lane D DailyBrief boundary',
    'Owner'
  )->>'household_id')::uuid;

  -- DailyBrief enrichment reads canonical actor refs when present. Keep this
  -- fixture on the same canonical identity foundation as real households.
  perform private.backfill_canonical_foundation_v1();

  -- CF-02/03/04: LINE `今日` is a presentation-only adapter over the exact
  -- same canonical DailyBrief renderer used by Today semantics. It must never
  -- reconstruct its own schedule/task truth.
  v_line := public.server_read_line_today_daily_brief(u);
  v_canonical := public.server_render_daily_brief_text(u, v_today);

  if v_line is distinct from v_canonical then
    raise exception 'FAIL lane-d-line-daily-brief: LINE reader diverged from canonical renderer';
  end if;

  if v_line is null or v_line !~ '^(朝|今日|夜)のおうちノート' then
    raise exception 'FAIL lane-d-line-daily-brief: daypart renderer header missing: %', v_line;
  end if;

  -- Compatibility guard: the historical detailed Today schedule RPC remains
  -- its established schedule contract. Lane D must not repurpose it merely to
  -- carry LINE presentation text.
  v_schedule := public.server_tx_get_today_schedule(u);
  if not (v_schedule ? 'occurrences')
     or not (v_schedule ? 'assignments')
     or not (v_schedule ? 'calendar_connected')
     or v_schedule ? 'daily_brief_text' then
    raise exception 'FAIL lane-d-schedule-compat: historical schedule RPC contract changed: %', v_schedule;
  end if;

  -- The LINE DailyBrief reader is a worker/service boundary, not a direct
  -- authenticated-client RPC.
  if has_function_privilege('authenticated', 'public.server_read_line_today_daily_brief(uuid)', 'EXECUTE') then
    raise exception 'FAIL lane-d-line-daily-brief: authenticated role can execute worker reader';
  end if;
  if not has_function_privilege('service_role', 'public.server_read_line_today_daily_brief(uuid)', 'EXECUTE') then
    raise exception 'FAIL lane-d-line-daily-brief: service role lost execute privilege';
  end if;
end;
$$;

rollback;
select 'lane_d_daily_brief_channel_boundary: PASS' as result;
