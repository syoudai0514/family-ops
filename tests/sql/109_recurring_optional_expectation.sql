-- Owner 2026-10-09: an optional recurring task ("掃除をしたら") is created as optional.
\set ON_ERROR_STOP on
begin;
set role service_role;

do $$
declare
  u1 uuid := gen_random_uuid();
  h uuid; opt_def uuid; req_def uuid; r record;
  mon date := date '2027-03-01';  -- Monday
begin
  insert into auth.users(id) values(u1);
  insert into public.profiles(user_id,display_name) values(u1,'Opt Papa');
  h := (public.server_tx_create_household(u1,gen_random_uuid(),'Opt H','Papa')->>'household_id')::uuid;

  insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,calendar_visibility,task_kind,default_expectation,created_by)
  values(h,'cleaning_optional_test','掃除（やったら）','cleaning','evening','whole','hidden','evening_chore','optional',u1) returning id into opt_def;
  insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,calendar_visibility,task_kind,default_expectation,created_by)
  values(h,'required_test','必須のこと','cleaning','evening','whole','hidden','evening_chore','required',u1) returning id into req_def;
  insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,effective_from,created_by)
  values(h,opt_def,1,'default','anyone_adult',mon,u1),(h,req_def,1,'default','anyone_adult',mon,u1);
  for r in select id from public.recurrence_rules where task_definition_id in (opt_def,req_def) loop
    perform private.materialize_recurrence_rule(h,r.id,mon,mon);
  end loop;

  if (select expectation from public.task_instances where household_id=h and task_definition_id=opt_def and scheduled_date=mon) is distinct from 'optional' then
    raise exception 'FAIL optional recurring: the instance must be optional';
  end if;
  if (select expectation from public.task_instances where household_id=h and task_definition_id=req_def and scheduled_date=mon) is not null then
    raise exception 'FAIL optional recurring: only optional is copied (required keeps the old behaviour)';
  end if;
end $$;

reset role;
rollback;
