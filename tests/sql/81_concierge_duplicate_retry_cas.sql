-- Lane B / CF-06 + CF-07: same canonical fixture must have three explicit
-- duplicate outcomes, CAS conflict must never create, and a response-lost
-- retry must replay the same parent mutation receipt/result.
\set ON_ERROR_STOP on

insert into auth.users (id) values ('81000000-0000-0000-0000-000000000001');
set role service_role;

do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_created jsonb;
  v_task_id uuid;
  v_before_count bigint;
  v_after_count bigint;
  v_initial_revision bigint;
  v_updated jsonb;
  v_replayed jsonb;
  v_separate jsonb;
begin
  v_hh := public.server_tx_create_household(
    '81000000-0000-0000-0000-000000000001',
    '81000000-0000-4000-8000-000000000002',
    'Concierge correctness HH',
    'Owner'
  );
  v_hh_id := (v_hh->>'household_id')::uuid;

  v_created := public.server_tx_create_task_with_calendar(
    p_actor_id => '81000000-0000-0000-0000-000000000001',
    p_operation_id => '81000000-0000-4000-8000-000000000010',
    p_title => 'ゴミ出し',
    p_category => 'todo',
    p_scheduled_date => date '2026-09-09',
    p_due_local_time => null,
    p_calendar_end_local_time => null,
    p_calendar_visibility => 'hidden',
    p_planned_assignee_user_id => null,
    p_completion_mode => 'whole',
    p_routine_phase => 'anytime',
    p_subtasks => null
  );
  v_task_id := (v_created->>'task_id')::uuid;
  select revision into v_initial_revision
  from public.task_instances where household_id=v_hh_id and id=v_task_id;
  select count(*) into v_before_count
  from public.task_instances where household_id=v_hh_id and title='ゴミ出し';

  -- existing => intentionally no business RPC. The same fixture count is
  -- unchanged before the update branch starts.
  if v_before_count <> 1 then
    raise exception 'FAIL CF-06 existing: fixture row count must be 1';
  end if;

  -- update => same canonical ID, row count unchanged, revision advances.
  v_updated := public.server_tx_commit_concierge_duplicate_update(
    p_actor_id => '81000000-0000-0000-0000-000000000001',
    p_operation_id => '81000000-0000-4000-8000-000000000020',
    p_entity_kind => 'task',
    p_entity_id => v_task_id,
    p_expected_revision => v_initial_revision,
    p_title => 'ゴミ出し',
    p_scheduled_date => date '2026-09-10',
    p_due_local_time => null,
    p_planned_assignee_user_id => null
  );
  if (v_updated->>'entity_id')::uuid <> v_task_id
     or v_updated->>'receipt' <> 'committed' then
    raise exception 'FAIL CF-06 update: canonical same-ID result missing';
  end if;
  select count(*) into v_after_count
  from public.task_instances where household_id=v_hh_id and title='ゴミ出し';
  if v_after_count <> v_before_count then
    raise exception 'FAIL CF-06 update: row count changed % -> %', v_before_count, v_after_count;
  end if;
  if not exists (
    select 1 from public.task_instances
    where household_id=v_hh_id and id=v_task_id
      and scheduled_date=date '2026-09-10'
      and revision > v_initial_revision
  ) then
    raise exception 'FAIL CF-06 update: same row/date/revision was not changed';
  end if;

  -- CF-07: simulate response loss by discarding v_updated, then retry the
  -- exact logical operation. Parent receipt must replay before stale CAS check.
  v_replayed := public.server_tx_commit_concierge_duplicate_update(
    p_actor_id => '81000000-0000-0000-0000-000000000001',
    p_operation_id => '81000000-0000-4000-8000-000000000020',
    p_entity_kind => 'task',
    p_entity_id => v_task_id,
    p_expected_revision => v_initial_revision,
    p_title => 'ゴミ出し',
    p_scheduled_date => date '2026-09-10',
    p_due_local_time => null,
    p_planned_assignee_user_id => null
  );
  if (v_replayed->>'entity_id')::uuid <> v_task_id
     or v_replayed->>'receipt' <> 'replay' then
    raise exception 'FAIL CF-07 retry: original canonical result was not replayed';
  end if;
  if (select count(*) from private.mutation_receipts
      where actor_id='81000000-0000-0000-0000-000000000001'
        and operation_id='81000000-0000-4000-8000-000000000020') <> 1 then
    raise exception 'FAIL CF-07 retry: parent mutation receipt must be exactly one';
  end if;
  if (select count(*) from public.task_instances where household_id=v_hh_id and title='ゴミ出し') <> 1 then
    raise exception 'FAIL CF-07 retry: replay created duplicate business row';
  end if;

  -- Concurrent modification / stale review must conflict and never create.
  begin
    perform public.server_tx_commit_concierge_duplicate_update(
      p_actor_id => '81000000-0000-0000-0000-000000000001',
      p_operation_id => '81000000-0000-4000-8000-000000000021',
      p_entity_kind => 'task',
      p_entity_id => v_task_id,
      p_expected_revision => v_initial_revision,
      p_title => 'ゴミ出し',
      p_scheduled_date => date '2026-09-11',
      p_due_local_time => null,
      p_planned_assignee_user_id => null
    );
    raise exception 'FAIL CF-06 stale: conflict was not raised';
  exception when others then
    if sqlerrm <> 'AGGREGATE_REVISION_CONFLICT' then
      raise exception 'FAIL CF-06 stale: expected AGGREGATE_REVISION_CONFLICT, got %', sqlerrm;
    end if;
  end;
  if (select count(*) from public.task_instances where household_id=v_hh_id and title='ゴミ出し') <> 1 then
    raise exception 'FAIL CF-06 stale: conflict created a second row';
  end if;

  -- separate => explicit standard create path creates exactly one additional row.
  v_separate := public.server_tx_create_task_with_calendar(
    p_actor_id => '81000000-0000-0000-0000-000000000001',
    p_operation_id => '81000000-0000-4000-8000-000000000030',
    p_title => 'ゴミ出し',
    p_category => 'todo',
    p_scheduled_date => date '2026-09-10',
    p_due_local_time => null,
    p_calendar_end_local_time => null,
    p_calendar_visibility => 'hidden',
    p_planned_assignee_user_id => null,
    p_completion_mode => 'whole',
    p_routine_phase => 'anytime',
    p_subtasks => null
  );
  if (v_separate->>'task_id')::uuid = v_task_id then
    raise exception 'FAIL CF-06 separate: must create a distinct ID';
  end if;
  if (select count(*) from public.task_instances where household_id=v_hh_id and title='ゴミ出し') <> 2 then
    raise exception 'FAIL CF-06 separate: row count must increase by exactly one';
  end if;
end;
$$;

reset role;
set role authenticated;
set request.jwt.claim.sub = '81000000-0000-0000-0000-000000000001';
do $$
begin
  begin
    perform public.server_tx_commit_concierge_duplicate_update(
      '81000000-0000-0000-0000-000000000001', gen_random_uuid(), 'task',
      gen_random_uuid(), 1, 'x', current_date, null, null
    );
    raise exception 'FAIL CF-06 grants: authenticated role must not call RPC directly';
  exception when insufficient_privilege then null;
  end;
end;
$$;
reset role;
reset request.jwt.claim.sub;

select 'concierge_duplicate_retry_cas: PASS' as result;
