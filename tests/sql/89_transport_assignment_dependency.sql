-- F2: transport assignment agreement must re-resolve same-day role-derived
-- routine tasks without overwriting protected agreements.
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
  dinner_def uuid;
  cleaning_def uuid;
  bath_def uuid;
  prep_def uuid;
  pickup_task uuid;
  dropoff_task uuid;
  dinner_task uuid;
  cleaning_task uuid;
  bath_task uuid;
  prep_task uuid;
  chosen_date date:=(now() at time zone 'Asia/Tokyo')::date + 1;
  dow int;
  c jsonb;
  req uuid;
  attempt uuid;
  r jsonb;
begin
  insert into auth.users(id) values(u1),(u2);
  hh:=(public.server_tx_create_household(u1,gen_random_uuid(),'transport dependent F2','Owner')->>'household_id')::uuid;
  insert into public.household_members(household_id,user_id,member_role)
  values(hh,u2,'adult');

  perform private.backfill_canonical_foundation_v1();

  select id into ar1
  from public.domain_actor_refs
  where household_id=hh and actor_kind='real_user' and real_user_id=u1;

  select id into ar2
  from public.domain_actor_refs
  where household_id=hh and actor_kind='real_user' and real_user_id=u2;

  select id into pickup_def from public.task_definitions where household_id=hh and code='pickup';
  select id into dropoff_def from public.task_definitions where household_id=hh and code='dropoff';
  select id into dinner_def from public.task_definitions where household_id=hh and code='dinner';
  select id into cleaning_def from public.task_definitions where household_id=hh and code='cleaning';
  select id into bath_def from public.task_definitions where household_id=hh and code='bath';
  select id into prep_def from public.task_definitions where household_id=hh and code='prep_tuesday_gym';

  if pickup_def is null or dropoff_def is null or dinner_def is null
     or cleaning_def is null or bath_def is null or prep_def is null then
    raise exception 'FAIL transport dependency: seeded task definitions missing';
  end if;

  dow:=extract(isodow from chosen_date)::int;

  -- Current transport occurrences are owned by u1.
  insert into public.task_instances(
    household_id,task_definition_id,origin,title,category,routine_phase,scheduled_date,due_at,
    planned_assignee_id,completion_mode,status,source,created_by,assignment_mode,
    assignment_source,planned_assignee_actor_ref_id
  ) values(
    hh,pickup_def,'recurring','お迎え','pickup','evening',chosen_date,
    ((chosen_date::text||' 18:20')::timestamp at time zone 'Asia/Tokyo'),
    u1,'whole','todo','test',u1,'person','legacy_snapshot',ar1
  ) returning id into pickup_task;

  insert into public.task_instances(
    household_id,task_definition_id,origin,title,category,routine_phase,scheduled_date,due_at,
    planned_assignee_id,completion_mode,status,source,created_by,assignment_mode,
    assignment_source,planned_assignee_actor_ref_id
  ) values(
    hh,dropoff_def,'recurring','送り','dropoff','morning',chosen_date,
    ((chosen_date::text||' 08:00')::timestamp at time zone 'Asia/Tokyo'),
    u1,'whole','todo','test',u1,'person','legacy_snapshot',ar1
  ) returning id into dropoff_task;

  -- Materialize explicit role-derived routines against the original transport owners.
  perform public.server_tx_change_recurrence(
    u1,gen_random_uuid(),dinner_def,dow,'default','pickup_assignee',null,'19:00',60,chosen_date
  );
  perform public.server_tx_change_recurrence(
    u1,gen_random_uuid(),cleaning_def,dow,'default','nonpickup_adult',null,'20:00',60,chosen_date
  );
  perform public.server_tx_change_recurrence(
    u1,gen_random_uuid(),bath_def,dow,'default','pickup_assignee',null,'20:10',60,chosen_date
  );
  perform public.server_tx_change_recurrence(
    u1,gen_random_uuid(),prep_def,dow,'default','dropoff_assignee',null,'07:20',60,chosen_date
  );

  select id into dinner_task from public.task_instances
  where household_id=hh and task_definition_id=dinner_def and scheduled_date=chosen_date and status='todo'
  order by created_at limit 1;
  select id into cleaning_task from public.task_instances
  where household_id=hh and task_definition_id=cleaning_def and scheduled_date=chosen_date and status='todo'
  order by created_at limit 1;
  select id into bath_task from public.task_instances
  where household_id=hh and task_definition_id=bath_def and scheduled_date=chosen_date and status='todo'
  order by created_at limit 1;
  select id into prep_task from public.task_instances
  where household_id=hh and task_definition_id=prep_def and scheduled_date=chosen_date and status='todo'
  order by created_at limit 1;

  if (select planned_assignee_id from public.task_instances where id=dinner_task) is distinct from u1 then
    raise exception 'FAIL transport dependency: pickup_assignee did not initially follow pickup';
  end if;
  if (select planned_assignee_id from public.task_instances where id=cleaning_task) is distinct from u2 then
    raise exception 'FAIL transport dependency: nonpickup_adult did not initially resolve to other adult';
  end if;
  if (select planned_assignee_id from public.task_instances where id=prep_task) is distinct from u1 then
    raise exception 'FAIL transport dependency: dropoff_assignee did not initially follow dropoff';
  end if;

  -- Protect bath with an explicit agreement; transport dependency must not overwrite it.
  update public.task_instances
  set assignment_source='agreement',
      planned_assignee_id=u1,
      planned_assignee_actor_ref_id=ar1,
      revision=revision+1
  where id=bath_task;

  -- One-off pickup agreement u1 -> u2.
  c:=public.server_tx_create_assignment_change_request(
    u1,gen_random_uuid(),pickup_task,u2,'今日のお迎えお願いできる？','once'
  );
  req:=(c->>'request_id')::uuid;
  attempt:=(c->>'attempt_id')::uuid;

  r:=public.server_tx_transition_request_v2(
    u2,gen_random_uuid(),req,attempt,'accept',null,1,1,'line'
  );

  if r->>'state'<>'accepted' then
    raise exception 'FAIL transport dependency: pickup assignment request not accepted';
  end if;
  if (select planned_assignee_id from public.task_instances where id=pickup_task) is distinct from u2 then
    raise exception 'FAIL transport dependency: pickup did not move to recipient';
  end if;
  if (select planned_assignee_id from public.task_instances where id=dinner_task) is distinct from u2 then
    raise exception 'FAIL transport dependency: pickup_assignee routine did not follow accepted pickup';
  end if;
  if (select planned_assignee_actor_ref_id from public.task_instances where id=dinner_task) is distinct from ar2 then
    raise exception 'FAIL transport dependency: pickup_assignee actor ref did not follow accepted pickup';
  end if;
  if (select planned_assignee_id from public.task_instances where id=cleaning_task) is distinct from u1 then
    raise exception 'FAIL transport dependency: nonpickup_adult did not flip after pickup agreement';
  end if;
  if (select planned_assignee_id from public.task_instances where id=bath_task) is distinct from u1
     or (select assignment_source from public.task_instances where id=bath_task)<>'agreement' then
    raise exception 'FAIL transport dependency: protected agreement was overwritten';
  end if;
  if not exists(
    select 1 from public.task_events
    where task_instance_id=dinner_task
      and event_type='edited'
      and payload->>'reason'='transport_role_dependency'
      and payload->>'request_id'=req::text
  ) then
    raise exception 'FAIL transport dependency: dependent reassignment history missing';
  end if;

  -- One-off dropoff agreement u1 -> u2 must likewise move dropoff_assignee prep.
  c:=public.server_tx_create_assignment_change_request(
    u1,gen_random_uuid(),dropoff_task,u2,'明日の送りお願いできる？','once'
  );
  req:=(c->>'request_id')::uuid;
  attempt:=(c->>'attempt_id')::uuid;

  r:=public.server_tx_transition_request_v2(
    u2,gen_random_uuid(),req,attempt,'accept',null,1,1,'line'
  );

  if r->>'state'<>'accepted' then
    raise exception 'FAIL transport dependency: dropoff assignment request not accepted';
  end if;
  if (select planned_assignee_id from public.task_instances where id=prep_task) is distinct from u2 then
    raise exception 'FAIL transport dependency: dropoff_assignee routine did not follow accepted dropoff';
  end if;

  -- Basic recurrence rules remain role-based; a one-off agreement must not rewrite them.
  if exists(
    select 1
    from public.recurrence_rules
    where household_id=hh
      and id in (
        select recurrence_rule_id from public.task_instances
        where id in (dinner_task,cleaning_task,bath_task,prep_task)
      )
      and assignee_strategy not in ('pickup_assignee','nonpickup_adult','dropoff_assignee')
  ) then
    raise exception 'FAIL transport dependency: one-off agreement rewrote recurrence strategy';
  end if;
end;
$$;

rollback;
select 'transport_assignment_dependency: PASS' as result;
