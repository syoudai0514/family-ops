-- 2026-10-07: completing 「送り」 must not unassign the day's "その日に送る人" tasks.
\set ON_ERROR_STOP on
begin;
set role service_role;

do $$
declare
  u1 uuid := gen_random_uuid();
  u2 uuid := gen_random_uuid();
  h uuid; token text;
  dropoff_def uuid; codmon_def uuid; dropoff_id uuid;
  wed date := date '2027-02-03';  -- Wednesday
  r record;
begin
  insert into auth.users(id) values(u1),(u2);
  insert into public.profiles(user_id,display_name) values(u1,'Leg Papa'),(u2,'Leg Mama');
  h := (public.server_tx_create_household(u1,gen_random_uuid(),'Leg H','Papa')->>'household_id')::uuid;
  token := public.server_tx_create_household_invite(u1,gen_random_uuid())->>'raw_token';
  perform public.server_tx_join_household(u2,gen_random_uuid(),token,'Mama');

  select id into dropoff_def from public.task_definitions where household_id=h and code='dropoff';
  if dropoff_def is null then
    insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,calendar_visibility,task_kind,created_by)
    values(h,'dropoff','送り','transport','morning','whole','transport','transport',u1) returning id into dropoff_def;
  end if;
  insert into public.task_instances(household_id,task_definition_id,origin,title,category,routine_phase,scheduled_date,completion_mode,status,source,created_by,planned_assignee_id)
  values(h,dropoff_def,'manual','送り','transport','morning',wed,'whole','todo','test',u1,u1) returning id into dropoff_id;

  insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,calendar_visibility,task_kind,created_by)
  values(h,'codmon_leg_test','コドモン送信','nursery','morning','whole','hidden','morning_chore',u1) returning id into codmon_def;
  insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,scheduled_local_time,effective_from,created_by)
  values(h,codmon_def,3,'default','dropoff_assignee',time '09:15',wed,u1);
  for r in select id from public.recurrence_rules where task_definition_id=codmon_def loop
    perform private.materialize_recurrence_rule(h,r.id,wed,wed);
  end loop;
  if not exists(select 1 from public.task_instances where household_id=h and task_definition_id=codmon_def and planned_assignee_id=u1) then
    raise exception 'FAIL setup: the dropoff assignee must own the dropoff-assignee task';
  end if;

  -- The dropoff is done; the role reconcile runs again.
  update public.task_instances set status='completed',completed_at=now(),actual_completed_by_id=u1 where id=dropoff_id;
  perform private.fn_reconcile_transport_role_date_v1(h,wed,'dropoff','test',null);
  if not exists(select 1 from public.task_instances where household_id=h and task_definition_id=codmon_def
                and planned_assignee_id=u1 and assignment_mode='person') then
    raise exception 'FAIL completed leg: completing 送り must keep the day''s dropoff-assignee tasks with the same person';
  end if;
  if (private.fn_resolve_transport_role_assignment_v2(h,wed,'dropoff_assignee',null)->>'user_id')::uuid is distinct from u1 then
    raise exception 'FAIL completed leg: a completed dropoff still names who took the children';
  end if;

  -- A cancelled leg names no one.
  update public.task_instances set status='cancelled',completed_at=null,actual_completed_by_id=null where id=dropoff_id;
  if private.fn_resolve_transport_role_assignment_v2(h,wed,'dropoff_assignee',null)->>'mode'<>'unassigned' then
    raise exception 'FAIL completed leg: a cancelled dropoff must not name anyone';
  end if;
end $$;

reset role;
rollback;
