-- Owner 2026-10-10: a task can carry required and optional (任意) checklist items; "全部やった" /
-- the 完了 button closes the task and checks the required items only. An optional item that was
-- not done stays unchecked, so the record says it was not done.
\set ON_ERROR_STOP on
begin;
set role service_role;

do $$
declare
  u1 uuid := gen_random_uuid();
  h uuid; def uuid; inst uuid; r jsonb;
  req_open int; opt_done int; v_status text;
begin
  insert into auth.users(id) values(u1);
  insert into public.profiles(user_id,display_name) values(u1,'Sub Papa');
  h := (public.server_tx_create_household(u1,gen_random_uuid(),'Sub H','Papa')->>'household_id')::uuid;
  insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,calendar_visibility,task_kind,created_by)
  values(h,'laundry_test','洗濯','laundry','evening','subtasks','hidden','evening_chore',u1) returning id into def;
  insert into public.task_instances(household_id,task_definition_id,title,category,routine_phase,scheduled_date,
    planned_assignee_id,planned_assignee_actor_ref_id,assignment_mode,completion_mode,status,source,created_by,origin)
  select h,def,'洗濯','laundry','evening',date '2027-05-10',u1,dar.id,'person','subtasks','todo','pwa',u1,'manual'
  from public.domain_actor_refs dar where dar.household_id=h and dar.real_user_id=u1 and dar.test_context_id is null
  limit 1 returning id into inst;
  insert into public.task_subtask_instances(household_id,task_instance_id,title,required,sort_order) values
    (h,inst,'畳む',true,1),(h,inst,'洗濯機のフィルター掃除',false,2);

  r := public.server_tx_complete_task(u1,gen_random_uuid(),inst,'self',true,'pwa');

  select status into v_status from public.task_instances where id=inst;
  select count(*) filter (where required and not is_completed), count(*) filter (where not required and is_completed)
    into req_open, opt_done from public.task_subtask_instances where task_instance_id=inst;
  if v_status<>'completed' then raise exception 'FAIL task not completed: %', v_status; end if;
  if req_open<>0 then raise exception 'FAIL a required item was left unchecked'; end if;
  if opt_done<>0 then raise exception 'FAIL the optional item was checked by 完了'; end if;
end $$;

rollback;
