\set ON_ERROR_STOP on
begin;
do $$
declare a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); h uuid; token text; day date:=(now() at time zone 'Asia/Tokyo')::date;
  basic uuid; health uuid; transport uuid; special uuid; manual uuid; today uuid; shopping uuid; linked uuid; assigned uuid; junction uuid; pending uuid; simulated uuid; test_context uuid; request_id uuid; session_id uuid;
  waiting uuid; until_done uuid; until_deadline uuid; critical uuid; special_kind uuid; event_task uuid; event_id uuid; actor_ref uuid;
  started uuid; partial uuid; noted uuid; participant uuid; handover_task uuid; old_outcome uuid; old_actor uuid; rescheduled uuid;
  changed_definition uuid; changed_def_task uuid;
  ids uuid[]; before_outbox bigint; after_outbox bigint;
begin
  insert into auth.users(id) values(a),(b);
  h:=(public.server_tx_create_household(a,gen_random_uuid(),'unrecorded candidates','A')->>'household_id')::uuid;
  token:=public.server_tx_create_household_invite(a,gen_random_uuid())->>'raw_token'; perform public.server_tx_join_household(b,gen_random_uuid(),token,'B');
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by,calendar_visibility)
    values(h,'recurring','通常','household','morning',day-1,'unassigned','whole','todo','test',a,'hidden') returning id into basic;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by,calendar_visibility)
    values(h,'recurring','健康の記録','health','morning',day-1,'unassigned','whole','todo','test',a,'hidden') returning id into health;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by,calendar_visibility)
    values(h,'recurring','送り迎え','dropoff','morning',day-1,'unassigned','whole','todo','test',a,'transport') returning id into transport;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by,calendar_visibility)
    values(h,'recurring','特別予定','household','morning',day-1,'unassigned','whole','todo','test',a,'special') returning id into special;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by,calendar_visibility)
    values(h,'manual','手動','household','morning',day-1,'unassigned','whole','todo','test',a,'hidden') returning id into manual;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by,calendar_visibility)
    values(h,'recurring','当日','household','morning',day,'unassigned','whole','todo','test',a,'hidden') returning id into today;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by,calendar_visibility)
    values(h,'recurring','買い物','shopping','morning',day-1,'unassigned','whole','todo','test',a,'hidden') returning id into shopping;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by,calendar_visibility)
    values(h,'recurring','お願い直結','household','morning',day-1,'unassigned','whole','todo','test',a,'hidden') returning id into linked;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by,calendar_visibility)
    values(h,'recurring','担当相談','household','morning',day-1,'unassigned','whole','todo','test',a,'hidden') returning id into assigned;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by,calendar_visibility)
    values(h,'recurring','お願い複数','household','morning',day-1,'unassigned','whole','todo','test',a,'hidden') returning id into junction;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by,calendar_visibility)
    values(h,'recurring','入力途中','household','morning',day-1,'unassigned','whole','todo','test',a,'hidden') returning id into pending;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by,attention_state,waiting_note)
    values(h,'recurring','返事待ち','household','morning',day-1,'unassigned','whole','todo','test',a,'waiting','返事を確認') returning id into waiting;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by,carryover_policy)
    values(h,'recurring','完了まで続く','household','morning',day-1,'unassigned','whole','todo','test',a,'until_done') returning id into until_done;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by,carryover_policy)
    values(h,'recurring','期限まで続く','household','morning',day-1,'unassigned','whole','todo','test',a,'until_deadline') returning id into until_deadline;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by,duplicate_sensitivity)
    values(h,'recurring','安全に重要','health','morning',day-1,'unassigned','whole','todo','test',a,'safety_critical') returning id into critical;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by)
    values(h,'recurring','特別な予定','household','morning',day-1,'unassigned','whole','todo','test',a) returning id into special_kind;
  update public.task_instances set task_kind='special' where id=special_kind;
  select id into actor_ref from public.domain_actor_refs where household_id=h and actor_kind='real_user' and real_user_id=a;
  insert into public.family_events(household_id,title,status,all_day,starts_at,ends_at,calendar_sync_preference,created_by_actor_ref_id)
    values(h,'特別な予定','active',false,now(),now()+interval '1 hour','external_follow',actor_ref) returning id into event_id;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by,event_id)
    values(h,'recurring','予定の準備','household','morning',day-1,'unassigned','whole','todo','test',a,event_id) returning id into event_task;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by)
    values(h,'recurring','着手済み','household','morning',day-1,'unassigned','whole','in_progress','test',a) returning id into started;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by)
    values(h,'recurring','一部チェック済み','household','morning',day-1,'unassigned','subtasks','todo','test',a) returning id into partial;
  insert into public.task_subtask_instances(household_id,task_instance_id,title,sort_order,is_completed,completed_by,completed_at)
    values(h,partial,'記録済み',1,true,a,now());
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by)
    values(h,'recurring','状況メモあり','household','morning',day-1,'unassigned','whole','todo','test',a) returning id into noted;
  insert into public.task_events(household_id,task_instance_id,actor_id,event_type,source)
    values(h,noted,a,'work_progress_recorded','pwa');
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by)
    values(h,'recurring','実施者の記録あり','household','morning',day-1,'unassigned','whole','todo','test',a) returning id into participant;
  insert into public.task_actual_participants(household_id,task_instance_id,actor_ref_id) values(h,participant,actor_ref);
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by)
    values(h,'recurring','引き継ぎ中','household','morning',day-1,'unassigned','whole','todo','test',a) returning id into handover_task;
  insert into public.handovers(household_id,author_id,shared_text,period,occurred_on,related_task_id)
    values(h,a,'家族に引き継ぎ中','day',day-1,handover_task);
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by,outcome_reason)
    values(h,'recurring','結果の記録あり','household','morning',day-1,'unassigned','whole','todo','test',a,'unknown') returning id into old_outcome;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by,actual_completed_by_id)
    values(h,'recurring','以前の実施者あり','household','morning',day-1,'unassigned','whole','todo','test',a,a) returning id into old_actor;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by,outcome_reason,rescheduled_to)
    values(h,'recurring','日付変更済み','household','morning',day-1,'unassigned','whole','todo','test',a,'rescheduled',day+1) returning id into rescheduled;
  insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,created_by)
    values(h,'archive_changed_definition','定義変更','household','morning','whole',a) returning id into changed_definition;
  insert into public.task_instances(household_id,task_definition_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by)
    values(h,changed_definition,'recurring','定義変更','household','morning',day-1,'unassigned','whole','todo','test',a) returning id into changed_def_task;
  update public.task_definitions set category='pickup' where id=changed_definition;
  if (select calendar_visibility from public.task_instances where id=changed_def_task)<>'hidden'
    or (select calendar_visibility from public.task_definitions where id=changed_definition)<>'transport' then
    raise exception 'calendar definition mismatch fixture invalid'; end if;
  insert into public.requests(household_id,requester_id,recipient_id,shared_title,status,linked_task_instance_id,assignment_task_instance_id)
    values(h,a,b,'お願い','pending',linked,assigned) returning id into request_id;
  insert into public.assignment_change_request_tasks(household_id,request_id,task_instance_id) values(h,request_id,junction);
  insert into public.routine_checkin_sessions(household_id,session_type,scheduled_date,assignee_id,status)
    values(h,'dropoff',day-1,a,'open') returning id into session_id;
  insert into public.routine_checkin_session_items(household_id,session_id,task_instance_id,display_order) values(h,session_id,pending,1);
  insert into public.test_simulation_contexts(household_id,operator_user_id) values(h,a) returning id into test_context;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,completion_mode,status,source,created_by,test_context_id)
    values(h,'recurring','テスト用','household','morning',day-1,'whole','todo','test',a,test_context) returning id into simulated;
  select count(*) into before_outbox from private.family_ops_calendar_mirrors;
  select array_agg(task_id order by task_id) into ids from private.fn_unrecorded_routine_candidates_v1(day) where household_id=h;
  select count(*) into after_outbox from private.family_ops_calendar_mirrors;
  if cardinality(ids)<>2 or not (ids @> array[basic,health]) then raise exception 'wrong eligible tasks: %',ids; end if;
  if (select count(*) from private.fn_unrecorded_routine_candidates_v1(day,h,basic))<>1
    or exists(select 1 from private.fn_unrecorded_routine_candidates_v1(day,gen_random_uuid(),basic)) then
    raise exception 'single-task candidate scope failed'; end if;
  if ids && array[transport,special,manual,today,shopping,linked,assigned,junction,pending,simulated,waiting,until_done,until_deadline,critical,special_kind,event_task,started,partial,noted,participant,handover_task,old_outcome,old_actor,rescheduled,changed_def_task] then raise exception 'protected task selected'; end if;
  if exists(select 1 from private.fn_unrecorded_routine_candidates_v1(day+30) where household_id=h and task_id=today) then
    raise exception 'future cutoff included today'; end if;
  if before_outbox<>after_outbox or (select status from public.task_instances where id=health)<>'todo' then raise exception 'candidate read mutated data'; end if;
  if has_function_privilege('authenticated','private.fn_unrecorded_routine_candidates_v1(date,uuid,uuid)','execute')
    or has_function_privilege('service_role','private.fn_unrecorded_routine_candidates_v1(date,uuid,uuid)','execute') then raise exception 'candidate reader exposed'; end if;
end $$;
rollback;
select 'unrecorded_candidate_foundation: PASS' as result;
