\set ON_ERROR_STOP on
begin;
do $$
declare
  a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); h uuid; token text; d uuid; r_id uuid; tentative uuid; manual uuid; completed uuid; optional uuid; codmon uuid; codmon_def uuid;
  note uuid; note2 uuid; old_batch uuid; batch uuid; result jsonb; today date:=(now() at time zone 'Asia/Tokyo')::date;
begin
  insert into auth.users(id) values(a),(b);
  h:=(public.server_tx_create_household(a,gen_random_uuid(),'previous day consent','A')->>'household_id')::uuid;
  token:=public.server_tx_create_household_invite(a,gen_random_uuid())->>'raw_token'; perform public.server_tx_join_household(b,gen_random_uuid(),token,'B');
  insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,created_by) values(h,'yesterday_rule','朝支度','chore','morning','whole',a) returning id into d;
  insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,planned_assignee_id,effective_from,created_by)
    values(h,d,1,'prior','fixed',b,today-10,a) returning id into r_id;
  insert into public.task_instances(household_id,task_definition_id,recurrence_rule_id,origin,title,category,routine_phase,scheduled_date,planned_assignee_id,assignment_mode,completion_mode,status,source,created_by)
    values(h,d,r_id,'recurring','仮の担当','chore','morning',today-1,b,'person','whole','todo','test',a) returning id into tentative;
  manual:=(public.server_tx_create_task(b,gen_random_uuid(),'本人の昨日','chore',today-1,null,b,'whole','morning','[]'::jsonb)->>'task_id')::uuid;
  optional:=(public.server_tx_create_task(b,gen_random_uuid(),'任意','chore',today-1,null,b,'whole','morning','[]'::jsonb)->>'task_id')::uuid;
  update public.task_instances set expectation='optional' where id=optional;
  insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,created_by) values(h,'codmon_submit','コドモン送信','nursery','morning','whole',a) returning id into codmon_def;
  insert into public.task_instances(household_id,task_definition_id,origin,title,category,routine_phase,scheduled_date,planned_assignee_id,assignment_mode,completion_mode,status,source,created_by)
    values(h,codmon_def,'manual','コドモン送信','nursery','morning',today-1,b,'person','whole','todo','test',a) returning id into codmon;
  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
    values(h,b,'daily_brief.v2','朝のおうちノート','body',jsonb_build_object('brief',jsonb_build_object('local_date',today)),'prev-note-1') returning id into note;
  if public.server_tx_prepare_previous_day_consent_v1(b,note) is not null then raise exception 'inactive user prompted'; end if;
  completed:=(public.server_tx_create_task(b,gen_random_uuid(),'本人の記録','chore',today,null,b,'whole','morning','[]'::jsonb)->>'task_id')::uuid;
  perform public.server_tx_complete_task(b,gen_random_uuid(),completed,'self',false,'line');
  result:=public.server_tx_prepare_previous_day_consent_v1(b,note); old_batch:=(result->>'id')::uuid;
  if old_batch is null or (select jsonb_array_length(items) from private.previous_day_consent_batches where id=old_batch)<>1
    or (select items->0->>'id' from private.previous_day_consent_batches where id=old_batch)<>manual::text then raise exception 'wrong yesterday scope'; end if;
  begin perform public.server_tx_complete_previous_day_consent_v1(a,old_batch); raise exception 'other actor completed';
    exception when others then if sqlerrm<>'CROSS_HOUSEHOLD_RESOURCE' then raise; end if; end;
  update public.task_instances set revision=revision+1 where id=manual;
  begin perform public.server_tx_complete_previous_day_consent_v1(b,old_batch); raise exception 'stale snapshot completed';
    exception when others then if sqlerrm<>'AGGREGATE_REVISION_CONFLICT' then raise; end if; end;
  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
    values(h,b,'daily_brief.v2','朝のおうちノート','body',jsonb_build_object('brief',jsonb_build_object('local_date',today)),'prev-note-2') returning id into note2;
  batch:=(public.server_tx_prepare_previous_day_consent_v1(b,note2)->>'id')::uuid;
  result:=public.server_tx_complete_previous_day_consent_v1(b,batch);
  if result->>'ok'<>'true' or (select status from public.task_instances where id=manual)<>'completed'
    or (select status from public.task_instances where id=tentative)<>'todo'
    or (select status from public.task_instances where id=optional)<>'todo'
    or (select status from public.task_instances where id=codmon)<>'todo' then raise exception 'yesterday touched excluded work'; end if;
  if (public.server_tx_complete_previous_day_consent_v1(b,batch)->>'already_completed')<>'true' then raise exception 'previous replay'; end if;
  perform public.server_tx_undo_previous_day_consent_v1(b,batch);
  if (select status from public.task_instances where id=manual)<>'todo' then raise exception 'previous undo failed'; end if;
  if (public.server_tx_undo_previous_day_consent_v1(b,batch)->>'already_undone')<>'true' then raise exception 'previous undo replay'; end if;
  if has_function_privilege('authenticated','public.server_tx_prepare_previous_day_consent_v1(uuid,uuid)','execute')
    or has_function_privilege('authenticated','public.server_tx_complete_previous_day_consent_v1(uuid,uuid)','execute')
    or has_function_privilege('authenticated','public.server_tx_undo_previous_day_consent_v1(uuid,uuid)','execute') then raise exception 'previous public RPC'; end if;
end $$;
rollback;
select 'previous_day_consent: PASS' as result;
