\set ON_ERROR_STOP on
begin;
set local role service_role;
do $$
declare
  a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid(); h uuid; other_h uuid; token text;
  t uuid; first_item uuid; second_item uuid; third_item uuid; optional_item uuid; participant uuid; ar uuid; req uuid;
  optional_task uuid; legacy_task uuid; whole_task uuid; op uuid:=gen_random_uuid(); undo_op uuid:=gen_random_uuid();
  done jsonb; reopened jsonb; replay jsonb; later jsonb; rev bigint; first_time timestamptz; request_time timestamptz;
begin
  insert into auth.users(id) values(a),(b),(outsider);
  h:=(public.server_tx_create_household(a,gen_random_uuid(),'Checklist undo','A')->>'household_id')::uuid;
  token:=public.server_tx_create_household_invite(a,gen_random_uuid())->>'raw_token';
  perform public.server_tx_join_household(b,gen_random_uuid(),token,'B');
  other_h:=(public.server_tx_create_household(outsider,gen_random_uuid(),'Other','Other')->>'household_id')::uuid;
  select id into ar from public.domain_actor_refs where household_id=h and real_user_id=a;
  t:=(public.server_tx_create_task(a,gen_random_uuid(),'準備','preparation',current_date,null,a,'subtasks','morning',jsonb_build_array(
    jsonb_build_object('title','先に済んだ','required',true,'sort_order',1),
    jsonb_build_object('title','今回1','required',true,'sort_order',2),
    jsonb_build_object('title','今回2','required',true,'sort_order',3),
    jsonb_build_object('title','任意','required',false,'sort_order',4)))->>'task_id')::uuid;
  select id into first_item from public.task_subtask_instances where task_instance_id=t and sort_order=1;
  select id into second_item from public.task_subtask_instances where task_instance_id=t and sort_order=2;
  select id into third_item from public.task_subtask_instances where task_instance_id=t and sort_order=3;
  select id into optional_item from public.task_subtask_instances where task_instance_id=t and sort_order=4;
  perform public.server_tx_set_subtask_completion(b,gen_random_uuid(),first_item,true,'self',null::bigint);
  perform public.server_tx_set_subtask_completion(a,gen_random_uuid(),optional_item,true,'self',null::bigint);
  update public.task_subtask_instances set completed_at=completed_at-interval '1 hour' where id=first_item;
  select completed_at into first_time from public.task_subtask_instances where id=first_item;
  update public.task_instances set status='in_progress',attention_state='waiting',waiting_note='確認待ち',next_check_at=now()+interval '1 hour' where id=t;
  insert into public.task_actual_participants(household_id,task_instance_id,actor_ref_id,recorded_by_actor_ref_id,compatibility_primary)
    values(h,t,ar,ar,false) returning id into participant;
  insert into public.requests(household_id,requester_id,recipient_id,shared_title,status,accepted_at,linked_task_instance_id)
    values(h,b,a,'準備','accepted',now(),t) returning id into req;
  done:=public.server_tx_complete_task_with_checklist_undo_v1(a,op,t,'self',true,'pwa');
  rev:=(done->>'revision')::bigint;
  if done->>'checklist_undo_available'<>'true' then raise exception 'safe undo capability missing'; end if;
  replay:=public.server_tx_complete_task_with_checklist_undo_v1(a,op,t,'self',true,'pwa');
  if replay is distinct from done or (select count(*) from private.checklist_completion_snapshots where task_id=t)<>1 then
    raise exception 'completion replay changed result or duplicated snapshot'; end if;
  if (select status from public.requests where id=req)<>'completed' then raise exception 'linked request not completed'; end if;
  begin
    perform public.server_tx_complete_task_with_checklist_undo_v1(a,op,t,'partner',true,'pwa');
    raise exception 'operation id reused with different performer';
  exception when others then if sqlerrm<>'IDEMPOTENCY_CONFLICT' then raise; end if; end;
  begin
    perform public.server_tx_reopen_task_with_checklist_undo_v1(outsider,gen_random_uuid(),t,rev,'pwa');
    raise exception 'outsider could undo';
  exception when others then if sqlerrm<>'CROSS_HOUSEHOLD_RESOURCE' then raise; end if; end;
  reopened:=public.server_tx_reopen_task_with_checklist_undo_v1(a,undo_op,t,rev,'pwa');
  if (select status from public.task_instances where id=t)<>'in_progress'
    or (select attention_state from public.task_instances where id=t)<>'waiting'
    or (select waiting_note from public.task_instances where id=t)<>'確認待ち'
    or (select next_check_at from public.task_instances where id=t) is distinct from now()+interval '1 hour'
    or not (select is_completed from public.task_subtask_instances where id=first_item)
    or (select completed_by from public.task_subtask_instances where id=first_item) is distinct from b
    or (select completed_at from public.task_subtask_instances where id=first_item) is distinct from first_time
    or (select is_completed from public.task_subtask_instances where id=second_item)
    or (select is_completed from public.task_subtask_instances where id=third_item)
    or not (select is_completed from public.task_subtask_instances where id=optional_item)
    or not exists(select 1 from public.task_actual_participants where id=participant and removed_at is null and not compatibility_primary)
    or (select status from public.requests where id=req)<>'accepted' then
    raise exception 'undo did not preserve previous state'; end if;
  if public.server_tx_reopen_task_with_checklist_undo_v1(a,undo_op,t,rev,'pwa') is distinct from reopened then
    raise exception 'undo replay did not return receipt'; end if;
  done:=public.server_tx_complete_task_with_checklist_undo_v1(a,gen_random_uuid(),t,'self',true,'pwa');
  rev:=(done->>'revision')::bigint;
  later:=public.server_tx_set_subtask_completion(b,gen_random_uuid(),optional_item,false,'self',rev);
  begin
    perform public.server_tx_reopen_task_with_checklist_undo_v1(a,gen_random_uuid(),t,rev,'pwa');
    raise exception 'stale undo succeeded';
  exception when others then if sqlerrm<>'AGGREGATE_REVISION_CONFLICT' then raise; end if; end;
  if not (select is_completed from public.task_subtask_instances where id=second_item) then raise exception 'stale undo changed work'; end if;

  -- A separately changed request must not be overwritten even if the task
  -- revision is still the completion revision.
  t:=(public.server_tx_create_task(a,gen_random_uuid(),'依頼','chore',current_date,null,a,'subtasks','anytime',
    jsonb_build_array(jsonb_build_object('title','必須','required',true,'sort_order',1)))->>'task_id')::uuid;
  insert into public.requests(household_id,requester_id,recipient_id,shared_title,status,accepted_at,linked_task_instance_id)
    values(h,b,a,'依頼','accepted',now(),t) returning id into req;
  done:=public.server_tx_complete_task_with_checklist_undo_v1(a,gen_random_uuid(),t,'self',true,'line');
  rev:=(done->>'revision')::bigint;
  update public.requests set status='accepted',completed_at=null where id=req;
  begin
    perform public.server_tx_reopen_task_with_checklist_undo_v1(a,gen_random_uuid(),t,rev,'line');
    raise exception 'undo overwrote changed request';
  exception when others then if sqlerrm<>'AGGREGATE_REVISION_CONFLICT' then raise; end if; end;
  if (select status from public.task_instances where id=t)<>'completed' then raise exception 'request conflict partly undid task'; end if;

  t:=(public.server_tx_create_task(a,gen_random_uuid(),'LINE作業','chore',current_date,null,a,'subtasks','anytime',
    jsonb_build_array(jsonb_build_object('title','必須','required',true,'sort_order',1)))->>'task_id')::uuid;
  done:=public.server_tx_complete_task_with_checklist_undo_v1(a,gen_random_uuid(),t,'self',true,'line');
  reopened:=public.server_tx_reopen_task_with_checklist_undo_v1(a,gen_random_uuid(),t,(done->>'revision')::bigint,'line');
  if exists(select 1 from public.task_events where task_instance_id=t and event_type='subtask_completion_reverted' and source<>'line') then
    raise exception 'LINE undo was recorded with wrong source'; end if;

  optional_task:=(public.server_tx_create_task(a,gen_random_uuid(),'任意だけ','chore',current_date,null,a,'subtasks','anytime',
    jsonb_build_array(jsonb_build_object('title','任意','required',false,'sort_order',1)))->>'task_id')::uuid;
  done:=public.server_tx_complete_task_with_checklist_undo_v1(a,gen_random_uuid(),optional_task,'self',true,'pwa');
  reopened:=public.server_tx_reopen_task_with_checklist_undo_v1(a,gen_random_uuid(),optional_task,(done->>'revision')::bigint,'pwa');
  if (select status from public.task_instances where id=optional_task)<>'todo' then raise exception 'optional-only task not restored'; end if;
  legacy_task:=(public.server_tx_create_task(a,gen_random_uuid(),'古い記録','chore',current_date,null,a,'subtasks','anytime',
    jsonb_build_array(jsonb_build_object('title','必須','required',true,'sort_order',1)))->>'task_id')::uuid;
  done:=public.server_tx_complete_task(a,gen_random_uuid(),legacy_task,'self',true,'pwa');
  begin
    perform public.server_tx_reopen_task_with_checklist_undo_v1(a,gen_random_uuid(),legacy_task,(done->>'revision')::bigint,'pwa');
    raise exception 'old snapshot-less completion reopened';
  exception when others then if sqlerrm<>'TASK_REOPEN_USE_SUBTASKS' then raise; end if; end;
  whole_task:=(public.server_tx_create_task(a,gen_random_uuid(),'単独','chore',current_date,null,a,'whole','anytime','[]'::jsonb)->>'task_id')::uuid;
  done:=public.server_tx_complete_task_with_checklist_undo_v1(a,gen_random_uuid(),whole_task,'self',false,'pwa');
  reopened:=public.server_tx_reopen_task_with_checklist_undo_v1(a,gen_random_uuid(),whole_task,(done->>'revision')::bigint,'pwa');
  if (select status from public.task_instances where id=whole_task)<>'todo' then raise exception 'whole task regression'; end if;
  if has_function_privilege('authenticated','public.server_tx_complete_task_with_checklist_undo_v1(uuid,uuid,uuid,text,boolean,text)','execute')
    or has_function_privilege('authenticated','public.server_tx_reopen_task_with_checklist_undo_v1(uuid,uuid,uuid,bigint,text)','execute') then
    raise exception 'new commands publicly callable'; end if;
end $$;
rollback;
select 'checklist_completion_undo: PASS' as result;
