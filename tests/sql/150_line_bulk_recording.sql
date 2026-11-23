\set ON_ERROR_STOP on
begin;
set local role service_role;
do $$
declare
  a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid(); h uuid; other_h uuid; token text;
  whole uuid; checklist uuid; first_item uuid; remaining uuid; later_task uuid; optional_task uuid; codmon uuid; codmon_def uuid; partner_task uuid;
  note uuid; next_note uuid; stale_note uuid; undo_note uuid; batch uuid; stale_batch uuid; undo_batch uuid; before_first timestamptz;
  today date:=(now() at time zone 'Asia/Tokyo')::date; groups jsonb; brief jsonb; result jsonb;
begin
  insert into auth.users(id) values(a),(b),(outsider);
  h:=(public.server_tx_create_household(a,gen_random_uuid(),'LINE batch','A')->>'household_id')::uuid;
  token:=public.server_tx_create_household_invite(a,gen_random_uuid())->>'raw_token';
  perform public.server_tx_join_household(b,gen_random_uuid(),token,'B');
  other_h:=(public.server_tx_create_household(outsider,gen_random_uuid(),'Other','O')->>'household_id')::uuid;
  whole:=(public.server_tx_create_task(a,gen_random_uuid(),'朝食','chore',today,null,a,'whole','morning','[]'::jsonb)->>'task_id')::uuid;
  update public.task_instances set status='in_progress',attention_state='waiting',waiting_note='返事待ち',next_check_at=now()+interval '1 hour' where id=whole;
  checklist:=(public.server_tx_create_task(a,gen_random_uuid(),'準備','preparation',today,null,a,'subtasks','morning',jsonb_build_array(
    jsonb_build_object('title','相手が済ませた','required',true,'sort_order',1),
    jsonb_build_object('title','残り','required',true,'sort_order',2)))->>'task_id')::uuid;
  select id into first_item from public.task_subtask_instances where task_instance_id=checklist and sort_order=1;
  select id into remaining from public.task_subtask_instances where task_instance_id=checklist and sort_order=2;
  perform public.server_tx_set_subtask_completion(b,gen_random_uuid(),first_item,true,'self',null::bigint);
  select completed_at into before_first from public.task_subtask_instances where id=first_item;
  optional_task:=(public.server_tx_create_task(a,gen_random_uuid(),'余裕があれば','chore',today,null,a,'whole','morning','[]'::jsonb)->>'task_id')::uuid;
  update public.task_instances set expectation='optional' where id=optional_task;
  partner_task:=(public.server_tx_create_task(a,gen_random_uuid(),'相手の作業','chore',today,null,b,'whole','morning','[]'::jsonb)->>'task_id')::uuid;
  insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,created_by)
    values(h,'codmon_submit','コドモン送信','nursery','morning','whole',a) returning id into codmon_def;
  insert into public.task_instances(household_id,task_definition_id,origin,title,category,routine_phase,scheduled_date,completion_mode,status,source,created_by,planned_assignee_id,assignment_mode)
    values(h,codmon_def,'manual','コドモン送信','nursery','morning',today,'whole','todo','test',a,a,'person') returning id into codmon;
  select coalesce(jsonb_agg(jsonb_build_object('task_id',id,'revision',revision,'status',status,'expectation',expectation,
      'assignment_mode',assignment_mode,'planned_assignee_id',planned_assignee_id) order by id),'[]'::jsonb)
    into groups from public.task_instances where id in (whole,checklist,optional_task,codmon,partner_task);
  brief:=jsonb_build_object('local_date',today,'own_task_groups',jsonb_build_object('morning',groups,'evening','[]'::jsonb));
  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
    values(h,a,'daily_brief.v2','朝のおうちノート','body',jsonb_build_object('brief',brief),'line-bulk-test') returning id into note;
  result:=public.server_tx_prepare_line_bulk_v1(a,note);
  batch:=(result->>'id')::uuid;
  if batch is null or (select jsonb_array_length(items) from private.line_bulk_batches where id=batch)<>2 then
    raise exception 'expected exactly own required non-Codmon tasks: %',result; end if;
  if (public.server_tx_prepare_line_bulk_v1(a,note)->>'id')::uuid<>batch then raise exception 'preparation not idempotent'; end if;
  begin perform public.server_tx_complete_line_bulk_v1(outsider,batch); raise exception 'outsider completed batch';
    exception when others then if sqlerrm<>'CROSS_HOUSEHOLD_RESOURCE' then raise; end if; end;
  later_task:=(public.server_tx_create_task(a,gen_random_uuid(),'通知後に追加','chore',today,null,a,'whole','morning','[]'::jsonb)->>'task_id')::uuid;
  result:=public.server_tx_complete_line_bulk_v1(a,batch);
  if result->>'ok'<>'true' or (select status from public.task_instances where id=whole)<>'completed'
    or (select status from public.task_instances where id=checklist)<>'completed'
    or (select status from public.task_instances where id in (later_task))<>'todo'
    or (select status from public.task_instances where id=optional_task)<>'todo'
    or (select status from public.task_instances where id=codmon)<>'todo'
    or (select status from public.task_instances where id=partner_task)<>'todo'
    or (select completed_by from public.task_subtask_instances where id=first_item) is distinct from b then
      raise exception 'batch completion touched wrong work'; end if;
  if (public.server_tx_complete_line_bulk_v1(a,batch)->>'already_completed')<>'true' then raise exception 'duplicate completion'; end if;
  result:=public.server_tx_undo_line_bulk_v1(a,batch);
  if result->>'ok'<>'true' or (select status from public.task_instances where id=whole)<>'in_progress'
    or (select attention_state from public.task_instances where id=whole)<>'waiting'
    or (select waiting_note from public.task_instances where id=whole)<>'返事待ち'
    or (select status from public.task_instances where id=checklist)<>'todo'
    or not (select is_completed from public.task_subtask_instances where id=first_item)
    or (select completed_at from public.task_subtask_instances where id=first_item) is distinct from before_first
    or (select is_completed from public.task_subtask_instances where id=remaining) then
      raise exception 'batch undo did not preserve prior states'; end if;
  if (public.server_tx_undo_line_bulk_v1(a,batch)->>'already_undone')<>'true' then raise exception 'duplicate undo'; end if;
  if (public.server_tx_complete_line_bulk_v1(a,batch)->>'already_undone')<>'true' then raise exception 'undone button completed again'; end if;

  select coalesce(jsonb_agg(jsonb_build_object('task_id',id,'revision',revision,'status',status,'expectation',expectation,
      'assignment_mode',assignment_mode,'planned_assignee_id',planned_assignee_id) order by id),'[]'::jsonb)
    into groups from public.task_instances where id in (whole,checklist);
  brief:=jsonb_build_object('local_date',today,'own_task_groups',jsonb_build_object('morning',groups));
  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
    values(h,a,'daily_brief.v2','朝のおうちノート','body',jsonb_build_object('brief',brief),'line-bulk-stale') returning id into stale_note;
  stale_batch:=(public.server_tx_prepare_line_bulk_v1(a,stale_note)->>'id')::uuid;
  update public.task_instances set revision=revision+1 where id=whole;
  begin perform public.server_tx_complete_line_bulk_v1(a,stale_batch); raise exception 'stale batch completed';
    exception when others then if sqlerrm<>'AGGREGATE_REVISION_CONFLICT' then raise; end if; end;
  if (select status from public.task_instances where id=checklist)<>'todo' then raise exception 'stale batch partly completed'; end if;
  select coalesce(jsonb_agg(jsonb_build_object('task_id',id,'revision',revision,'status',status,'expectation',expectation,
      'assignment_mode',assignment_mode,'planned_assignee_id',planned_assignee_id) order by id),'[]'::jsonb)
    into groups from public.task_instances where id in (whole,checklist);
  brief:=jsonb_build_object('local_date',today,'own_task_groups',jsonb_build_object('morning',groups));
  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
    values(h,a,'daily_brief.v2','朝のおうちノート','body',jsonb_build_object('brief',brief),'line-bulk-stale-undo') returning id into undo_note;
  undo_batch:=(public.server_tx_prepare_line_bulk_v1(a,undo_note)->>'id')::uuid;
  perform public.server_tx_complete_line_bulk_v1(a,undo_batch);
  update public.task_instances set revision=revision+1 where id=whole;
  begin perform public.server_tx_undo_line_bulk_v1(a,undo_batch); raise exception 'stale batch undo succeeded';
    exception when others then if sqlerrm<>'AGGREGATE_REVISION_CONFLICT' then raise; end if; end;
  if (select status from public.task_instances where id=checklist)<>'completed' then raise exception 'stale batch partly undone'; end if;
  brief:=jsonb_set(brief,'{local_date}',to_jsonb(today+1));
  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
    values(h,a,'daily_brief.v2','朝のおうちノート','body',jsonb_build_object('brief',brief),'line-bulk-future') returning id into next_note;
  if public.server_tx_prepare_line_bulk_v1(a,next_note) is not null then raise exception 'future notification prepared'; end if;
  if has_function_privilege('authenticated','public.server_tx_prepare_line_bulk_v1(uuid,uuid)','execute')
    or has_function_privilege('authenticated','public.server_tx_complete_line_bulk_v1(uuid,uuid)','execute')
    or has_function_privilege('authenticated','public.server_tx_undo_line_bulk_v1(uuid,uuid)','execute') then
    raise exception 'bulk commands publicly callable'; end if;
end $$;
rollback;
select 'line_bulk_recording: PASS' as result;
