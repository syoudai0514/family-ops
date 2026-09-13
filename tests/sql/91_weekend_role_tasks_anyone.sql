-- Weekend role-derived tasks: live transport > weekend anyone > weekday fallback.
-- Includes Shino medication and generic anyone claim lifecycle.
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
  med_am uuid;
  med_pm uuid;
  record_am uuid;
  record_pm uuid;
  sat date;
  mon date;
  sat_dow int:=6;
  mon_dow int:=1;
  sat_am_rule uuid;
  sat_pm_rule uuid;
  record_am_rule uuid;
  record_pm_rule uuid;
  mon_am_rule uuid;
  sat_am_task uuid;
  sat_pm_task uuid;
  record_am_task uuid;
  record_pm_task uuid;
  mon_am_task uuid;
  pickup_def uuid;
  pickup_task uuid;
  brief1 jsonb;
  brief2 jsonb;
  rev bigint;
begin
  insert into auth.users(id) values(u1),(u2);
  hh:=(public.server_tx_create_household(u1,gen_random_uuid(),'weekend anyone','Owner')->>'household_id')::uuid;
  insert into public.household_members(household_id,user_id,member_role,family_role)
  values(hh,u2,'adult','mama');
  update public.household_members set family_role='papa' where household_id=hh and user_id=u1;
  perform private.backfill_canonical_foundation_v1();

  select id into ar1 from public.domain_actor_refs
  where household_id=hh and actor_kind='real_user' and real_user_id=u1;
  select id into ar2 from public.domain_actor_refs
  where household_id=hh and actor_kind='real_user' and real_user_id=u2;

  -- Shino medication definitions are household-specific production setup, not
  -- part of the generic household bootstrap. Seed the same semantic shapes in
  -- this isolated regression household so the weekend rule is tested directly.
  insert into public.task_definitions(
    household_id,code,title,category,routine_phase,completion_mode,task_kind,
    include_in_routine_line,created_by
  ) values
    (hh,'med_shino_constipation_am','詩乃（便秘）の薬','health','morning','whole','morning_chore',true,u1),
    (hh,'med_shino_constipation_pm','詩乃（便秘）の薬','health','evening','whole','evening_chore',true,u1),
    (hh,'health_shino_med_bowel_record_am','詩乃の薬・便の記録','health','morning','subtasks','morning_chore',true,u1),
    (hh,'health_shino_med_bowel_record_pm','詩乃の薬・便の記録','health','evening','subtasks','evening_chore',true,u1)
  on conflict do nothing;

  select id into med_am from public.task_definitions
  where household_id=hh and code='med_shino_constipation_am';
  select id into med_pm from public.task_definitions
  where household_id=hh and code='med_shino_constipation_pm';
  select id into record_am from public.task_definitions
  where household_id=hh and code='health_shino_med_bowel_record_am';
  select id into record_pm from public.task_definitions
  where household_id=hh and code='health_shino_med_bowel_record_pm';
  select id into pickup_def from public.task_definitions
  where household_id=hh and code='pickup';
  if med_am is null or med_pm is null or record_am is null or record_pm is null or pickup_def is null then
    raise exception 'FAIL weekend anyone: required task definitions missing';
  end if;

  sat:=(now() at time zone 'Asia/Tokyo')::date
    + ((6-extract(isodow from (now() at time zone 'Asia/Tokyo')::date)::int+7)%7);
  if sat<(now() at time zone 'Asia/Tokyo')::date then sat:=sat+7; end if;
  mon:=sat+2;

  -- The generic household bootstrap may materialize transport rows for every
  -- weekday. This scenario specifically proves a transport-free weekend, so
  -- make both Saturday legs absent before materializing role-derived work.
  update public.task_instances ti
  set status='cancelled',
      planned_assignee_id=null,
      planned_assignee_actor_ref_id=null,
      assignment_mode='unassigned',
      revision=revision+1
  from public.task_definitions td
  where ti.household_id=hh
    and ti.task_definition_id=td.id
    and td.household_id=hh
    and td.code in ('pickup','dropoff')
    and ti.scheduled_date=sat
    and ti.status in ('todo','in_progress');

  sat_am_rule:=(public.server_tx_change_recurrence(
    u1,gen_random_uuid(),med_am,sat_dow,'weekend-am','dropoff_assignee',
    u1,'08:00',60,sat
  )->>'rule_id')::uuid;
  sat_pm_rule:=(public.server_tx_change_recurrence(
    u1,gen_random_uuid(),med_pm,sat_dow,'weekend-pm','pickup_assignee',
    u1,'20:00',60,sat
  )->>'rule_id')::uuid;
  record_am_rule:=(public.server_tx_change_recurrence(
    u1,gen_random_uuid(),record_am,sat_dow,'weekend-record-am','dropoff_assignee',
    u1,'08:05',60,sat
  )->>'rule_id')::uuid;
  record_pm_rule:=(public.server_tx_change_recurrence(
    u1,gen_random_uuid(),record_pm,sat_dow,'weekend-record-pm','pickup_assignee',
    u1,'20:05',60,sat
  )->>'rule_id')::uuid;
  mon_am_rule:=(public.server_tx_change_recurrence(
    u1,gen_random_uuid(),med_am,mon_dow,'weekday-am','dropoff_assignee',
    u1,'08:00',60,mon
  )->>'rule_id')::uuid;

  select id into sat_am_task from public.task_instances
  where household_id=hh and recurrence_rule_id=sat_am_rule and scheduled_date=sat;
  select id into sat_pm_task from public.task_instances
  where household_id=hh and recurrence_rule_id=sat_pm_rule and scheduled_date=sat;
  select id into record_am_task from public.task_instances
  where household_id=hh and recurrence_rule_id=record_am_rule and scheduled_date=sat;
  select id into record_pm_task from public.task_instances
  where household_id=hh and recurrence_rule_id=record_pm_rule and scheduled_date=sat;
  select id into mon_am_task from public.task_instances
  where household_id=hh and recurrence_rule_id=mon_am_rule and scheduled_date=mon;

  if (select assignment_mode from public.task_instances where id=sat_am_task)<>'anyone'
     or (select assignment_mode from public.task_instances where id=sat_pm_task)<>'anyone'
     or (select assignment_mode from public.task_instances where id=record_am_task)<>'anyone'
     or (select assignment_mode from public.task_instances where id=record_pm_task)<>'anyone'
     or (select planned_assignee_id from public.task_instances where id=sat_am_task) is not null
     or (select planned_assignee_id from public.task_instances where id=sat_pm_task) is not null
     or (select planned_assignee_id from public.task_instances where id=record_am_task) is not null
     or (select planned_assignee_id from public.task_instances where id=record_pm_task) is not null then
    raise exception 'FAIL weekend anyone: Shino medication/record weekend routines were not anyone';
  end if;

  if (select assignment_mode from public.task_instances where id=mon_am_task)<>'person'
     or (select planned_assignee_id from public.task_instances where id=mon_am_task) is distinct from u1 then
    raise exception 'FAIL weekend anyone: weekday fallback changed';
  end if;

  -- Unclaimed anyone work is visible to both adults and is not assignment_needed.
  brief1:=public.server_read_daily_brief(u1,sat);
  brief2:=public.server_read_daily_brief(u2,sat);
  if not exists(select 1 from jsonb_array_elements(brief1->'tasks') x where x->>'task_id'=sat_am_task::text)
     or not exists(select 1 from jsonb_array_elements(brief2->'tasks') x where x->>'task_id'=sat_am_task::text) then
    raise exception 'FAIL weekend anyone: shared task not visible to both adults';
  end if;
  if exists(select 1 from jsonb_array_elements(brief1->'urgent_actions') x
            where x->>'kind'='assignment_needed' and x->>'task_id'=sat_am_task::text) then
    raise exception 'FAIL weekend anyone: anyone task rendered as assignment_needed';
  end if;

  -- Claim / release / takeover lifecycle.
  select revision into rev from public.task_instances where id=sat_am_task;
  perform public.server_tx_task_anyone_claim_v1(
    u1,gen_random_uuid(),sat_am_task,'claim',rev,'pwa'
  );
  if (select active_claimant_actor_ref_id from public.task_instances where id=sat_am_task)
     is distinct from ar1 then
    raise exception 'FAIL weekend anyone: claim did not set current actor';
  end if;

  brief2:=public.server_read_daily_brief(u2,sat);
  if not exists(
    select 1 from jsonb_array_elements(brief2->'tasks') x
    where x->>'task_id'=sat_am_task::text
      and x->>'active_claimant_actor_ref_id'=ar1::text
  ) then
    raise exception 'FAIL weekend anyone: partner lost visibility of claimed task';
  end if;

  select revision into rev from public.task_instances where id=sat_am_task;
  perform public.server_tx_task_anyone_claim_v1(
    u2,gen_random_uuid(),sat_am_task,'takeover',rev,'line'
  );
  if (select active_claimant_actor_ref_id from public.task_instances where id=sat_am_task)
     is distinct from ar2 then
    raise exception 'FAIL weekend anyone: takeover did not replace claimant';
  end if;

  select revision into rev from public.task_instances where id=sat_am_task;
  perform public.server_tx_task_anyone_claim_v1(
    u2,gen_random_uuid(),sat_am_task,'release',rev,'pwa'
  );
  if (select active_claimant_actor_ref_id from public.task_instances where id=sat_am_task) is not null then
    raise exception 'FAIL weekend anyone: release did not clear claimant';
  end if;

  -- A real weekend pickup still wins for pickup-derived medication.
  insert into public.task_instances(
    household_id,task_definition_id,origin,title,category,routine_phase,scheduled_date,
    due_at,planned_assignee_id,planned_assignee_actor_ref_id,assignment_mode,
    assignment_source,completion_mode,status,source,created_by
  ) values(
    hh,pickup_def,'manual','お迎え','pickup','evening',sat,
    ((sat::text||' 18:00')::timestamp at time zone 'Asia/Tokyo'),
    u2,ar2,'person','legacy_snapshot','whole','todo','test',u1
  ) returning id into pickup_task;

  if (select assignment_mode from public.task_instances where id=sat_pm_task)<>'person'
     or (select planned_assignee_id from public.task_instances where id=sat_pm_task) is distinct from u2 then
    raise exception 'FAIL weekend anyone: live weekend pickup did not win';
  end if;

  update public.task_instances
  set status='cancelled',
      planned_assignee_id=null,
      planned_assignee_actor_ref_id=null,
      assignment_mode='unassigned',
      revision=revision+1
  where id=pickup_task;

  if (select assignment_mode from public.task_instances where id=sat_pm_task)<>'anyone'
     or (select planned_assignee_id from public.task_instances where id=sat_pm_task) is not null then
    raise exception 'FAIL weekend anyone: cancelled weekend pickup did not return to anyone';
  end if;

  if not exists(
    select 1 from public.task_events
    where task_instance_id=sat_am_task
      and event_type in ('assignment_claimed','assignment_takeover','assignment_released')
  ) then
    raise exception 'FAIL weekend anyone: claim audit missing';
  end if;
end;
$$;

rollback;
select 'weekend_role_tasks_anyone: PASS' as result;
