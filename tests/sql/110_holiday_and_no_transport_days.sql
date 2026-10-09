-- Owner 2026-10-09: a Japanese public holiday is not a nursery day, and a day can be cleared by hand.
\set ON_ERROR_STOP on
begin;

-- A made-up Monday holiday (not in the real table).
insert into private.jp_holidays(local_date,name,source_fetched_at) values (date '2027-04-05','テスト祝日',now())
  on conflict (local_date) do nothing;

set role service_role;

do $$
declare
  u1 uuid := gen_random_uuid();
  u2 uuid := gen_random_uuid();
  h uuid; token text;
  hol date := date '2027-04-05';      -- Monday, a holiday
  normal date := date '2027-04-12';   -- Monday, a normal weekday
  dropoff_def uuid; pickup_def uuid; codmon_def uuid; morning_def uuid; daily_def uuid; garbage_def uuid;
  r record; v_res jsonb; v_res2 jsonb;
begin
  insert into auth.users(id) values(u1),(u2);
  insert into public.profiles(user_id,display_name) values(u1,'Hol Papa'),(u2,'Hol Mama');
  h := (public.server_tx_create_household(u1,gen_random_uuid(),'Hol H','Papa')->>'household_id')::uuid;
  token := public.server_tx_create_household_invite(u1,gen_random_uuid())->>'raw_token';
  perform public.server_tx_join_household(u2,gen_random_uuid(),token,'Mama');

  select id into dropoff_def from public.task_definitions where household_id=h and code='dropoff';
  if dropoff_def is null then
    insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,calendar_visibility,task_kind,created_by)
    values(h,'dropoff','送り','transport','morning','whole','transport','transport',u1) returning id into dropoff_def;
  end if;
  select id into pickup_def from public.task_definitions where household_id=h and code='pickup';
  if pickup_def is null then
    insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,calendar_visibility,task_kind,created_by)
    values(h,'pickup','迎え','transport','evening','whole','transport','transport',u1) returning id into pickup_def;
  end if;
  insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,calendar_visibility,task_kind,created_by)
  values(h,'codmon_submit','コドモン送信','nursery','morning','whole','hidden','morning_chore',u1) returning id into codmon_def;
  insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,calendar_visibility,task_kind,created_by)
  values(h,'weekday_morning_test','平日だけの朝のこと','housework','morning','whole','hidden','morning_chore',u1) returning id into morning_def;
  insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,calendar_visibility,task_kind,created_by)
  values(h,'daily_morning_test','毎日の朝のこと（薬）','health','morning','whole','hidden','morning_chore',u1) returning id into daily_def;
  insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,calendar_visibility,task_kind,created_by)
  values(h,'garbage_test','ゴミ出し','housework','morning','whole','hidden','morning_chore',u1) returning id into garbage_def;

  -- Mondays: transport legs, Codmon, a weekday-only morning routine, a daily one (also Sunday), garbage.
  insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,planned_assignee_id,scheduled_local_time,transport_leg,effective_from,created_by)
  values (h,dropoff_def,1,'default','fixed',u1,time '08:00','dropoff',date '2027-03-01',u1);
  insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,scheduled_local_time,transport_leg,effective_from,planned_assignee_id,created_by)
  values (h,pickup_def,1,'default','fixed',time '18:00','pickup',date '2027-03-01',u2,u1);
  insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,fallback_assignee_id,scheduled_local_time,effective_from,created_by) values
    (h,codmon_def,1,'default','dropoff_assignee',u1,time '09:15',date '2027-03-01',u1),
    (h,morning_def,1,'default','dropoff_assignee',u1,time '07:30',date '2027-03-01',u1),
    (h,daily_def,1,'default','dropoff_assignee',u1,time '07:00',date '2027-03-01',u1),
    (h,daily_def,7,'default','anyone_adult',null,time '07:00',date '2027-03-01',u1),
    (h,garbage_def,1,'default','dropoff_assignee',u1,time '07:45',date '2027-03-01',u1);

  for r in select id from public.recurrence_rules where household_id=h loop
    perform private.materialize_recurrence_rule(h,r.id,normal,normal);
    perform private.materialize_recurrence_rule(h,r.id,hol,hol);
  end loop;

  -- An ordinary Monday has everything.
  if (select count(*) from public.task_instances where household_id=h and scheduled_date=normal)<>6 then
    raise exception 'FAIL setup: an ordinary Monday must have all 6 tasks, got %', (select count(*) from public.task_instances where household_id=h and scheduled_date=normal);
  end if;
  -- The holiday has only the daily task and the garbage; no transport, Codmon or weekday-only morning routine.
  if exists(select 1 from public.task_instances ti join public.task_definitions td on td.id=ti.task_definition_id
            where ti.household_id=h and ti.scheduled_date=hol and td.code in ('dropoff','pickup','codmon_submit','weekday_morning_test')) then
    raise exception 'FAIL holiday: transport, Codmon and a weekday-only morning routine must not be made';
  end if;
  if (select count(*) from public.task_instances where household_id=h and scheduled_date=hol)<>2 then
    raise exception 'FAIL holiday: the daily task and the garbage must stay, got %', (select count(*) from public.task_instances where household_id=h and scheduled_date=hol);
  end if;
  -- What followed the dropoff person is 誰でもOK on a holiday (as on a weekend).
  if not exists(select 1 from public.task_instances ti join public.task_definitions td on td.id=ti.task_definition_id
                where ti.household_id=h and ti.scheduled_date=hol and td.code='daily_morning_test' and ti.assignment_mode='anyone') then
    raise exception 'FAIL holiday: a task that follows the dropoff person must be anyone';
  end if;

  -- By hand: clear the ordinary Monday.
  v_res := public.server_tx_clear_day_transport_v1(u1,gen_random_uuid(),normal);
  if (v_res->>'cancelled')::int<>4 then
    raise exception 'FAIL clear day: dropoff, pickup, Codmon and the weekday-only morning routine (4) must be cancelled, got %', v_res;
  end if;
  if exists(select 1 from public.task_instances ti join public.task_definitions td on td.id=ti.task_definition_id
            where ti.household_id=h and ti.scheduled_date=normal and td.code in ('dropoff','pickup','codmon_submit','weekday_morning_test') and ti.status<>'cancelled') then
    raise exception 'FAIL clear day: those four must be cancelled';
  end if;
  if not exists(select 1 from public.task_instances ti join public.task_definitions td on td.id=ti.task_definition_id
                where ti.household_id=h and ti.scheduled_date=normal and td.code='daily_morning_test' and ti.status='todo' and ti.assignment_mode='anyone') then
    raise exception 'FAIL clear day: the daily task stays and becomes anyone';
  end if;
  if not exists(select 1 from public.task_instances ti join public.task_definitions td on td.id=ti.task_definition_id
                where ti.household_id=h and ti.scheduled_date=normal and td.code='garbage_test' and ti.status='todo') then
    raise exception 'FAIL clear day: garbage is never dropped';
  end if;
  if not exists(select 1 from public.task_events e join public.task_instances ti on ti.id=e.task_instance_id join public.task_definitions td on td.id=ti.task_definition_id
                where td.code='dropoff' and ti.scheduled_date=normal and e.event_type='cancelled' and e.source='pwa') then
    raise exception 'FAIL clear day: the cancellation must be kept in history';
  end if;

  -- A replay returns the same answer; materializing again does not bring the day back.
  v_res2 := public.server_tx_clear_day_transport_v1(u1,gen_random_uuid(),normal);
  if (v_res2->>'cancelled')::int<>0 then raise exception 'FAIL clear day: a second clear finds nothing left to cancel'; end if;
  for r in select id from public.recurrence_rules where household_id=h loop
    perform private.materialize_recurrence_rule(h,r.id,normal,normal);
  end loop;
  if exists(select 1 from public.task_instances ti join public.task_definitions td on td.id=ti.task_definition_id
            where ti.household_id=h and ti.scheduled_date=normal and td.code='dropoff' and ti.status<>'cancelled') then
    raise exception 'FAIL clear day: the cleared day must not be made again';
  end if;

  -- A holiday that became known after its tasks were made is cleared by the daily batch.
  insert into public.task_instances(household_id,task_definition_id,recurrence_rule_id,logical_occurrence_key,origin,title,category,routine_phase,scheduled_date,completion_mode,status,source,created_by,planned_assignee_id,assignment_mode)
  select h,dropoff_def,rr.id,'late-holiday-test','recurring','送り','transport','morning',hol,'whole','todo','recurring',u1,u1,'person'
  from public.recurrence_rules rr where rr.task_definition_id=dropoff_def;
  perform public.server_tx_materialize_recurring_batch(date '2027-04-01');
  if exists(select 1 from public.task_instances where household_id=h and scheduled_date=hol and logical_occurrence_key='late-holiday-test' and status<>'cancelled') then
    raise exception 'FAIL batch: a transport task already made for a holiday must be cancelled by the daily batch';
  end if;
end $$;

reset role;
set role authenticated;
do $$
begin
  perform public.server_tx_clear_day_transport_v1(gen_random_uuid(),gen_random_uuid(),date '2027-04-12');
  raise exception 'FAIL clear day: authenticated must not call the command';
exception when insufficient_privilege then null;
end $$;
reset role;

rollback;
