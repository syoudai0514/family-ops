\set ON_ERROR_STOP on
begin;
do $$
declare a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); h uuid; token text; day date:=(now() at time zone 'Asia/Tokyo')::date;
  basic uuid; health uuid; transport uuid; special uuid; manual uuid; today uuid; shopping uuid; linked uuid; assigned uuid; junction uuid; pending uuid; simulated uuid; test_context uuid; request_id uuid; session_id uuid;
  ids uuid[]; before_outbox bigint; after_outbox bigint;
begin
  insert into auth.users(id) values(a),(b);
  h:=(public.server_tx_create_household(a,gen_random_uuid(),'unrecorded candidates','A')->>'household_id')::uuid;
  token:=public.server_tx_create_household_invite(a,gen_random_uuid())->>'raw_token'; perform public.server_tx_join_household(b,gen_random_uuid(),token,'B');
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by,calendar_visibility)
    values(h,'recurring','通常','household','morning',day-1,'unassigned','whole','todo','test',a,'hidden') returning id into basic;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by,calendar_visibility)
    values(h,'recurring','健康の記録','health','morning',day-1,'unassigned','whole','in_progress','test',a,'hidden') returning id into health;
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
  if cardinality(ids)<>3 or not (ids @> array[basic,health,transport]) then raise exception 'wrong eligible tasks: %',ids; end if;
  if ids && array[special,manual,today,shopping,linked,assigned,junction,pending,simulated] then raise exception 'protected task selected'; end if;
  if before_outbox<>after_outbox or (select status from public.task_instances where id=health)<>'in_progress' then raise exception 'candidate read mutated data'; end if;
  if has_function_privilege('authenticated','private.fn_unrecorded_routine_candidates_v1(date)','execute') then raise exception 'candidate reader exposed'; end if;
end $$;
rollback;
select 'unrecorded_candidate_foundation: PASS' as result;
