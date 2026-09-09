-- Lane D Q87: evening Today receives a compact server-owned morning completion
-- summary from the canonical DailyBrief projection. Completed non-morning work
-- must not inflate the numerator.
\set ON_ERROR_STOP on

begin;
set local role service_role;

do $$
declare
  v_user_id uuid;
  v_remaining_id uuid;
  v_completed_morning_id uuid;
  v_completed_day_id uuid;
  v_result jsonb;
  v_summary jsonb;
  v_live_brief jsonb;
begin
  select hm.user_id
    into v_user_id
  from public.household_members hm
  join auth.users u on u.id = hm.user_id
  order by hm.joined_at nulls last
  limit 1;

  if v_user_id is null then
    raise exception 'FAIL lane-d-morning-summary: expected an existing household member fixture';
  end if;

  v_result := public.server_tx_create_task(
    v_user_id, gen_random_uuid(), 'Q87 morning remaining', 'chore',
    (now() at time zone 'Asia/Tokyo')::date, null, v_user_id,
    'whole', 'morning', null
  );
  v_remaining_id := (v_result->>'task_id')::uuid;

  v_result := public.server_tx_create_task(
    v_user_id, gen_random_uuid(), 'Q87 morning completed', 'chore',
    (now() at time zone 'Asia/Tokyo')::date, null, v_user_id,
    'whole', 'morning', null
  );
  v_completed_morning_id := (v_result->>'task_id')::uuid;
  perform public.server_tx_complete_task(v_user_id, gen_random_uuid(), v_completed_morning_id, 'self', null);

  v_result := public.server_tx_create_task(
    v_user_id, gen_random_uuid(), 'Q87 daytime completed', 'chore',
    (now() at time zone 'Asia/Tokyo')::date, null, v_user_id,
    'whole', 'daytime', null
  );
  v_completed_day_id := (v_result->>'task_id')::uuid;
  perform public.server_tx_complete_task(v_user_id, gen_random_uuid(), v_completed_day_id, 'self', null);

  v_summary := private.fn_daily_brief_morning_summary_v1(
    jsonb_build_object(
      'own_task_groups', jsonb_build_object(
        'morning', jsonb_build_array(jsonb_build_object('task_id', v_remaining_id))
      ),
      'already_handled', jsonb_build_array(
        jsonb_build_object('task_id', v_completed_morning_id),
        jsonb_build_object('task_id', v_completed_day_id)
      )
    )
  );

  if (v_summary->>'completed_count')::integer <> 1
     or (v_summary->>'total_count')::integer <> 2 then
    raise exception 'FAIL lane-d-morning-summary: expected 1/2, got %', v_summary;
  end if;

  v_live_brief := public.server_read_daily_brief(
    v_user_id,
    (now() at time zone 'Asia/Tokyo')::date
  );

  if not (v_live_brief ? 'morning_summary') then
    raise exception 'FAIL lane-d-morning-summary: canonical DailyBrief must expose morning_summary';
  end if;
  if (v_live_brief#>>'{morning_summary,completed_count}')::integer < 0
     or (v_live_brief#>>'{morning_summary,total_count}')::integer
        < (v_live_brief#>>'{morning_summary,completed_count}')::integer then
    raise exception 'FAIL lane-d-morning-summary: invalid canonical counts %', v_live_brief->'morning_summary';
  end if;
end;
$$;

rollback;
select 'lane_d_morning_completion_summary: PASS' as result;
