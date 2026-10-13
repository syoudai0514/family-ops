\set ON_ERROR_STOP on
begin;
set role service_role;
do $$
declare
  u1 uuid:=gen_random_uuid(); u2 uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid();
  hh uuid; t uuid; test_task uuid; ctx uuid; a1 uuid; a2 uuid;
  op uuid:=gen_random_uuid(); shared_op uuid:=gen_random_uuid(); failure_op uuid:=gen_random_uuid();
  saved jsonb; shared jsonb; rev bigint; before_task jsonb; after_task jsonb;
  notification_count bigint; handover_count bigint; event_count bigint;
begin
  insert into auth.users(id) values(u1),(u2),(outsider);
  hh:=(public.server_tx_create_household(u1,gen_random_uuid(),'Progress family','Owner')->>'household_id')::uuid;
  perform public.server_tx_create_household(outsider,gen_random_uuid(),'Other progress family','Other');
  insert into public.household_members(household_id,user_id,member_role) values(hh,u2,'adult');
  update public.household_members set family_role=case user_id when u1 then 'papa' else 'mama' end where household_id=hh;
  a1:=(private.fn_require_production_actor_context_v1(u1)->>'actor_ref_id')::uuid;
  a2:=(private.fn_require_production_actor_context_v1(u2)->>'actor_ref_id')::uuid;
  t:=(public.server_tx_create_task(u1,gen_random_uuid(),'食洗機を空ける','chore','2026-10-12',null,u2,'whole','morning',null)->>'task_id')::uuid;
  update public.task_instances set assignment_mode='anyone',planned_assignee_id=null,
    planned_assignee_actor_ref_id=null,active_claimant_actor_ref_id=a2,claimed_at=now() where id=t;
  select revision, to_jsonb(x)-'revision'-'updated_at' into rev,before_task from public.task_instances x where id=t;
  notification_count:=(select count(*) from public.user_notifications where household_id=hh);
  handover_count:=(select count(*) from public.handovers where household_id=hh);

  saved:=public.server_tx_record_task_progress(u1,op,t,rev,
    '昨日の分がまだ洗えていなかった','朝の食器を追加し、洗浄を開始した',
    '洗浄中。食器の取り出しはまだ','洗浄が終わってから取り出してほしい',false,'none');
  select to_jsonb(x)-'revision'-'updated_at' into after_task from public.task_instances x where id=t;
  if before_task is distinct from after_task then raise exception 'FAIL: progress changed task outcome, assignment or claim'; end if;
  if (saved->>'revision')::bigint<>rev+1 or saved->>'handover_id' is not null
     or (select count(*) from public.user_notifications where household_id=hh)<>notification_count
     or (select count(*) from public.handovers where household_id=hh)<>handover_count
     or exists(select 1 from public.task_actual_participants where task_instance_id=t) then
    raise exception 'FAIL: memo-only recording completed work or shared without intent'; end if;
  if not exists(select 1 from public.task_events where id=(saved->>'task_event_id')::uuid
    and actor_id=u1 and actor_ref_id=a1 and test_context_id is null and event_type='work_progress_recorded'
    and payload->>'work_performer_actor_ref_id'=a1::text
    and payload->>'task_date'='2026-10-12' and payload->>'remaining_note'='洗浄中。食器の取り出しはまだ') then
    raise exception 'FAIL: observation and self-performed partial work were not separated'; end if;
  if saved is distinct from public.server_tx_record_task_progress(u1,op,t,rev,
    '昨日の分がまだ洗えていなかった','朝の食器を追加し、洗浄を開始した',
    '洗浄中。食器の取り出しはまだ','洗浄が終わってから取り出してほしい',false,'none')
    or (select count(*) from public.task_events where task_instance_id=t and event_type='work_progress_recorded')<>1 then
    raise exception 'FAIL: progress lost-response retry duplicated work'; end if;

  -- Every behavior-changing input belongs to receipt identity.
  begin
    perform public.server_tx_record_task_progress(u1,op,t,rev,
      '昨日の分がまだ洗えていなかった','朝の食器を追加し、洗浄を開始した',
      '洗浄中。食器の取り出しはまだ','洗浄が終わってから取り出してほしい',true,'none');
    raise exception 'FAIL: sharing changed on operation replay';
  exception when others then if sqlerrm<>'IDEMPOTENCY_CONFLICT' then raise; end if; end;
  begin
    perform public.server_tx_record_task_progress(u1,gen_random_uuid(),t,rev,'状況変更');
    raise exception 'FAIL: stale snapshot appended contradictory progress';
  exception when others then if sqlerrm<>'AGGREGATE_REVISION_CONFLICT' then raise; end if; end;

  rev:=(saved->>'revision')::bigint;
  shared:=public.server_tx_record_task_progress(u2,shared_op,t,rev,
    null,null,'食器は洗浄中','終了後に取り出してください',true,'required',now()+interval '1 day');
  if not exists(select 1 from public.handovers where id=(shared->>'handover_id')::uuid
    and household_id=hh and author_id=u2 and author_actor_ref_id=a2 and test_context_id is null
    and related_task_id=t and ack_policy='required' and revision=1
    and shared_text like E'ママからの引き継ぎ\n%'
    and shared_text like '%対象の作業日：2026/10/12%'
    and shared_text like '%確認の返答が必要です。LINEで「共有確認」と送って確認してください。%'
    and shared_text not like '%自分が%') then raise exception 'FAIL: task/date-linked handover or author/ack instructions missing'; end if;
  if (select count(*) from public.user_notifications where household_id=hh)<>notification_count+1
    or not exists(select 1 from public.user_notifications where household_id=hh and recipient_user_id=u1
      and aggregate_id=(shared->>'handover_id')::uuid and aggregate_type='handover'
      and payload->>'handover_id'=shared->>'handover_id' and notification_kind='handover_created') then
    raise exception 'FAIL: explicit sharing did not follow canonical household notification path'; end if;
  if exists(select 1 from public.task_events where id=(shared->>'task_event_id')::uuid
    and payload->>'work_performer_actor_ref_id' is not null) then
    raise exception 'FAIL: an observation asserted actual work'; end if;
  if shared is distinct from public.server_tx_record_task_progress(u2,shared_op,t,rev,
    null,null,'食器は洗浄中','終了後に取り出してください',true,'required',now()+interval '1 day')
    or (select revision from public.handovers where id=(shared->>'handover_id')::uuid)<>1
    or (select count(*) from public.user_notifications where household_id=hh)<>notification_count+1 then
    raise exception 'FAIL: shared retry changed handover or duplicated notifications'; end if;
  begin
    perform public.server_tx_record_task_progress(u2,shared_op,t,rev,
      null,null,'食器は洗浄中','終了後に取り出してください',true,'none',now()+interval '1 day');
    raise exception 'FAIL: acknowledgement policy changed on replay';
  exception when others then if sqlerrm<>'IDEMPOTENCY_CONFLICT' then raise; end if; end;
  begin
    perform public.server_tx_record_task_progress(u2,shared_op,t,rev,
      null,null,'食器は洗浄中','終了後に取り出してください',true,'required',now()+interval '2 days');
    raise exception 'FAIL: expiration changed on replay';
  exception when others then if sqlerrm<>'IDEMPOTENCY_CONFLICT' then raise; end if; end;

  -- Cancellation after success cannot change a receipt replay's result.
  update public.task_instances set status='cancelled',active_claimant_actor_ref_id=null,
    claimed_at=null,revision=revision+1 where id=t;
  if shared is distinct from public.server_tx_record_task_progress(u2,shared_op,t,rev,
    null,null,'食器は洗浄中','終了後に取り出してください',true,'required',now()+interval '1 day') then
    raise exception 'FAIL: later task state prevented receipt replay'; end if;
  select revision into rev from public.task_instances where id=t;
  begin
    perform public.server_tx_record_task_progress(u1,gen_random_uuid(),t,rev,'取り消された項目');
    raise exception 'FAIL: cancelled task accepted progress';
  exception when others then if sqlerrm<>'TASK_TERMINAL' then raise; end if; end;
  begin
    perform public.server_tx_record_task_progress(outsider,gen_random_uuid(),t,rev,'他世帯から');
    raise exception 'FAIL: other household appended a record';
  exception when others then if sqlerrm<>'CROSS_HOUSEHOLD_RESOURCE' then raise; end if; end;

  -- Completed work can receive a supplemental memo without changing performers.
  t:=(public.server_tx_create_task(u1,gen_random_uuid(),'保育園の準備','chore','2026-10-12',null,u2,'whole','morning',null)->>'task_id')::uuid;
  perform public.server_tx_complete_task(u2,gen_random_uuid(),t,'self',true,'pwa');
  select revision,to_jsonb(x)-'revision'-'updated_at' into rev,before_task from public.task_instances x where id=t;
  saved:=public.server_tx_record_task_progress(u1,gen_random_uuid(),t,rev,'シーツと着替えは準備済み',null,'残りの物を確認');
  select to_jsonb(x)-'revision'-'updated_at' into after_task from public.task_instances x where id=t;
  if before_task is distinct from after_task
    or (select count(*) from public.task_actual_participants where task_instance_id=t and removed_at is null)<>1
    or exists(select 1 from public.task_actual_participants where task_instance_id=t and actor_ref_id=a1 and removed_at is null) then
    raise exception 'FAIL: supplemental progress rewrote completed performers'; end if;

  insert into public.test_simulation_contexts(household_id,operator_user_id,label) values(hh,u1,'Progress scope') returning id into ctx;
  insert into public.task_instances(household_id,title,category,scheduled_date,status,completion_mode,routine_phase,test_context_id,origin,source,created_by)
    values(hh,'Test-only task','chore','2026-10-12','todo','whole','morning',ctx,'manual','manual',u1) returning id into test_task;
  select revision into rev from public.task_instances where id=test_task;
  begin
    perform public.server_tx_record_task_progress(u1,gen_random_uuid(),test_task,rev,'テスト項目',null,null,null,true,'none');
    raise exception 'FAIL: production adapter accepted test scope';
  exception when others then if sqlerrm<>'CROSS_HOUSEHOLD_RESOURCE' then raise; end if; end;

  select revision into rev from public.task_instances where id=t;
  begin
    perform public.server_tx_record_task_progress(u1,gen_random_uuid(),t,rev,E' \n\t　');
    raise exception 'FAIL: blank progress accepted';
  exception when others then if sqlerrm<>'INVALID_INPUT' then raise; end if; end;
  begin
    perform public.server_tx_record_task_progress(u1,gen_random_uuid(),t,rev,repeat('あ',2001));
    raise exception 'FAIL: overlong progress accepted';
  exception when others then if sqlerrm<>'INVALID_INPUT' then raise; end if; end;
  begin
    perform public.server_tx_record_task_progress(u1,gen_random_uuid(),t,rev,'状態',null,null,null,false,'required');
    raise exception 'FAIL: private record requested acknowledgement';
  exception when others then if sqlerrm<>'INVALID_INPUT' then raise; end if; end;

  -- Force a failure after the task update, handover and notification intent.
  -- All of them, including the new receipt claim, must roll back together.
  notification_count:=(select count(*) from public.user_notifications where household_id=hh);
  handover_count:=(select count(*) from public.handovers where household_id=hh);
  event_count:=(select count(*) from public.task_events where task_instance_id=t);
  insert into public.task_events(household_id,task_instance_id,actor_id,actor_ref_id,event_type,source,idempotency_key)
    values(hh,t,u1,a1,'test-conflict','pwa','task-progress:'||a1::text||':'||failure_op::text);
  begin
    perform public.server_tx_record_task_progress(u1,failure_op,t,rev,'状況',null,null,'次の人へ',true,'none');
    raise exception 'FAIL: forced event conflict did not fail';
  exception when unique_violation then null; end;
  if (select revision from public.task_instances where id=t)<>rev
    or (select count(*) from public.handovers where household_id=hh)<>handover_count
    or (select count(*) from public.user_notifications where household_id=hh)<>notification_count
    or (select count(*) from public.task_events where task_instance_id=t)<>event_count+1
    or exists(select 1 from private.canonical_operation_receipts where operation_id=failure_op and actor_ref_id=a1) then
    raise exception 'FAIL: rejected progress left partial transaction writes'; end if;

  if has_function_privilege('anon','public.server_tx_record_task_progress(uuid,uuid,uuid,bigint,text,text,text,text,boolean,text,timestamptz)','execute')
    or has_function_privilege('authenticated','public.server_tx_record_task_progress(uuid,uuid,uuid,bigint,text,text,text,text,boolean,text,timestamptz)','execute')
    or has_function_privilege('authenticated','private.fn_command_record_task_progress_v1(uuid,uuid,uuid,bigint,text,text,text,text,boolean,text,timestamptz)','execute')
    or has_function_privilege('anon','private.fn_command_record_task_progress_v1(uuid,uuid,uuid,bigint,text,text,text,text,boolean,text,timestamptz)','execute')
    or has_function_privilege('service_role','private.fn_claim_canonical_operation_v1(uuid,uuid,uuid,uuid,uuid,text,text)','execute') then
    raise exception 'FAIL: user-selected actor RPC exposed to browser'; end if;
end $$;
reset role;
rollback;
select 'task_progress: PASS' as result;
