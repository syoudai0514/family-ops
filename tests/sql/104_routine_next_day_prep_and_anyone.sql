-- Owner rules 2026-10-04: nursery preparation moves to the evening before and is done
-- by the adult who does NOT take the children the next day; first-come tasks
-- ("先に家を出る人") are 誰でもOK.
\set ON_ERROR_STOP on
begin;
set role service_role;

do $$
declare
  u1 uuid := gen_random_uuid();
  u2 uuid := gen_random_uuid();
  h uuid; token text;
  dropoff_def uuid; prep_def uuid; anyone_def uuid;
  prep_rule uuid; anyone_rule uuid;
  mon date := date '2027-02-01';  -- Monday
  r record;
  v_count int;
begin
  insert into auth.users(id) values(u1),(u2);
  insert into public.profiles(user_id,display_name) values(u1,'Prep Papa'),(u2,'Prep Mama');
  h := (public.server_tx_create_household(u1,gen_random_uuid(),'Prep H','Papa')->>'household_id')::uuid;
  token := public.server_tx_create_household_invite(u1,gen_random_uuid())->>'raw_token';
  perform public.server_tx_join_household(u2,gen_random_uuid(),token,'Mama');

  select id into dropoff_def from public.task_definitions where household_id=h and code='dropoff';
  if dropoff_def is null then
    insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,calendar_visibility,task_kind,created_by)
    values(h,'dropoff','送り','transport','morning','whole','transport','transport',u1) returning id into dropoff_def;
  end if;
  -- Tomorrow's dropoff: Tue = papa, Wed = mama, Thu = mama, Fri = papa (no row on Sat).
  insert into public.task_instances(household_id,task_definition_id,origin,title,category,routine_phase,scheduled_date,completion_mode,status,source,created_by,planned_assignee_id)
  select h,dropoff_def,'manual','送り','transport','morning',d,'whole','todo','test',u1,who
  from (values (mon+1,u1),(mon+2,u2),(mon+3,u2),(mon+4,u1)) v(d,who);

  insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,calendar_visibility,task_kind,created_by)
  values(h,'prep_evening_test','明日の保育園準備','childcare','evening','whole','hidden','evening_chore',u1) returning id into prep_def;
  insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,scheduled_local_time,effective_from,created_by)
  select h,prep_def,w,'default','next_day_nondropoff_adult',time '21:00',mon,u1 from generate_series(1,5) w;

  insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,calendar_visibility,task_kind,created_by)
  values(h,'anyone_test','食洗機を空ける（先に家を出る人）','housework','morning','whole','hidden','morning_chore',u1) returning id into anyone_def;
  insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,scheduled_local_time,effective_from,created_by)
  values(h,anyone_def,2,'default','anyone_adult',time '07:00',mon,u1) returning id into anyone_rule;

  for r in select id from public.recurrence_rules where task_definition_id in (prep_def,anyone_def) loop
    perform private.materialize_recurrence_rule(h,r.id,mon,mon+6);
  end loop;

  -- Mon evening -> Tue dropoff papa -> mama prepares; Tue -> Wed mama -> papa; Wed, Thu likewise.
  for r in select * from (values (mon,u2),(mon+1,u1),(mon+2,u1),(mon+3,u2)) v(d,who) loop
    if not exists(select 1 from public.task_instances where household_id=h and task_definition_id=prep_def
                  and scheduled_date=r.d and planned_assignee_id=r.who and assignment_mode='person') then
      raise exception 'FAIL next-day prep: % must be prepared by the adult not taking the children the next day', r.d;
    end if;
  end loop;
  -- Fri evening: Saturday is not a nursery day -> no preparation task.
  select count(*) into v_count from public.task_instances where household_id=h and task_definition_id=prep_def and scheduled_date=mon+4;
  if v_count<>0 then raise exception 'FAIL next-day prep: no task before a non-nursery day'; end if;

  -- Tomorrow's dropoff changes (Wed: mama -> papa): Tuesday evening's preparation follows.
  update public.task_instances set planned_assignee_id=null where household_id=h and task_definition_id=dropoff_def and scheduled_date=mon+2;
  update public.task_instances set planned_assignee_id=u1 where household_id=h and task_definition_id=dropoff_def and scheduled_date=mon+2;
  perform private.fn_reconcile_transport_role_date_v1(h,mon+2,'dropoff','test',null);
  if not exists(select 1 from public.task_instances where household_id=h and task_definition_id=prep_def
                and scheduled_date=mon+1 and planned_assignee_id=u2) then
    raise exception 'FAIL next-day prep: a changed dropoff must reassign the evening before';
  end if;

  if not exists(select 1 from public.task_instances where household_id=h and task_definition_id=anyone_def
                and scheduled_date=mon+1 and assignment_mode='anyone' and planned_assignee_id is null) then
    raise exception 'FAIL anyone_adult: must be 誰でもOK (assignment_mode anyone, no assignee)';
  end if;
end $$;

reset role;
rollback;
