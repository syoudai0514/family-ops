-- Re-review fix (P1-1/P1-2, docs/adr/0010): the LINE-native item-by-item
-- flow (項目ごとに入力) and the mandatory confirmation step before a
-- top-level 今回は不要 mass-skip are both implemented entirely in
-- supabase/functions/process-line-inbox/{index,routineItemFlow}.ts and
-- supabase/functions/send-notifications/routineQuickReply.ts -- no RPC/table
-- changed. What DID change is how much this repo's SQL-layer tests rely on
-- two server_tx_get_routine_session fields the new Edge Function code reads
-- directly to decide "show the next item" vs. "resolve to the latest safe
-- link": `items` ordering (display_order, the deterministic-selection
-- backbone pickNextUnfinished in routineItemFlow.ts assumes) and
-- `can_act`/`current_session_id` (the exact fields routine_item_mode/
-- routine_item_next/routine_skip_prompt gate on). Neither was previously
-- asserted anywhere in tests/sql -- this file closes that gap. See
-- supabase/functions/process-line-inbox/routineItemFlow.test.ts for the
-- pure-function unit tests (selection/wraparound/message-shape) that don't
-- need a database at all.
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('26000000-0000-0000-0000-000000000001'), -- HH1 adult A (display_order/can_act scenario)
  ('26000000-0000-0000-0000-000000000002'), -- HH1 adult B
  ('26000000-0000-0000-0000-000000000003'), -- HH2 adult A (superseded/current_session_id scenario)
  ('26000000-0000-0000-0000-000000000004'); -- HH2 adult B

set role service_role;

-- ===========================================================================
-- Scenario 1: server_tx_get_routine_session's items[] are ordered by
-- task_definition.sort_order (NOT insertion order), and can_act correctly
-- distinguishes the session's own open assignee from anyone else.
-- ===========================================================================
do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_a uuid := '26000000-0000-0000-0000-000000000001';
  v_b uuid := '26000000-0000-0000-0000-000000000002';
  v_dropoff_def uuid;   -- sort_order 10
  v_uwabaki_def uuid;   -- sort_order 31
  v_english_def uuid;   -- sort_order 33
  v_dropoff_ti uuid;
  v_now timestamptz := ('2026-08-24 07:00:00'::timestamp at time zone 'Asia/Tokyo');
  v_session_id uuid;
  v_get_a jsonb;
  v_get_b jsonb;
  v_titles text[];
  v_display_orders int[];
