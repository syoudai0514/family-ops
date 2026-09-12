-- F2 regression: role-derived routines converge when transport disappears.
-- Live transport wins; explicit fallback is used only when role cannot resolve;
-- no fallback remains unassigned; protected occurrences are not overwritten.
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
  laundry_def uuid;
  cleaning_def uuid;
  pickup_task uuid;
  laundry_task uuid;
  cleaning_task uuid;
  chosen_date date;
  dow int;
  rule_laundry uuid;
  rule_cleaning uuid;
begin
  insert into auth.users(id) values(u1),(u2);
  hh:=(public.server_tx_create_household(u1,gen_random_uuid(),'transport fallback F2','Owner')->>'household_id')::uuid;
  insert into public.household_members(household_id,user_id,member_role)
  values(hh,u2,'adult');
  update public.household_members set family_role='papa' where household_id=hh and user_id=u1;
  update public.household_members set family_role='mama' where household_id=hh and user_id=u2;
  perform private.backfill_canonical_foundation_v1();

  select id into ar1 from public.domain_actor_refs
  where household_id=hh and actor_kind='real_user' and real_user_id=u1;
  select id into ar2 from public.domain_actor_refs
  where household_id=hh and actor_kind='real_user' and real_user_id=u2;

  select id into pickup_def from public.task_definitions where household_id=hh and code='pickup';
  select id into laundry_def from public.task_definitions where household_id=hh and code='laundry';
  select id into cleaning_def from public.task_definitions where household_id=hh and code='cleaning';
  if pickup_def is null or laundry_def is null or cleaning_def is null then
    raise exception 'FAIL transport fallback: required definitions missing';
  end if;

  chosen_date:=(now() at time zone 'Asia/Tokyo')::date;
  dow:=extract(isodow from chosen_date)::int;

  insert into public.task_instances(
    household_id,task_definition_id,origin,title,category,routine_phase,scheduled_date,due_at,
    planned_assignee_id,planned_assignee_actor_ref_id,assignment_mode,assignment_source,
    completion_mode,status,source,created_by
  ) values(
    hh,pickup_def,'recurring','お迎え','pickup','evening',chosen_date,
    ((chosen_date::text||' 18:20')::timestamp at time zone 'Asia/Tokyo'),
    u1,ar1,'person','legacy_snapshot','whole','todo','test',u1
  ) returning id into pickup_task;

  rule_laundry:=(public.server_tx_change_recurrence(
    u1,gen_random_uuid(),laundry_def,dow,'default','pickup_assignee',
    u2,'20:30',60,chosen_date
  )->>'rule_id')::uuid;

  if (select fallback_assignee_id from public.recurrence_rules where id=rule_laundry) is distinct from u2
     or (select planned_assignee_id from public.recurrence_rules where id=rule_laundry) is not null then
    raise exception 'FAIL transport fallback: role rule did not store explicit fallback';
  end if;

  select id into laundry_task
  from public.task_instances
  where household_id=hh and recurrence_rule_id=rule_laundry and scheduled_date=chosen_date
  limit 1;

  if laundry_task is null
     or (select planned_assignee_id from public.task_instances where id=laundry_task) is distinct from u1 then
    raise exception 'FAIL transport fallback: live pickup did not win over fallback';
  end if;

  -- No fallback: when transport is unavailable, fail closed to unassigned.
  rule_cleaning:=(public.server_tx_change_recurrence(
    u1,gen_random_uuid(),cleaning_def,dow,'default','pickup_assignee',
    null,'20:00',60,chosen_date
  )->>'rule_id')::uuid;
  select id into cleaning_task
  from public.task_instances
  where household_id=hh and recurrence_rule_id=rule_cleaning and scheduled_date=chosen_date
  limit 1;
  if cleaning_task is null
     or (select planned_assignee_id from public.task_instances where id=cleaning_task) is distinct from u1 then
    raise exception 'FAIL transport fallback: live pickup did not resolve no-fallback rule';
  end if;

  -- Pickup disappears: fallback task -> u2; no-fallback task -> unassigned.
  update public.task_instances
  set status='cancelled',
      planned_assignee_id=null,
      planned_assignee_actor_ref_id=null,
      assignment_mode='unassigned',
      revision=revision+1
  where id=pickup_task;

  if (select planned_assignee_id from public.task_instances where id=laundry_task) is distinct from u2
     or (select assignment_mode from public.task_instances where id=laundry_task)<>'person' then
    raise exception 'FAIL transport fallback: cancelled pickup did not use explicit fallback';
  end if;
  if (select planned_assignee_id from public.task_instances where id=cleaning_task) is not null
     or (select assignment_mode from public.task_instances where id=cleaning_task)<>'unassigned' then
    raise exception 'FAIL transport fallback: no-fallback task did not fail closed';
  end if;
  if not exists(
    select 1 from public.task_events
    where task_instance_id=laundry_task
      and event_type='edited'
      and payload->>'reason'='transport_role_fallback_reconcile'
      and payload->>'fallback_assignee_user_id'=u2::text
  ) then
    raise exception 'FAIL transport fallback: audit missing';
  end if;

  -- Restoring a previously unresolved leg re-resolves both tasks to live truth.
  update public.task_instances
  set status='todo',
      planned_assignee_id=u1,
      planned_assignee_actor_ref_id=ar1,
      assignment_mode='person',
      revision=revision+1
  where id=pickup_task;

  if (select planned_assignee_id from public.task_instances where id=laundry_task) is distinct from u1
     or (select planned_assignee_id from public.task_instances where id=cleaning_task) is distinct from u1 then
    raise exception 'FAIL transport fallback: restored pickup did not regain precedence';
  end if;

  -- Protected occurrence must remain untouched when transport disappears again.
  update public.task_instances
  set assignment_source='agreement',
      planned_assignee_id=u1,
      planned_assignee_actor_ref_id=ar1,
      assignment_mode='person',
      revision=revision+1
  where id=laundry_task;

  update public.task_instances
  set status='cancelled',
      planned_assignee_id=null,
      planned_assignee_actor_ref_id=null,
      assignment_mode='unassigned',
      revision=revision+1
  where id=pickup_task;

  if (select planned_assignee_id from public.task_instances where id=laundry_task) is distinct from u1
     or (select assignment_source from public.task_instances where id=laundry_task)<>'agreement' then
    raise exception 'FAIL transport fallback: protected agreement was overwritten';
  end if;
end;
$$;

rollback;
select 'transport_role_fallback_resolution: PASS' as result;
