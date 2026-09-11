-- F2 regression: a `担当未定` Today item must have a complete LINE action path.
-- Self/anyone resolve immediately; partner assignment stays unassigned until
-- the partner accepts the canonical Request; an active request replaces the
-- duplicate `担当未定` nag in DailyBrief.
\set ON_ERROR_STOP on

begin;
set role service_role;

do $$
declare
  u uuid := gen_random_uuid();
  v uuid := gen_random_uuid();
  hh uuid;
  d date := (now() at time zone 'Asia/Tokyo')::date;
  ar uuid;
  br uuid;
  t_self uuid;
  t_any uuid;
  t_partner uuid;
  op uuid;
  c jsonb;
  replay jsonb;
  req uuid;
  attempt uuid;
  brief jsonb;
  result jsonb;
begin
  insert into auth.users(id) values(u),(v);
  hh := (public.server_tx_create_household(u, gen_random_uuid(), 'F2 assignment test', 'Owner')->>'household_id')::uuid;
  insert into public.household_members(household_id,user_id,member_role)
  values(hh,v,'adult');
  update public.household_members set family_role='papa' where household_id=hh and user_id=u;
  update public.household_members set family_role='mama' where household_id=hh and user_id=v;
  perform private.backfill_canonical_foundation_v1();
  select id into ar from public.domain_actor_refs where household_id=hh and actor_kind='real_user' and real_user_id=u;
  select id into br from public.domain_actor_refs where household_id=hh and actor_kind='real_user' and real_user_id=v;
  if ar is null or br is null then raise exception 'FAIL f2-line-assignment: actor refs missing'; end if;

  insert into public.task_instances(
    household_id,origin,title,category,routine_phase,scheduled_date,due_at,
    planned_assignee_id,completion_mode,status,source,created_by,
    assignment_mode,assignment_source,planned_assignee_actor_ref_id
  ) values (
    hh,'manual','朝の着替え準備','other','morning',d,(d::timestamp + time '08:00') at time zone 'Asia/Tokyo',
    null,'whole','todo','f2_line_assignment',u,'unassigned','manual',null
  ) returning id into t_self;

  op := gen_random_uuid();
  c := public.server_tx_line_assign_unassigned_task_v1(u,op,t_self,'self',1);
  replay := public.server_tx_line_assign_unassigned_task_v1(u,op,t_self,'self',1);
  if c is distinct from replay
     or (select assignment_mode from public.task_instances where id=t_self) <> 'person'
     or (select planned_assignee_actor_ref_id from public.task_instances where id=t_self) is distinct from ar
     or (select planned_assignee_id from public.task_instances where id=t_self) is distinct from u
     or (select revision from public.task_instances where id=t_self) <> 2
     or (select count(*) from public.task_events where task_instance_id=t_self and source='line' and event_type='assignment_changed') <> 1 then
    raise exception 'FAIL f2-line-assignment: self choice was not canonical/idempotent';
  end if;

  insert into public.task_instances(
    household_id,origin,title,category,routine_phase,scheduled_date,due_at,
    planned_assignee_id,completion_mode,status,source,created_by,
    assignment_mode,assignment_source,planned_assignee_actor_ref_id
  ) values (
    hh,'manual','牛乳を買う','other','anytime',d,(d::timestamp + time '12:00') at time zone 'Asia/Tokyo',
    null,'whole','todo','f2_line_assignment',u,'unassigned','manual',null
  ) returning id into t_any;

  c := public.server_tx_line_assign_unassigned_task_v1(u,gen_random_uuid(),t_any,'anyone',1);
  if (select assignment_mode from public.task_instances where id=t_any) <> 'anyone'
     or (select planned_assignee_actor_ref_id from public.task_instances where id=t_any) is not null
     or (select planned_assignee_id from public.task_instances where id=t_any) is not null then
    raise exception 'FAIL f2-line-assignment: anyone choice did not remain claimant-based';
  end if;

  insert into public.task_instances(
    household_id,origin,title,category,routine_phase,scheduled_date,due_at,
    planned_assignee_id,completion_mode,status,source,created_by,
    assignment_mode,assignment_source,planned_assignee_actor_ref_id
  ) values (
    hh,'manual','子どもの着替え準備','other','evening',d,(d::timestamp + time '20:00') at time zone 'Asia/Tokyo',
    null,'whole','todo','f2_line_assignment',u,'unassigned','manual',null
  ) returning id into t_partner;

  op := gen_random_uuid();
  c := public.server_tx_line_request_unassigned_task_assignment_v1(u,op,t_partner,1);
  replay := public.server_tx_line_request_unassigned_task_assignment_v1(u,op,t_partner,1);
  req := (c->>'request_id')::uuid;
  attempt := (c->>'attempt_id')::uuid;
  if c is distinct from replay
     or c->>'state' <> 'pending'
     or c->>'recipient_role' <> 'mama'
     or (select planned_assignee_actor_ref_id from public.task_instances where id=t_partner) is not null
     or (select assignment_mode from public.task_instances where id=t_partner) <> 'unassigned'
     or (select request_kind from public.requests where id=req) <> 'assignment_change'
     or (select assignment_task_instance_id from public.requests where id=req) is distinct from t_partner
     or (select state from public.request_attempts where id=attempt) <> 'pending' then
    raise exception 'FAIL f2-line-assignment: partner request silently assigned or lost request state';
  end if;

  brief := public.server_read_daily_brief(u,d);
  if not exists (
    select 1
    from jsonb_array_elements(coalesce(brief->'urgent_actions','[]'::jsonb)) x
    where x->>'task_id'=t_partner::text
      and x->>'kind'='assignment_negotiation'
      and x->>'request_id'=req::text
      and x->>'title' like '%ママにお願い中%'
      and x->>'state'='pending'
  ) then
    raise exception 'FAIL f2-line-assignment: Today did not show partner request state: %', brief->'urgent_actions';
  end if;
  if exists (
    select 1
    from jsonb_array_elements(coalesce(brief->'urgent_actions','[]'::jsonb)) x
    where x->>'task_id'=t_partner::text and x->>'kind'='assignment_needed'
  ) then
    raise exception 'FAIL f2-line-assignment: active request still duplicated as 担当未定';
  end if;

  result := public.server_tx_transition_request_v2(
    v,gen_random_uuid(),req,attempt,'accept',null,1,1,'line'
  );
  if result->>'state' <> 'accepted'
     or (select planned_assignee_actor_ref_id from public.task_instances where id=t_partner) is distinct from br
     or (select planned_assignee_id from public.task_instances where id=t_partner) is distinct from v
     or (select assignment_source from public.task_instances where id=t_partner) <> 'agreement' then
    raise exception 'FAIL f2-line-assignment: partner acceptance did not assign exact Task';
  end if;

  brief := public.server_read_daily_brief(u,d);
  if exists (
    select 1
    from jsonb_array_elements(coalesce(brief->'urgent_actions','[]'::jsonb)) x
    where x->>'task_id'=t_partner::text
      and x->>'kind' in ('assignment_needed','assignment_negotiation')
  ) then
    raise exception 'FAIL f2-line-assignment: accepted Task remained in assignment decision UX';
  end if;
end;
$$;

rollback;
select 'f2_line_unassigned_assignment_actions: PASS' as result;
