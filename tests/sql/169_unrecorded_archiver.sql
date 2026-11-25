\set ON_ERROR_STOP on
begin;
do $$
declare
  a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); h uuid; token text; actor_ref uuid;
  ordinary uuid; protected uuid; transport uuid; dependent uuid; pickup_def uuid; laundry_def uuid; rule_id uuid;
  google_conn uuid; calendar_conn uuid; day date:=(now() at time zone 'Asia/Tokyo')::date-1;
  r jsonb; snap jsonb; before_dependent bigint; original_claimed_at timestamptz:=now()-interval '1 hour';
begin
  insert into auth.users(id) values(a),(b);
  h:=(public.server_tx_create_household(a,gen_random_uuid(),'archive primitive','A')->>'household_id')::uuid;
  token:=public.server_tx_create_household_invite(a,gen_random_uuid())->>'raw_token';
  perform public.server_tx_join_household(b,gen_random_uuid(),token,'B');
  select id into actor_ref from public.domain_actor_refs where household_id=h and actor_kind='real_user' and real_user_id=a;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,
    active_claimant_actor_ref_id,claimed_at,completion_mode,status,source,created_by)
    values(h,'recurring','未記録','household','morning',day,'anyone',actor_ref,original_claimed_at,'whole','todo','test',a)
    returning id into ordinary;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,
    completion_mode,status,source,created_by,attention_state)
    values(h,'recurring','返事待ち','household','morning',day,'unassigned','whole','todo','test',a,'waiting') returning id into protected;
  r:=private.fn_archive_unrecorded_routine_v1(h,ordinary,day+1,99);
  if r->>'reason'<>'stale' or (select status from public.task_instances where id=ordinary)<>'todo' then raise exception 'stale revision was changed'; end if;
  r:=private.fn_archive_unrecorded_routine_v1(h,protected,day+1,1);
  if r->>'reason'<>'protected' then raise exception 'waiting task archived: %',r; end if;
  r:=private.fn_archive_unrecorded_routine_v1(gen_random_uuid(),ordinary,day+1,1);
  if r->>'reason'<>'not_found' then raise exception 'cross-household task accessible'; end if;
  perform set_config('family_ops.unrecorded_archive_task','previous',true);
  r:=private.fn_archive_unrecorded_routine_v1(h,ordinary,day+1,1);
  if r->>'archived'<>'true' or (r->>'revision')::bigint<>2
    or current_setting('family_ops.unrecorded_archive_task',true)<>'previous' then raise exception 'archive failed or marker leaked: %',r; end if;
  select before_state into snap from private.unrecorded_routine_archives where household_id=h and task_id=ordinary and closed_revision=2;
  if snap->>'status'<>'todo' or (snap->>'active_claimant_actor_ref_id')::uuid<>actor_ref
    or (snap->>'claimed_at')::timestamptz<>original_claimed_at
    or not exists(select 1 from public.task_instances where id=ordinary and status='skipped' and outcome_reason='unrecorded'
      and active_claimant_actor_ref_id is null and claimed_at is null and revision=2) then raise exception 'archive lost source state: %',snap; end if;
  r:=private.fn_archive_unrecorded_routine_v1(h,ordinary,day+1,1);
  if r->>'archived'<>'true' or r->>'already_archived'<>'true' or (r->>'revision')::bigint<>2 then
    raise exception 'archive retry did not replay: %',r; end if;
  r:=private.fn_archive_unrecorded_routine_v1(h,ordinary,day+1,2);
  if r->>'archived'<>'false' or (select count(*) from private.unrecorded_routine_archives where task_id=ordinary)<>1 then
    raise exception 'repeated archive changed data'; end if;

  -- Use an actual family Google target and a dependent pickup rule. Transport
  -- must be excluded: later Google projections may read its state even when
  -- the archive transition itself did not enqueue a projection.
  while extract(isodow from day)::int>5 or private.fn_is_jp_holiday_v1(day) loop day:=day-1; end loop;
  insert into private.google_connections(household_id,owner_user_id,google_subject,encrypted_refresh_token,encryption_version,scopes,status)
    values(h,a,'archive-fixture','cipher',1,array['https://www.googleapis.com/auth/calendar.events'],'active') returning id into google_conn;
  insert into public.calendar_connections(household_id,provider,external_calendar_id,google_connection_id,active,reauth_required)
    values(h,'google','archive@example.invalid',google_conn,true,false) returning id into calendar_conn;
  perform public.server_tx_set_family_calendar_target(a,gen_random_uuid(),calendar_conn);
  select id into pickup_def from public.task_definitions where household_id=h and code='pickup';
  select id into laundry_def from public.task_definitions where household_id=h and code='laundry';
  insert into public.task_instances(household_id,task_definition_id,origin,title,category,routine_phase,scheduled_date,
    planned_assignee_id,planned_assignee_actor_ref_id,assignment_mode,assignment_source,completion_mode,status,source,created_by)
    values(h,pickup_def,'recurring','お迎え','pickup','evening',day,a,actor_ref,'person','legacy_snapshot','whole','todo','test',a)
    returning id into transport;
  insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,fallback_assignee_id,effective_from,created_by)
    values(h,laundry_def,extract(isodow from day)::int,'archive-test','pickup_assignee',b,day,a) returning id into rule_id;
  insert into public.task_instances(household_id,task_definition_id,recurrence_rule_id,origin,title,category,routine_phase,scheduled_date,
    planned_assignee_id,planned_assignee_actor_ref_id,assignment_mode,assignment_source,completion_mode,status,source,created_by)
    values(h,laundry_def,rule_id,'recurring','洗濯','household','evening',day,a,actor_ref,'person','legacy_snapshot','whole','todo','test',a)
    returning id into dependent;
  before_dependent:=(select revision from public.task_instances where id=dependent);
  delete from private.family_ops_calendar_mirrors where household_id=h;
  r:=private.fn_archive_unrecorded_routine_v1(h,transport,day+1,1);
  if r->>'reason'<>'protected' or exists(select 1 from private.family_ops_calendar_mirrors where household_id=h)
    or (select revision from public.task_instances where id=dependent)<>before_dependent
    or (select planned_assignee_id from public.task_instances where id=dependent) is distinct from a then
    raise exception 'protected transport was changed: %',r; end if;
  -- Independently exercise the narrow trigger guard with a synthetic direct
  -- transition. This does not make transport eligible for auto-close.
  perform set_config('family_ops.unrecorded_archive_task',transport::text,true);
  update public.task_instances set status='skipped',outcome_reason='unrecorded',revision=revision+1 where id=transport;
  perform set_config('family_ops.unrecorded_archive_task','previous',true);
  if exists(select 1 from private.family_ops_calendar_mirrors where household_id=h)
    or (select revision from public.task_instances where id=dependent)<>before_dependent then
    raise exception 'narrow archive transition triggered side effects'; end if;
  -- The transaction marker is restored: a real subsequent status change must
  -- still enqueue the projection and run transport reconciliation.
  update public.task_instances set status='todo',outcome_reason=null,revision=revision+1 where id=transport;
  if not exists(select 1 from private.family_ops_calendar_mirrors where household_id=h) then
    raise exception 'normal Google projection was suppressed'; end if;
  update public.task_instances set status='cancelled',revision=revision+1 where id=transport;
  if (select planned_assignee_id from public.task_instances where id=dependent) is distinct from b then
    raise exception 'normal transport reconciliation was suppressed'; end if;
  update public.task_instances set status='todo',revision=revision+1 where id=transport;
  delete from private.family_ops_calendar_mirrors where household_id=h;
  perform set_config('family_ops.unrecorded_archive_task',transport::text,true);
  update public.task_instances set status='skipped',outcome_reason='unrecorded',title='変更されたお迎え',revision=revision+1 where id=transport;
  if not exists(select 1 from private.family_ops_calendar_mirrors where household_id=h)
    or (select planned_assignee_id from public.task_instances where id=dependent) is distinct from b then
    raise exception 'marker incorrectly suppressed a simultaneous non-archive edit'; end if;
  if has_function_privilege('authenticated','private.fn_archive_unrecorded_routine_v1(uuid,uuid,date,bigint)','execute')
    or has_function_privilege('service_role','private.fn_archive_unrecorded_routine_v1(uuid,uuid,date,bigint)','execute') then
    raise exception 'internal archive primitive exposed'; end if;
end $$;
rollback;
select 'unrecorded_archiver: PASS' as result;