begin
  v_hh := public.server_tx_create_household(v_a, gen_random_uuid(), 'WP-P1-1 Order HH', 'A');
  v_hh_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role) values (v_hh_id, v_b, 'adult');

  select id into v_dropoff_def from public.task_definitions where household_id = v_hh_id and code = 'dropoff';
  select id into v_uwabaki_def from public.task_definitions where household_id = v_hh_id and code = 'prep_monday_uwabaki';
  select id into v_english_def from public.task_definitions where household_id = v_hh_id and code = 'prep_thursday_english';

  -- Insertion order is deliberately the REVERSE of sort_order (english=33
  -- first, uwabaki=31 second, dropoff=10 last) so a test that only happened
  -- to pass by accident of insertion/created_at order would fail here.
  insert into public.task_instances
    (id, household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
     planned_assignee_id, completion_mode, status, source, created_by)
  values (gen_random_uuid(), v_hh_id, v_english_def, 'recurring', '英語用品を準備する', 'preparation', 'morning', '2026-08-24',
    v_a, 'whole', 'todo', 'recurring', v_a);
  insert into public.task_instances
    (id, household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
     planned_assignee_id, completion_mode, status, source, created_by)
  values (gen_random_uuid(), v_hh_id, v_uwabaki_def, 'recurring', '洗った上履きを持っていく', 'preparation', 'morning', '2026-08-24',
    v_a, 'whole', 'todo', 'recurring', v_a);
  insert into public.task_instances
    (id, household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
     planned_assignee_id, completion_mode, status, source, created_by)
  values (gen_random_uuid(), v_hh_id, v_dropoff_def, 'recurring', '送り', 'dropoff', 'morning', '2026-08-24',
    v_a, 'whole', 'todo', 'recurring', v_a)
  returning id into v_dropoff_ti;

  perform public.server_tx_dispatch_routine_automation(v_now, 2000);

  select id into v_session_id from public.routine_checkin_sessions
  where household_id = v_hh_id and session_type = 'dropoff' and scheduled_date = '2026-08-24' and assignee_id = v_a;
  if v_session_id is null then
    raise exception 'FAIL order: dropoff session was not created';
  end if;

  -- can_act: true for the session's own open assignee.
  v_get_a := public.server_tx_get_routine_session(v_a, v_session_id);
  if (v_get_a->>'can_act')::boolean is not true then
    raise exception 'FAIL can_act: the open session''s own assignee must have can_act=true, got %', v_get_a->>'can_act';
  end if;

  -- can_act: false for a household member who is NOT this session's
  -- assignee, even though the session itself is open -- routine_item_mode/
  -- routine_item_next/routine_skip_prompt all gate on this exact field to
  -- decide whether to ever show an item or mutate anything.
  v_get_b := public.server_tx_get_routine_session(v_b, v_session_id);
  if (v_get_b->>'can_act')::boolean is not false then
    raise exception 'FAIL can_act: a non-assignee household member must have can_act=false, got %', v_get_b->>'can_act';
  end if;

  -- Deterministic ordering: display_order (and therefore the order
  -- pickNextUnfinished.ts's "first unfinished item" picks from) must follow
  -- task_definition.sort_order, not insertion order.
  select array_agg(item ->> 'title' order by (item->>'display_order')::int) into v_titles
  from jsonb_array_elements(v_get_a -> 'items') as item;
  if v_titles <> array['送り', '洗った上履きを持っていく', '英語用品を準備する'] then
    raise exception 'FAIL order: expected items ordered by sort_order (送り, 上履き, 英語), got %', v_titles;
  end if;

  select array_agg((item ->> 'display_order')::int order by (item->>'display_order')::int) into v_display_orders
  from jsonb_array_elements(v_get_a -> 'items') as item;
  if v_display_orders[1] >= v_display_orders[2] or v_display_orders[2] >= v_display_orders[3] then
    raise exception 'FAIL order: display_order values must be strictly increasing in the returned order, got %', v_display_orders;
  end if;
end;
$$;

-- ===========================================================================
-- Scenario 2: a superseded session's can_act is false even for its former
-- assignee, and current_session_id correctly resolves to the live
-- replacement session -- the exact pair of fields
-- process-line-inbox's sendStaleSessionReply/buildStaleSessionText use to
-- avoid ever mutating a stale session and to point the user at the right
-- link instead.
-- ===========================================================================
do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_a uuid := '26000000-0000-0000-0000-000000000003';
  v_b uuid := '26000000-0000-0000-0000-000000000004';
  v_pickup_def uuid;
  v_pickup_ti uuid;
  v_today date := (now() at time zone 'Asia/Tokyo')::date;
  v_open_time timestamptz := ((v_today::text || ' 16:00:00')::timestamp at time zone 'Asia/Tokyo');
  v_old_session uuid;
  v_new_session uuid;
  v_get jsonb;
begin
  v_hh := public.server_tx_create_household(v_a, gen_random_uuid(), 'WP-P1-1 Stale HH', 'A');
  v_hh_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role) values (v_hh_id, v_b, 'adult');

  select id into v_pickup_def from public.task_definitions where household_id = v_hh_id and code = 'pickup';
  insert into public.task_instances
    (id, household_id, task_definition_id, origin, title, category, routine_phase, scheduled_date,
     planned_assignee_id, completion_mode, status, source, created_by)
  values (gen_random_uuid(), v_hh_id, v_pickup_def, 'recurring', '迎え', 'pickup', 'evening', v_today,
    v_a, 'whole', 'todo', 'recurring', v_a)
  returning id into v_pickup_ti;

  perform public.server_tx_dispatch_routine_automation(v_open_time, 2000);
  select id into v_old_session from public.routine_checkin_sessions
  where household_id = v_hh_id and session_type = 'pickup' and scheduled_date = v_today and assignee_id = v_a;
  if v_old_session is null then
    raise exception 'FAIL stale: pickup session for A was not created';
  end if;

  perform public.server_tx_reassign_task_once(v_a, gen_random_uuid(), v_pickup_ti, v_b);

  select id into v_new_session from public.routine_checkin_sessions
  where household_id = v_hh_id and session_type = 'pickup' and scheduled_date = v_today and assignee_id = v_b;
  if v_new_session is null then
    raise exception 'FAIL stale: B''s replacement pickup session was not created';
  end if;

  -- A's own (now superseded) session: can_act must be false even for A,
  -- its own former assignee -- routine_item_mode/routine_item_next/
  -- routine_skip_prompt must never mutate through a stale button here.
  v_get := public.server_tx_get_routine_session(v_a, v_old_session);
  if (v_get->>'status') <> 'superseded' then
    raise exception 'FAIL stale: A''s old session must be superseded, got %', v_get->>'status';
  end if;
  if (v_get->>'can_act')::boolean is not false then
    raise exception 'FAIL stale: a superseded session must have can_act=false even for its former assignee, got %', v_get->>'can_act';
  end if;
  if (v_get->>'current_session_id')::uuid <> v_new_session then
    raise exception 'FAIL stale: current_session_id on the superseded session must resolve to B''s live replacement session, got %', v_get->>'current_session_id';
  end if;
end;
$$;

reset role;

select 'line_item_by_item_and_skip_confirm: PASS' as result;
