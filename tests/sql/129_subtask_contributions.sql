-- Mixed preparation, later completion, and corrections preserve each person's
-- items. The task's original target date never becomes the recording date.
\set ON_ERROR_STOP on
begin;
set local role service_role;

do $$
declare
  a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid();
  h uuid; other_h uuid; ar uuid; br uuid; t uuid; first_item uuid; second_item uuid;
  foreign_t uuid; foreign_item uuid;
  remaining_item uuid; optional_item uuid; claimed_t uuid; claimed_item uuid;
  optional_t uuid; optional_only_item uuid; test_context uuid; test_t uuid; test_item uuid;
  observed_t uuid; observed_item uuid;
  old_operation uuid; old_hash text; old_result jsonb;
  first_time timestamptz; first_result jsonb; batch_result jsonb; undo_result jsonb;
  r jsonb; revision bigint; event_count integer; parent_completed_at timestamptz;
  operation uuid:=gen_random_uuid(); undo_operation uuid:=gen_random_uuid();
begin
  insert into auth.users(id) values(a),(b),(outsider);
  h:=(public.server_tx_create_household(a,gen_random_uuid(),'Mixed preparation','First')->>'household_id')::uuid;
  insert into public.household_members(household_id,user_id,member_role) values(h,b,'adult');
  other_h:=(public.server_tx_create_household(outsider,gen_random_uuid(),'Other household','Other')->>'household_id')::uuid;
  select id into ar from public.domain_actor_refs where household_id=h and real_user_id=a;
  select id into br from public.domain_actor_refs where household_id=h and real_user_id=b;
  foreign_t:=(public.server_tx_create_task(outsider,gen_random_uuid(),'Old household task','chore',current_date,
    null,outsider,'subtasks','anytime',jsonb_build_array(jsonb_build_object('title','Old item','required',true,'sort_order',1)))->>'task_id')::uuid;
  select id into foreign_item from public.task_subtask_instances where task_instance_id=foreign_t;

  t:=(public.server_tx_create_task(a,gen_random_uuid(),'Nursery preparation','preparation',
    current_date-1,null,a,'subtasks','evening',jsonb_build_array(
      jsonb_build_object('title','Sheets','required',true,'sort_order',1),
      jsonb_build_object('title','First child clothes','required',true,'sort_order',2),
      jsonb_build_object('title','Second child shoes','required',true,'sort_order',3),
      jsonb_build_object('title','Optional spare bag','required',false,'sort_order',4)
    ))->>'task_id')::uuid;
  select id into first_item from public.task_subtask_instances where task_instance_id=t and sort_order=1;
  select id into second_item from public.task_subtask_instances where task_instance_id=t and sort_order=2;
  select id into remaining_item from public.task_subtask_instances where task_instance_id=t and sort_order=3;
  select id into optional_item from public.task_subtask_instances where task_instance_id=t and sort_order=4;
  select ti.revision into revision from public.task_instances ti where id=t;

  first_result:=public.server_tx_set_subtask_completion(a,operation,first_item,true,'self',revision);
  select completed_at into first_time from public.task_subtask_instances where id=first_item;
  if (select completed_by_actor_ref_id from public.task_subtask_instances where id=first_item) is distinct from ar
     or (select recorded_by_actor_ref_id from public.task_subtask_instances where id=first_item) is distinct from ar
     or (select status from public.task_instances where id=t)<>'todo'
     or (select scheduled_date from public.task_instances where id=t)<>current_date-1
     or first_time is null or (first_result->>'revision')::bigint<>revision+1 then
    raise exception 'FAIL contribution: initial item actor, recorder, progress, date, or revision lost';
  end if;
  -- Give this earlier contribution a distinct historical timestamp so a later
  -- bulk write cannot pass the preservation assertion merely because now() is
  -- transaction-stable throughout this test.
  first_time:=first_time-interval '1 hour';
  update public.task_subtask_instances set completed_at=first_time where id=first_item;
  revision:=(first_result->>'revision')::bigint;
  -- The person reporting completed preparation can differ from its performer.
  r:=public.server_tx_set_subtask_completion(a,gen_random_uuid(),second_item,true,'partner',revision);
  if (select completed_by from public.task_subtask_instances where id=second_item) is distinct from b
     or (select completed_by_actor_ref_id from public.task_subtask_instances where id=second_item) is distinct from br
     or (select recorded_by_actor_ref_id from public.task_subtask_instances where id=second_item) is distinct from ar then
    raise exception 'FAIL contribution: observed partner work attributed to recorder';
  end if;
  revision:=(r->>'revision')::bigint;
  select count(*) into event_count from public.task_events where task_instance_id=t;
  r:=public.server_tx_set_subtask_completion(b,gen_random_uuid(),first_item,true,'self',revision);
  if r->>'changed'<>'false' or (r->>'revision')::bigint<>revision
     or (select completed_by from public.task_subtask_instances where id=first_item) is distinct from a
     or (select completed_at from public.task_subtask_instances where id=first_item) is distinct from first_time
     or (select count(*) from public.task_events where task_instance_id=t)<>event_count then
    raise exception 'FAIL contribution: rechecking completed item rewrote earlier work';
  end if;
  -- An old operation's replay cannot borrow the latest parent revision.
  if public.server_tx_set_subtask_completion(a,operation,first_item,true,'self',
       (first_result->>'revision')::bigint-1) is distinct from first_result then
    raise exception 'FAIL contribution: retry changed the original receipt';
  end if;
  begin
    perform public.server_tx_set_subtask_completion(a,operation,first_item,false,'self',revision);
    raise exception 'FAIL contribution: changed payload reused operation id';
  exception when others then if sqlerrm<>'IDEMPOTENCY_CONFLICT' then raise; end if; end;

  batch_result:=public.server_tx_complete_task(b,gen_random_uuid(),t,'self',true,'pwa');
  select completed_at into parent_completed_at from public.task_instances where id=t;
  revision:=(batch_result->>'revision')::bigint;
  if (select status from public.task_instances where id=t)<>'completed'
     or (select actual_completed_by_id from public.task_instances where id=t) is not null
     or (select scheduled_date from public.task_instances where id=t)<>current_date-1
     or (select completed_by from public.task_subtask_instances where id=first_item) is distinct from a
     or (select completed_at from public.task_subtask_instances where id=first_item) is distinct from first_time
     or (select completed_by_actor_ref_id from public.task_subtask_instances where id=remaining_item) is distinct from br
     or (select recorded_by_actor_ref_id from public.task_subtask_instances where id=remaining_item) is distinct from br
     or (select is_completed from public.task_subtask_instances where id=optional_item)
     or (select count(*) from public.task_actual_participants where task_instance_id=t and removed_at is null)<>2
     or exists(select 1 from public.task_actual_participants where task_instance_id=t and removed_at is null and compatibility_primary)
     or not exists(select 1 from public.task_events where task_instance_id=t and event_type='completed'
       and payload->'performer_actor_ref_ids' @> to_jsonb(array[ar,br])) then
    raise exception 'FAIL contribution: remaining completion lost mixed actors or checked optional work';
  end if;

  undo_result:=public.server_tx_set_subtask_completion(a,undo_operation,second_item,false,'self',revision);
  if (select status from public.task_instances where id=t)<>'in_progress'
     or (select completed_at from public.task_instances where id=t) is not null
     or (select completed_by from public.task_subtask_instances where id=second_item) is not null
     or (select completed_by_actor_ref_id from public.task_subtask_instances where id=second_item) is not null
     or (select recorded_by_actor_ref_id from public.task_subtask_instances where id=second_item) is not null
     or (select count(*) from public.task_actual_participants where task_instance_id=t and removed_at is null)<>0
     or (select count(*) from public.task_actual_participants where task_instance_id=t and removed_at is not null)<>2
     or not exists(select 1 from public.task_events where task_instance_id=t
       and event_type='subtask_completion_reverted' and payload->>'subtask_instance_id'=second_item::text
       and payload->>'previous_performer_actor_ref_id'=br::text) then
    raise exception 'FAIL contribution: undo did not clear canonical fields or preserve audit history';
  end if;
  -- A stale screen cannot cancel a later completion, including a no-op check.
  begin
    perform public.server_tx_set_subtask_completion(b,gen_random_uuid(),remaining_item,false,'self',revision);
    raise exception 'FAIL contribution: stale revision unchecked newer work';
  exception when others then if sqlerrm<>'AGGREGATE_REVISION_CONFLICT' then raise; end if; end;
  revision:=(undo_result->>'revision')::bigint;
  r:=public.server_tx_set_subtask_completion(b,gen_random_uuid(),second_item,true,'self',revision);
  if (select status from public.task_instances where id=t)<>'completed'
     or (select count(*) from public.task_actual_participants where task_instance_id=t and removed_at is null)<>2 then
    raise exception 'FAIL contribution: individual last check omitted earlier contributors';
  end if;
  select completed_at into parent_completed_at from public.task_instances where id=t;
  if public.server_tx_set_subtask_completion(a,undo_operation,second_item,false,'self',revision-1)
     is distinct from undo_result or not (select is_completed from public.task_subtask_instances where id=second_item) then
    raise exception 'FAIL contribution: replay undid intervening recompletion';
  end if;

  -- Optional work is separately recorded and does not reopen required completion.
  revision:=(r->>'revision')::bigint;
  r:=public.server_tx_set_subtask_completion(a,gen_random_uuid(),optional_item,true,'self',revision);
  revision:=(r->>'revision')::bigint;
  perform public.server_tx_set_subtask_completion(a,gen_random_uuid(),optional_item,false,'self',revision);
  if (select status from public.task_instances where id=t)<>'completed'
     or (select completed_at from public.task_instances where id=t) is distinct from parent_completed_at then
    raise exception 'FAIL contribution: optional undo changed completed parent';
  end if;

  claimed_t:=(public.server_tx_create_task(a,gen_random_uuid(),'Claimed checklist','chore',current_date,
    null,null,'subtasks','anytime',jsonb_build_array(jsonb_build_object('title','Only item','required',true,'sort_order',1)))->>'task_id')::uuid;
  update public.task_instances set assignment_mode='anyone',assignment_source='override',
    active_claimant_actor_ref_id=br,claimed_at=now() where id=claimed_t;
  select id into claimed_item from public.task_subtask_instances where task_instance_id=claimed_t;
  select ti.revision into revision from public.task_instances ti where id=claimed_t;
  begin
    perform public.server_tx_set_subtask_completion(a,gen_random_uuid(),claimed_item,true,'self',revision);
    raise exception 'FAIL contribution: other person claim ignored on item';
  exception when others then if sqlerrm<>'TASK_CLAIMED_BY_OTHER' then raise; end if; end;
  begin
    perform public.server_tx_complete_task(a,gen_random_uuid(),claimed_t,'self',true,'line');
    raise exception 'FAIL contribution: other person claim ignored on parent';
  exception when others then if sqlerrm<>'TASK_CLAIMED_BY_OTHER' then raise; end if; end;
  begin
    perform public.server_tx_set_subtask_completion(a,gen_random_uuid(),claimed_item,true,'unknown',revision);
    raise exception 'FAIL contribution: unknown observation bypassed another person claim';
  exception when others then if sqlerrm<>'TASK_CLAIMED_BY_OTHER' then raise; end if; end;
  if (select active_claimant_actor_ref_id from public.task_instances where id=claimed_t) is distinct from br
     or (select is_completed from public.task_subtask_instances where id=claimed_item) then
    raise exception 'FAIL contribution: rejected observation cleared claim or checked item'; end if;
  -- Reporting the actual claimant's work is allowed; this is not a takeover.
  perform public.server_tx_set_subtask_completion(a,gen_random_uuid(),claimed_item,true,'partner',revision);
  if (select completed_by from public.task_subtask_instances where id=claimed_item) is distinct from b
     or (select active_claimant_actor_ref_id from public.task_instances where id=claimed_t) is not null then
    raise exception 'FAIL contribution: claimant completion did not keep performer and clear claim';
  end if;

  optional_t:=(public.server_tx_create_task(a,gen_random_uuid(),'Optional-only checklist','chore',current_date,
    null,a,'subtasks','anytime',jsonb_build_array(jsonb_build_object('title','Extra','required',false,'sort_order',1)))->>'task_id')::uuid;
  select id into optional_only_item from public.task_subtask_instances where task_instance_id=optional_t;
  perform public.server_tx_complete_task(a,gen_random_uuid(),optional_t,'self',true,'pwa');
  select ti.revision into revision from public.task_instances ti where id=optional_t;
  r:=public.server_tx_set_subtask_completion(b,gen_random_uuid(),optional_only_item,true,'self',revision);
  perform public.server_tx_set_subtask_completion(b,gen_random_uuid(),optional_only_item,false,'self',(r->>'revision')::bigint);
  if (select status from public.task_instances where id=optional_t)<>'completed'
     or not exists(select 1 from public.task_actual_participants where task_instance_id=optional_t
       and actor_ref_id=ar and removed_at is null)
     or exists(select 1 from public.task_actual_participants where task_instance_id=optional_t
       and actor_ref_id=br and removed_at is null) then
    raise exception 'FAIL contribution: optional-only explicit completion lost';
  end if;

  -- Readiness can be observed without inventing who prepared the item. The
  -- observer gets recorder evidence, and no execution participant or score.
  observed_t:=(public.server_tx_create_task(a,gen_random_uuid(),'Already prepared','preparation',current_date,
    null,a,'subtasks','morning',jsonb_build_array(jsonb_build_object('title','Found ready','required',true,'sort_order',1)))->>'task_id')::uuid;
  select id into observed_item from public.task_subtask_instances where task_instance_id=observed_t;
  select ti.revision into revision from public.task_instances ti where id=observed_t;
  begin
    update public.task_subtask_instances set is_completed=true,completed_at=now() where id=observed_item;
    raise exception 'FAIL contribution: no performer and no observer evidence accepted';
  exception when check_violation then null; end;
  r:=public.server_tx_set_subtask_completion(a,gen_random_uuid(),observed_item,true,'unknown',revision);
  if (select status from public.task_instances where id=observed_t)<>'completed'
     or (select completed_by from public.task_subtask_instances where id=observed_item) is not null
     or (select completed_by_actor_ref_id from public.task_subtask_instances where id=observed_item) is not null
     or (select recorded_by_actor_ref_id from public.task_subtask_instances where id=observed_item) is distinct from ar
     or (select count(*) from public.task_actual_participants where task_instance_id=observed_t and removed_at is null)<>0
     or not exists(select 1 from public.task_events where task_instance_id=observed_t
       and payload->>'completion_basis'='observed_ready' and actor_ref_id=ar) then
    raise exception 'FAIL contribution: observer was made performer or ready state lost';
  end if;
  perform public.server_tx_set_subtask_completion(b,gen_random_uuid(),observed_item,true,'self',(r->>'revision')::bigint);
  if (select completed_by_actor_ref_id from public.task_subtask_instances where id=observed_item) is not null then
    raise exception 'FAIL contribution: rechecking unknown performer invented attribution'; end if;
  r:=public.server_tx_set_subtask_completion(a,gen_random_uuid(),observed_item,false,'unknown',(r->>'revision')::bigint);
  if (select recorded_by_actor_ref_id from public.task_subtask_instances where id=observed_item) is not null
     or (select status from public.task_instances where id=observed_t)<>'in_progress' then
    raise exception 'FAIL contribution: unknown observation undo lost readiness correction'; end if;

  begin
    perform public.server_tx_set_subtask_completion(outsider,gen_random_uuid(),first_item,true,'self',1);
    raise exception 'FAIL contribution: cross-household item changed';
  exception when others then if sqlerrm<>'CROSS_HOUSEHOLD_RESOURCE' then raise; end if; end;
  begin
    perform public.server_tx_complete_task(outsider,gen_random_uuid(),t,'self',true,'pwa');
    raise exception 'FAIL contribution: cross-household parent changed';
  exception when others then if sqlerrm<>'CROSS_HOUSEHOLD_RESOURCE' then raise; end if; end;
  insert into public.test_simulation_contexts(household_id,operator_user_id) values(h,a) returning id into test_context;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,
    completion_mode,status,source,created_by,test_context_id)
  values(h,'manual','Simulation checklist','other','anytime',current_date,'subtasks','todo','test',a,test_context)
  returning id into test_t;
  insert into public.task_subtask_instances(household_id,task_instance_id,title,required,sort_order,test_context_id)
  values(h,test_t,'Simulation item',true,1,test_context) returning id into test_item;
  begin
    perform public.server_tx_set_subtask_completion(a,gen_random_uuid(),test_item,true,'self',1);
    raise exception 'FAIL contribution: production RPC changed simulation item';
  exception when others then if sqlerrm<>'ACTOR_SCOPE_CONFLICT' then raise; end if; end;
  begin
    perform public.server_tx_complete_task(a,gen_random_uuid(),test_t,'self',true,'pwa');
    raise exception 'FAIL contribution: production RPC changed simulation task';
  exception when others then if sqlerrm<>'ACTOR_SCOPE_CONFLICT' then raise; end if; end;
  if (select is_completed from public.task_subtask_instances where id=test_item) then
    raise exception 'FAIL contribution: scope rejection left changed test data'; end if;

  -- Model receipts retained from an earlier household context. Replaying a
  -- correct hash cannot authorize that earlier context after membership changes.
  -- Current composite member/ActorRef FKs prevent moving an actor with records;
  -- the retained-receipt fixture exercises the boundary without weakening FKs.
  old_operation:=gen_random_uuid();
  old_hash:=encode(sha256(convert_to('set-subtask-completion|'||first_item::text||'|true|self','UTF8')),'hex');
  old_result:=jsonb_build_object('ok',true,'old_household',true);
  insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash,actor_ref_id,
    result_type,result_id,result_payload)
  values(a,old_operation,'set-subtask-completion',old_hash,br,'task_subtask_instance',first_item,old_result);
  begin
    perform public.server_tx_set_subtask_completion(a,old_operation,first_item,true,'self');
    raise exception 'FAIL contribution: different ActorRef context receipt replayed';
  exception when others then if sqlerrm<>'CROSS_HOUSEHOLD_RESOURCE' then raise; end if; end;
  update private.mutation_receipts set actor_ref_id=null,result_id=foreign_item where actor_id=a and operation_id=old_operation;
  begin
    perform public.server_tx_set_subtask_completion(a,old_operation,first_item,true,'self');
    raise exception 'FAIL contribution: old null ActorRef receipt exposed old household';
  exception when others then if sqlerrm<>'CROSS_HOUSEHOLD_RESOURCE' then raise; end if; end;
  update private.mutation_receipts set result_id=first_item where actor_id=a and operation_id=old_operation;
  if public.server_tx_set_subtask_completion(a,old_operation,first_item,true,'self') is distinct from old_result then
    raise exception 'FAIL contribution: same-household null ActorRef compatibility receipt refused'; end if;

  old_operation:=gen_random_uuid();
  old_hash:=encode(sha256(convert_to('complete-task|'||t::text||'|self|true','UTF8')),'hex');
  insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash,actor_ref_id,
    result_type,result_id,result_payload)
  values(a,old_operation,'complete-task',old_hash,br,'task_instance',t,old_result);
  begin
    perform public.server_tx_complete_task(a,old_operation,t,'self',true,'pwa');
    raise exception 'FAIL contribution: different ActorRef completion receipt replayed';
  exception when others then if sqlerrm<>'CROSS_HOUSEHOLD_RESOURCE' then raise; end if; end;
  update private.mutation_receipts set actor_ref_id=null,result_id=foreign_t where actor_id=a and operation_id=old_operation;
  begin
    perform public.server_tx_complete_task(a,old_operation,t,'self',true,'pwa');
    raise exception 'FAIL contribution: old null completion receipt exposed old household';
  exception when others then if sqlerrm<>'CROSS_HOUSEHOLD_RESOURCE' then raise; end if; end;
  update private.mutation_receipts set result_id=t where actor_id=a and operation_id=old_operation;
  if public.server_tx_complete_task(a,old_operation,t,'self',true,'pwa') is distinct from old_result then
    raise exception 'FAIL contribution: same-household old completion receipt refused'; end if;
end;
$$;

reset role;
do $$ begin
  if has_function_privilege('anon','public.server_tx_set_subtask_completion(uuid,uuid,uuid,boolean,text,bigint)','execute')
     or has_function_privilege('authenticated','public.server_tx_set_subtask_completion(uuid,uuid,uuid,boolean,text,bigint)','execute')
     or has_function_privilege('authenticated','private.fn_sync_checklist_participants_v1(uuid,uuid,uuid,uuid)','execute') then
    raise exception 'FAIL contribution: service-only mutation exposed'; end if;
end; $$;
rollback;
select 'subtask_contributions: PASS' as result;
