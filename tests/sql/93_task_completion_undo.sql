-- Q114: accidental task completion can be corrected without deleting audit history.
\set ON_ERROR_STOP on

begin;

insert into auth.users(id) values
  ('93000000-0000-0000-0000-000000000001'),
  ('93000000-0000-0000-0000-000000000002');

set role service_role;

do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_task_id uuid;
  v_result jsonb;
  v_revision bigint;
  v_op uuid;
  v_subtask_task_id uuid;
begin
  v_hh:=public.server_tx_create_household(
    '93000000-0000-0000-0000-000000000001',
    gen_random_uuid(),'Task Undo HH','Owner'
  );
  v_hh_id:=(v_hh->>'household_id')::uuid;
  insert into public.household_members(household_id,user_id,member_role)
  values(v_hh_id,'93000000-0000-0000-0000-000000000002','adult');

  v_result:=public.server_tx_create_task(
    '93000000-0000-0000-0000-000000000001',gen_random_uuid(),
    'Mistap candidate','chore',(now() at time zone 'Asia/Tokyo')::date,
    null,'93000000-0000-0000-0000-000000000001',
    'whole','anytime',null
  );
  v_task_id:=(v_result->>'task_id')::uuid;

  perform public.server_tx_complete_task(
    '93000000-0000-0000-0000-000000000001',gen_random_uuid(),
    v_task_id,'self',false
  );
  select revision into v_revision from public.task_instances where id=v_task_id;

  if not exists(
    select 1 from public.task_actual_participants
    where household_id=v_hh_id and task_instance_id=v_task_id and removed_at is null
  ) then
    raise exception 'FAIL task-undo: completion actual participant missing';
  end if;

  v_op:=gen_random_uuid();
  v_result:=public.server_tx_reopen_task(
    '93000000-0000-0000-0000-000000000001',v_op,
    v_task_id,v_revision,'pwa'
  );

  if (select status from public.task_instances where id=v_task_id)<>'todo'
     or (select completed_at from public.task_instances where id=v_task_id) is not null
     or (select actual_completed_by_id from public.task_instances where id=v_task_id) is not null then
    raise exception 'FAIL task-undo: whole task did not return to clean todo state';
  end if;

  if exists(
    select 1 from public.task_actual_participants
    where household_id=v_hh_id and task_instance_id=v_task_id and removed_at is null
  ) then
    raise exception 'FAIL task-undo: active actual participant was not retired';
  end if;

  if (select count(*) from public.task_events
      where household_id=v_hh_id and task_instance_id=v_task_id
        and event_type='completion_reverted')<>1 then
    raise exception 'FAIL task-undo: correction event missing';
  end if;

  -- response-lost retry must replay instead of mutating twice.
  perform public.server_tx_reopen_task(
    '93000000-0000-0000-0000-000000000001',v_op,
    v_task_id,v_revision,'pwa'
  );
  if (select count(*) from public.task_events
      where household_id=v_hh_id and task_instance_id=v_task_id
        and event_type='completion_reverted')<>1 then
    raise exception 'FAIL task-undo: replay duplicated correction event';
  end if;

  begin
    perform public.server_tx_reopen_task(
      '93000000-0000-0000-0000-000000000001',gen_random_uuid(),
      v_task_id,(select revision from public.task_instances where id=v_task_id),'pwa'
    );
    raise exception 'FAIL task-undo: open task should not reopen';
  exception when others then
    if sqlerrm='FAIL task-undo: open task should not reopen' then raise; end if;
    if sqlerrm<>'TASK_NOT_COMPLETED' then
      raise exception 'FAIL task-undo: expected TASK_NOT_COMPLETED, got %',sqlerrm;
    end if;
  end;

  v_result:=public.server_tx_create_task(
    '93000000-0000-0000-0000-000000000001',gen_random_uuid(),
    'Checklist','chore',(now() at time zone 'Asia/Tokyo')::date,
    null,null,'subtasks','anytime',
    jsonb_build_array(
      jsonb_build_object('title','A','required',true,'sort_order',1),
      jsonb_build_object('title','B','required',true,'sort_order',2)
    )
  );
  v_subtask_task_id:=(v_result->>'task_id')::uuid;
  perform public.server_tx_complete_task(
    '93000000-0000-0000-0000-000000000001',gen_random_uuid(),
    v_subtask_task_id,'self',true
  );

  begin
    perform public.server_tx_reopen_task(
      '93000000-0000-0000-0000-000000000001',gen_random_uuid(),
      v_subtask_task_id,
      (select revision from public.task_instances where id=v_subtask_task_id),
      'pwa'
    );
    raise exception 'FAIL task-undo: checklist must use fine-grained uncheck';
  exception when others then
    if sqlerrm='FAIL task-undo: checklist must use fine-grained uncheck' then raise; end if;
    if sqlerrm<>'TASK_REOPEN_USE_SUBTASKS' then
      raise exception 'FAIL task-undo: expected TASK_REOPEN_USE_SUBTASKS, got %',sqlerrm;
    end if;
  end;
end;
$$;

reset role;
set role authenticated;
set request.jwt.claim.sub='93000000-0000-0000-0000-000000000001';
do $$
begin
  begin
    perform public.server_tx_reopen_task(
      '93000000-0000-0000-0000-000000000001',gen_random_uuid(),
      gen_random_uuid(),1,'pwa'
    );
    raise exception 'FAIL task-undo: authenticated must not execute server_tx_reopen_task directly';
  exception when insufficient_privilege then null;
  end;
end;
$$;
reset role;
reset request.jwt.claim.sub;

rollback;
select 'task_completion_undo: PASS' as result;
