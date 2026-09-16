-- Daily Codmon coordination regression.
-- Proves assignment derivation, nonworkday suppression, final-send readiness,
-- and 09:00 targeted reminder dedup without any provider mutation.
\set ON_ERROR_STOP on

begin;
set role service_role;

do $$
declare
  u1 uuid:=gen_random_uuid();
  u2 uuid:=gen_random_uuid();
  hh uuid;
  ar1 uuid;
  ar2 uuid;
  pickup_def uuid;
  dropoff_def uuid;
  evening_def uuid;
  holiday_def uuid;
  previous_task uuid;
  dropoff_task uuid;
  pickup_task uuid;
  workday date;
  reminder_day date;
  resolver_day date;
  holiday_day date;
  prior_day date;
  previous_rule uuid;
  submit_task uuid;
  input_task record;
  resolved jsonb;
  notification_result jsonb;
  n int;
begin
  insert into auth.users(id) values(u1),(u2);
  hh:=(public.server_tx_create_household(
    u1,gen_random_uuid(),'codmon regression','Owner'
  )->>'household_id')::uuid;

  insert into public.household_members(household_id,user_id,member_role,family_role)
  values(hh,u2,'adult','mama');
  update public.household_members
  set family_role='papa'
  where household_id=hh and user_id=u1;

  perform private.backfill_canonical_foundation_v1();

  select id into ar1 from public.domain_actor_refs
  where household_id=hh and actor_kind='real_user' and real_user_id=u1;
  select id into ar2 from public.domain_actor_refs
  where household_id=hh and actor_kind='real_user' and real_user_id=u2;

  select id into pickup_def from public.task_definitions
  where household_id=hh and code='pickup';
  select id into dropoff_def from public.task_definitions
  where household_id=hh and code='dropoff';
  if pickup_def is null or dropoff_def is null then
    raise exception 'FAIL codmon: transport definitions missing';
  end if;

  select min(d::date) into workday
  from generate_series(
    (now() at time zone 'Asia/Tokyo')::date+1,
    (now() at time zone 'Asia/Tokyo')::date+21,
    interval '1 day'
  ) d
  where extract(isodow from d)::int between 1 and 5
    and not private.fn_is_nonworkday(d::date);

  select min(d::date) into reminder_day
  from generate_series(workday+1,workday+21,interval '1 day') d
  where extract(isodow from d)::int between 1 and 5
    and not private.fn_is_nonworkday(d::date);

  select min(d::date) into resolver_day
  from generate_series(reminder_day+2,reminder_day+28,interval '1 day') d
  where extract(isodow from d)::int between 1 and 5
    and not private.fn_is_nonworkday(d::date);

  if workday is null or reminder_day is null or resolver_day is null then
    raise exception 'FAIL codmon: could not choose workdays';
  end if;

  -- Canonical transport truth for the target day.
  insert into public.task_instances(
    household_id,task_definition_id,origin,title,category,routine_phase,
    scheduled_date,due_at,planned_assignee_id,planned_assignee_actor_ref_id,
    assignment_mode,assignment_source,completion_mode,status,source,created_by
  ) values(
    hh,dropoff_def,'manual','送り','transport','morning',workday,
    ((workday::text||' 08:00')::timestamp at time zone 'Asia/Tokyo'),
    u1,ar1,'person','legacy_snapshot','whole','todo','test',u1
  ) returning id into dropoff_task;

  insert into public.task_instances(
    household_id,task_definition_id,origin,title,category,routine_phase,
    scheduled_date,due_at,planned_assignee_id,planned_assignee_actor_ref_id,
    assignment_mode,assignment_source,completion_mode,status,source,created_by
  ) values(
    hh,pickup_def,'manual','お迎え','transport','evening',workday,
    ((workday::text||' 18:20')::timestamp at time zone 'Asia/Tokyo'),
    u2,ar2,'person','legacy_snapshot','whole','todo','test',u1
  ) returning id into pickup_task;

  -- Yesterday's actual pickup was Mama/u2. The next morning's "yesterday
  -- dinner / condition" input must follow that person.
  prior_day:=workday-1;
  insert into public.task_instances(
    household_id,task_definition_id,origin,title,category,routine_phase,
    scheduled_date,due_at,planned_assignee_id,planned_assignee_actor_ref_id,
    assignment_mode,assignment_source,completion_mode,status,
    actual_completed_by_id,completed_at,source,created_by
  ) values(
    hh,pickup_def,'manual','お迎え','transport','evening',prior_day,
    ((prior_day::text||' 18:20')::timestamp at time zone 'Asia/Tokyo'),
    u2,ar2,'person','legacy_snapshot','whole','completed',
    u2,now(),'test',u1
  ) returning id into previous_task;

  perform private.fn_seed_codmon_daily_for_household_v1(hh,workday);

  -- The seed runs before this future workday. It must create recurrence rules
  -- only; it must NOT freeze tomorrow's "yesterday owner" before tomorrow.
  if exists(
    select 1
    from public.task_instances ti
    join public.task_definitions td
      on td.household_id=ti.household_id and td.id=ti.task_definition_id
    where ti.household_id=hh
      and ti.scheduled_date=workday
      and td.code like 'codmon_%'
  ) then
    raise exception 'FAIL codmon: future seed pre-materialized Codmon ownership';
  end if;

  -- Simulate the 00:10 JST materializer reaching that local workday.
  for previous_rule in
    select rr.id
    from public.recurrence_rules rr
    join public.task_definitions td
      on td.household_id=rr.household_id and td.id=rr.task_definition_id
    where rr.household_id=hh
      and td.code like 'codmon_%'
      and td.code not like 'codmon_test_%'
      and rr.weekday=extract(isodow from workday)::int
      and rr.active
  loop
    perform private.materialize_recurrence_rule(
      hh,previous_rule,workday,workday
    );
  end loop;

  if (
    select planned_assignee_id
    from public.task_instances ti
    join public.task_definitions td
      on td.household_id=ti.household_id and td.id=ti.task_definition_id
    where ti.household_id=hh and ti.scheduled_date=workday
      and td.code='codmon_masaki_pickup_input'
  ) is distinct from u2 then
    raise exception 'FAIL codmon: Masaki pickup input did not follow today pickup';
  end if;

  if (
    select planned_assignee_id
    from public.task_instances ti
    join public.task_definitions td
      on td.household_id=ti.household_id and td.id=ti.task_definition_id
    where ti.household_id=hh and ti.scheduled_date=workday
      and td.code='codmon_shino_previous_input'
  ) is distinct from u2 then
    raise exception 'FAIL codmon: Shino previous-day input did not follow yesterday owner';
  end if;

  if (
    select planned_assignee_id
    from public.task_instances ti
    join public.task_definitions td
      on td.household_id=ti.household_id and td.id=ti.task_definition_id
    where ti.household_id=hh and ti.scheduled_date=workday
      and td.code='codmon_shino_breakfast_input'
  ) is distinct from u1 then
    raise exception 'FAIL codmon: breakfast input did not follow morning/dropoff owner';
  end if;

  if (
    select planned_assignee_id
    from public.task_instances ti
    join public.task_definitions td
      on td.household_id=ti.household_id and td.id=ti.task_definition_id
    where ti.household_id=hh and ti.scheduled_date=workday
      and td.code='codmon_shino_pickup_input'
  ) is distinct from u2 then
    raise exception 'FAIL codmon: Shino pickup input did not follow today pickup';
  end if;

  select ti.id into submit_task
  from public.task_instances ti
  join public.task_definitions td
    on td.household_id=ti.household_id and td.id=ti.task_definition_id
  where ti.household_id=hh and ti.scheduled_date=workday
    and td.code='codmon_submit';

  if submit_task is null
     or (select planned_assignee_id from public.task_instances where id=submit_task) is distinct from u1 then
    raise exception 'FAIL codmon: final submit did not follow morning/dropoff owner';
  end if;

  if exists(
    select 1
    from public.task_instances ti
    join public.task_definitions td
      on td.household_id=ti.household_id and td.id=ti.task_definition_id
    where ti.household_id=hh and ti.scheduled_date=workday
      and td.code like 'codmon_%'
      and (
        ti.due_at is null
        or to_char(ti.due_at at time zone 'Asia/Tokyo','HH24:MI')<>'09:15'
      )
  ) then
    raise exception 'FAIL codmon: 09:15 deadline not applied';
  end if;

  -- Future "previous evening" ownership must not be precomputed.
  select rr.id into previous_rule
  from public.recurrence_rules rr
  join public.task_definitions td
    on td.household_id=rr.household_id and td.id=rr.task_definition_id
  where rr.household_id=hh
    and td.code='codmon_shino_previous_input'
    and rr.weekday=extract(isodow from workday)::int
    and rr.active
  limit 1;

  perform private.materialize_recurrence_rule(
    hh,previous_rule,workday,workday+7
  );

  if exists(
    select 1
    from public.task_instances ti
    join public.task_definitions td
      on td.household_id=ti.household_id and td.id=ti.task_definition_id
    where ti.household_id=hh
      and td.code='codmon_shino_previous_input'
      and ti.scheduled_date>workday
  ) then
    raise exception 'FAIL codmon: future previous-evening owner was pre-materialized';
  end if;

  -- Without pickup, one unique evening owner is accepted; mixed ownership
  -- fails closed rather than guessing.
  insert into public.task_definitions(
    household_id,code,title,category,routine_phase,completion_mode,
    created_by,task_kind
  ) values(
    hh,'evening_test_a','夜テストA','test','evening','whole',
    u1,'evening_chore'
  ) returning id into evening_def;

  delete from public.task_instances ti
  using public.task_definitions td
  where ti.household_id=hh and ti.task_definition_id=td.id
    and td.household_id=hh and td.code='pickup'
    and ti.scheduled_date=resolver_day-1;

  insert into public.task_instances(
    household_id,task_definition_id,origin,title,category,routine_phase,
    scheduled_date,planned_assignee_id,planned_assignee_actor_ref_id,
    assignment_mode,assignment_source,completion_mode,status,source,created_by
  ) values(
    hh,evening_def,'manual','夜テストA','test','evening',resolver_day-1,
    u1,ar1,'person','legacy_snapshot','whole','todo','test',u1
  );

  resolved:=private.fn_resolve_previous_evening_assignee_v1(hh,resolver_day);
  if resolved->>'mode'<>'person' or (resolved->>'user_id')::uuid is distinct from u1 then
    raise exception 'FAIL codmon: unique previous evening owner did not resolve';
  end if;

  insert into public.task_definitions(
    household_id,code,title,category,routine_phase,completion_mode,
    created_by,task_kind
  ) values(
    hh,'evening_test_b','夜テストB','test','evening','whole',
    u1,'evening_chore'
  ) returning id into evening_def;

  insert into public.task_instances(
    household_id,task_definition_id,origin,title,category,routine_phase,
    scheduled_date,planned_assignee_id,planned_assignee_actor_ref_id,
    assignment_mode,assignment_source,completion_mode,status,source,created_by
  ) values(
    hh,evening_def,'manual','夜テストB','test','evening',resolver_day-1,
    u2,ar2,'person','legacy_snapshot','whole','todo','test',u1
  );

  resolved:=private.fn_resolve_previous_evening_assignee_v1(hh,resolver_day);
  if resolved->>'mode'<>'unassigned' then
    raise exception 'FAIL codmon: ambiguous previous evening owner was guessed';
  end if;

  -- A weekday Japanese holiday suppresses Codmon even when a recurrence rule
  -- itself matches that weekday.
  select min(local_date) into holiday_day
  from private.jp_holidays
  where extract(isodow from local_date)::int between 1 and 5;
  if holiday_day is null then
    raise exception 'FAIL codmon: no weekday holiday fixture';
  end if;

  insert into public.task_definitions(
    household_id,code,title,category,routine_phase,completion_mode,
    created_by,task_kind
  ) values(
    hh,'codmon_test_holiday','休日コドモン','nursery','morning','whole',
    u1,'morning_preparation'
  ) returning id into holiday_def;

  insert into public.recurrence_rules(
    household_id,task_definition_id,weekday,slot_key,assignee_strategy,
    planned_assignee_id,scheduled_local_time,effective_from,active,created_by
  ) values(
    hh,holiday_def,extract(isodow from holiday_day)::int,'holiday-test',
    'fixed',u1,time '09:15',holiday_day,true,u1
  ) returning id into previous_rule;

  perform private.materialize_recurrence_rule(
    hh,previous_rule,holiday_day,holiday_day
  );
  if exists(
    select 1 from public.task_instances
    where household_id=hh and task_definition_id=holiday_def
      and scheduled_date=holiday_day
  ) then
    raise exception 'FAIL codmon: holiday occurrence was materialized';
  end if;

  -- Final send is blocked until all four input acknowledgements are complete.
  begin
    perform public.server_tx_complete_task(
      u1,gen_random_uuid(),submit_task,'self',false
    );
    raise exception 'FAIL codmon: final submit completed before inputs';
  exception when others then
    if sqlerrm='FAIL codmon: final submit completed before inputs' then raise; end if;
    if sqlerrm<>'CODMON_INPUTS_INCOMPLETE' then
      raise exception 'FAIL codmon: unexpected submit guard error %',sqlerrm;
    end if;
  end;

  for input_task in
    select ti.id,ti.planned_assignee_id
    from public.task_instances ti
    join public.task_definitions td
      on td.household_id=ti.household_id and td.id=ti.task_definition_id
    where ti.household_id=hh and ti.scheduled_date=workday
      and td.code in (
        'codmon_masaki_pickup_input',
        'codmon_shino_previous_input',
        'codmon_shino_breakfast_input',
        'codmon_shino_pickup_input'
      )
  loop
    perform public.server_tx_complete_task(
      input_task.planned_assignee_id,gen_random_uuid(),input_task.id,'self',false
    );
  end loop;

  perform public.server_tx_complete_task(
    u1,gen_random_uuid(),submit_task,'self',false
  );
  if (select status from public.task_instances where id=submit_task)<>'completed' then
    raise exception 'FAIL codmon: final submit did not complete after all inputs';
  end if;

  -- Completed submission never emits the 09:00 reminder.
  notification_result:=public.server_tx_dispatch_codmon_reminders_v1(
    ((workday::text||' 09:00')::timestamp at time zone 'Asia/Tokyo')
  );
  if coalesce((notification_result->>'notifications')::int,0)<>0 then
    raise exception 'FAIL codmon: completed submission emitted reminder';
  end if;

  -- Materialize a fresh workday to prove targeted reminder + dedup.
  insert into public.task_instances(
    household_id,task_definition_id,origin,title,category,routine_phase,
    scheduled_date,due_at,planned_assignee_id,planned_assignee_actor_ref_id,
    assignment_mode,assignment_source,completion_mode,status,source,created_by
  ) values(
    hh,dropoff_def,'manual','送り','transport','morning',reminder_day,
    ((reminder_day::text||' 08:00')::timestamp at time zone 'Asia/Tokyo'),
    u1,ar1,'person','legacy_snapshot','whole','todo','test',u1
  );

  insert into public.task_instances(
    household_id,task_definition_id,origin,title,category,routine_phase,
    scheduled_date,due_at,planned_assignee_id,planned_assignee_actor_ref_id,
    assignment_mode,assignment_source,completion_mode,status,source,created_by
  ) values(
    hh,pickup_def,'manual','お迎え','transport','evening',reminder_day,
    ((reminder_day::text||' 18:20')::timestamp at time zone 'Asia/Tokyo'),
    u2,ar2,'person','legacy_snapshot','whole','todo','test',u1
  );

  -- Recreate an unambiguous previous pickup after the resolver ambiguity test.
  insert into public.task_instances(
    household_id,task_definition_id,origin,title,category,routine_phase,
    scheduled_date,planned_assignee_id,planned_assignee_actor_ref_id,
    assignment_mode,assignment_source,completion_mode,status,
    actual_completed_by_id,completed_at,source,created_by
  ) values(
    hh,pickup_def,'manual','お迎え','transport','evening',reminder_day-1,
    u2,ar2,'person','legacy_snapshot','whole','completed',
    u2,now(),'test',u1
  );

  for previous_rule in
    select rr.id
    from public.recurrence_rules rr
    join public.task_definitions td
      on td.household_id=rr.household_id and td.id=rr.task_definition_id
    where rr.household_id=hh
      and td.code like 'codmon_%'
      and td.code not like 'codmon_test_%'
      and rr.weekday=extract(isodow from reminder_day)::int
      and rr.active
  loop
    perform private.materialize_recurrence_rule(
      hh,previous_rule,reminder_day,reminder_day
    );
  end loop;

  notification_result:=public.server_tx_dispatch_codmon_reminders_v1(
    ((reminder_day::text||' 09:00')::timestamp at time zone 'Asia/Tokyo')
  );
  if coalesce((notification_result->>'notifications')::int,0)<>2 then
    raise exception 'FAIL codmon: expected two targeted reminder intents, got %',
      notification_result;
  end if;

  if not exists(
    select 1 from public.user_notifications
    where household_id=hh and recipient_user_id=u1
      and type='codmon.deadline'
      and body like '%詩乃：コドモン入力（朝食）%'
  ) then
    raise exception 'FAIL codmon: morning owner reminder missing breakfast input';
  end if;

  if not exists(
    select 1 from public.user_notifications
    where household_id=hh and recipient_user_id=u2
      and type='codmon.deadline'
      and body like '%将生：コドモン入力%'
      and body like '%詩乃：コドモン入力（迎え）%'
  ) then
    raise exception 'FAIL codmon: pickup owner reminder missing assigned inputs';
  end if;

  perform public.server_tx_dispatch_codmon_reminders_v1(
    ((reminder_day::text||' 09:00')::timestamp at time zone 'Asia/Tokyo')
  );
  select count(*) into n
  from public.user_notifications
  where household_id=hh and type='codmon.deadline'
    and payload->>'local_date'=reminder_day::text;
  if n<>2 then
    raise exception 'FAIL codmon: reminder dedup failed (% rows)',n;
  end if;
end;
$$;

rollback;
select 'codmon_daily_submission: PASS' as result;
