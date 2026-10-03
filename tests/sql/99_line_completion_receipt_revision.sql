-- A LINE confirmation may arrive after a partner has corrected and redone
-- the work. Its undo must remain tied to the first completion's receipt.
\set ON_ERROR_STOP on

begin;
set role service_role;

do $$
declare
  u1 uuid := gen_random_uuid();
  u2 uuid := gen_random_uuid();
  hh uuid;
  task_id uuid;
  checklist_id uuid;
  op uuid := gen_random_uuid();
  completed jsonb;
  replay jsonb;
  later jsonb;
  completed_revision bigint;
begin
  insert into auth.users(id) values (u1), (u2);
  hh := (public.server_tx_create_household(u1, gen_random_uuid(), 'LINE receipt revision', 'Owner')->>'household_id')::uuid;
  insert into public.household_members(household_id,user_id,member_role)
    values (hh,u2,'adult');

  task_id := (public.server_tx_create_task(
    u1,gen_random_uuid(),'LINE completion','chore',
    (now() at time zone 'Asia/Tokyo')::date,null,u1,
    'whole','anytime',null
  )->>'task_id')::uuid;

  completed := public.server_tx_complete_task(u1,op,task_id,'self',false,'line');
  completed_revision := (completed->>'revision')::bigint;
  if completed_revision is null or completed_revision is distinct from
      (select revision from public.task_instances where id=task_id) then
    raise exception 'FAIL LINE receipt: completion must return the revision it produced: %', completed;
  end if;

  perform public.server_tx_reopen_task(u2,gen_random_uuid(),task_id,completed_revision,'pwa');
  later := public.server_tx_complete_task(u2,gen_random_uuid(),task_id,'self',false,'pwa');
  if (later->>'revision')::bigint <= completed_revision then
    raise exception 'FAIL LINE receipt: partner recompletion did not advance revision';
  end if;

  -- A response-lost retry returns the exact original receipt, even though
  -- the row is now completed again by the other parent.
  replay := public.server_tx_complete_task(u1,op,task_id,'self',false,'line');
  if replay is distinct from completed then
    raise exception 'FAIL LINE receipt: replay borrowed a later completion revision';
  end if;

  begin
    perform public.server_tx_reopen_task(u1,gen_random_uuid(),task_id,
      (replay->>'revision')::bigint,'line');
    raise exception 'FAIL LINE receipt: stale undo erased the partner recompletion';
  exception when others then
    if sqlerrm <> 'AGGREGATE_REVISION_CONFLICT' then raise; end if;
  end;
  if (select actual_completed_by_id from public.task_instances where id=task_id) is distinct from u2 then
    raise exception 'FAIL LINE receipt: partner completion was changed';
  end if;

  -- The historical five-argument adapter and the checklist branch return
  -- the same revision contract without changing their completion behavior.
  checklist_id := (public.server_tx_create_task(
    u1,gen_random_uuid(),'LINE checklist','chore',
    (now() at time zone 'Asia/Tokyo')::date,null,u1,
    'subtasks','anytime',jsonb_build_array(
      jsonb_build_object('title','A','required',true,'sort_order',1)
    )
  )->>'task_id')::uuid;
  completed := public.server_tx_complete_task(u1,gen_random_uuid(),checklist_id,'self',true);
  if (completed->>'revision')::bigint is distinct from
      (select revision from public.task_instances where id=checklist_id) then
    raise exception 'FAIL LINE receipt: checklist adapter omitted its completed revision';
  end if;

  if has_function_privilege('authenticated',
       'public.server_tx_complete_task(uuid,uuid,uuid,text,boolean,text)','execute')
     or has_function_privilege('anon',
       'public.server_tx_complete_task(uuid,uuid,uuid,text,boolean,text)','execute') then
    raise exception 'FAIL LINE receipt: completion must remain service-only';
  end if;
end;
$$;

reset role;
rollback;
select 'line_completion_receipt_revision: PASS' as result;
