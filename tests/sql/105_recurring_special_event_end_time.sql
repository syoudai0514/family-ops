-- Owner 2026-10-05: 将生のプール is Saturday 14:00-15:00. A recurring special
-- (calendar) definition with default_duration_minutes gets an end time, so Google
-- Calendar shows a timed event; a chore keeps no end.
\set ON_ERROR_STOP on
begin;
set role service_role;

do $$
declare
  u1 uuid := gen_random_uuid();
  h uuid;
  pool_def uuid; chore_def uuid;
  r record;
  sat date := date '2027-02-06';  -- Saturday
  v_due timestamptz; v_end timestamptz;
begin
  insert into auth.users(id) values(u1);
  insert into public.profiles(user_id,display_name) values(u1,'Pool Papa');
  h := (public.server_tx_create_household(u1,gen_random_uuid(),'Pool H','Papa')->>'household_id')::uuid;

  insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,calendar_visibility,task_kind,default_duration_minutes,created_by)
  values(h,'pool_test','将生のプール','child_routine','anytime','whole','special','special',60,u1) returning id into pool_def;
  insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,calendar_visibility,task_kind,default_duration_minutes,created_by)
  values(h,'chore_test','トイレ掃除','housework','anytime','whole','hidden','morning_chore',15,u1) returning id into chore_def;
  insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,scheduled_local_time,effective_from,created_by)
  values(h,pool_def,6,'default','anyone_adult',time '14:00',sat-5,u1),
        (h,chore_def,6,'default','anyone_adult',time '10:00',sat-5,u1);

  for r in select id from public.recurrence_rules where task_definition_id in (pool_def,chore_def) loop
    perform private.materialize_recurrence_rule(h,r.id,sat-5,sat+1);
  end loop;

  select due_at,calendar_ends_at into v_due,v_end from public.task_instances where household_id=h and task_definition_id=pool_def and scheduled_date=sat;
  if v_due is distinct from timestamptz '2027-02-06 14:00+09' or v_end is distinct from timestamptz '2027-02-06 15:00+09' then
    raise exception 'FAIL special end time: pool must be 14:00-15:00, got % - %', v_due, v_end;
  end if;
  select calendar_ends_at into v_end from public.task_instances where household_id=h and task_definition_id=chore_def and scheduled_date=sat;
  if v_end is not null then
    raise exception 'FAIL special end time: a chore must not get a calendar end';
  end if;
end $$;

reset role;
rollback;
