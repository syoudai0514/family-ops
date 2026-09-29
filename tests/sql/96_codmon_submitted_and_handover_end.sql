-- Owner decisions 2026-09-30:
--  * "コドモンを送信した" closes the Codmon job in one step, even when the
--    input tasks were never ticked in the app. The final-send guard itself is
--    unchanged: completing codmon_submit directly is still refused.
--  * The author of a handover can end it; nobody else can.
\set ON_ERROR_STOP on

begin;
set role service_role;

do $$
declare
  u1 uuid:=gen_random_uuid();   -- papa: dropoff / breakfast / submit
  u2 uuid:=gen_random_uuid();   -- mama: pickup inputs, yesterday's dinner
  hh uuid;
  ar1 uuid;
  ar2 uuid;
  pickup_def uuid;
  dropoff_def uuid;
  workday date;
  submit_task uuid;
  other_task uuid;
  op uuid:=gen_random_uuid();
  result jsonb;
  replay jsonb;
  readiness jsonb;
  n int;
  ho uuid;
  ended jsonb;
  brief jsonb;
  rule_id uuid;
begin
  insert into auth.users(id) values(u1),(u2);
  hh:=(public.server_tx_create_household(u1,gen_random_uuid(),'codmon submitted','Owner')->>'household_id')::uuid;
  insert into public.household_members(household_id,user_id,member_role,family_role) values(hh,u2,'adult','mama');
  update public.household_members set family_role='papa' where household_id=hh and user_id=u1;
  perform private.backfill_canonical_foundation_v1();
  select id into ar1 from public.domain_actor_refs where household_id=hh and actor_kind='real_user' and real_user_id=u1;
  select id into ar2 from public.domain_actor_refs where household_id=hh and actor_kind='real_user' and real_user_id=u2;
  select id into pickup_def from public.task_definitions where household_id=hh and code='pickup';
  select id into dropoff_def from public.task_definitions where household_id=hh and code='dropoff';

  select min(d::date) into workday
  from generate_series((now() at time zone 'Asia/Tokyo')::date+1,(now() at time zone 'Asia/Tokyo')::date+21,interval '1 day') d
  where extract(isodow from d)::int between 1 and 5 and not private.fn_is_nonworkday(d::date);

  insert into public.task_instances(household_id,task_definition_id,origin,title,category,routine_phase,
    scheduled_date,due_at,planned_assignee_id,planned_assignee_actor_ref_id,assignment_mode,assignment_source,
    completion_mode,status,source,created_by)
  values
    (hh,dropoff_def,'manual','送り','transport','morning',workday,((workday::text||' 08:00')::timestamp at time zone 'Asia/Tokyo'),
     u1,ar1,'person','legacy_snapshot','whole','todo','test',u1),
    (hh,pickup_def,'manual','お迎え','transport','evening',workday,((workday::text||' 18:20')::timestamp at time zone 'Asia/Tokyo'),
     u2,ar2,'person','legacy_snapshot','whole','todo','test',u1);
  -- Yesterday's pickup was mama, so "yesterday's dinner" follows her.
  insert into public.task_instances(household_id,task_definition_id,origin,title,category,routine_phase,
    scheduled_date,due_at,planned_assignee_id,planned_assignee_actor_ref_id,assignment_mode,assignment_source,
    completion_mode,status,actual_completed_by_id,completed_at,source,created_by)
  values (hh,pickup_def,'manual','お迎え','transport','evening',workday-1,
    (((workday-1)::text||' 18:20')::timestamp at time zone 'Asia/Tokyo'),
    u2,ar2,'person','legacy_snapshot','whole','completed',u2,now(),'test',u1);

  perform private.fn_seed_codmon_daily_for_household_v1(hh,workday);
  -- The seed only writes recurrence rules; materialize the day like the 00:10 worker.
  for rule_id in
    select rr.id from public.recurrence_rules rr
    join public.task_definitions td on td.household_id=rr.household_id and td.id=rr.task_definition_id
    where rr.household_id=hh and td.code like 'codmon_%' and td.code not like 'codmon_test_%'
      and rr.weekday=extract(isodow from workday)::int and rr.active
  loop
    perform private.materialize_recurrence_rule(hh,rule_id,workday,workday);
  end loop;

  readiness:=private.fn_codmon_readiness_v1(hh,workday,null);
  if readiness->>'state'<>'waiting_inputs' then
    raise exception 'FAIL 96: expected waiting_inputs before acknowledgement, got %',readiness->>'state';
  end if;
  submit_task:=(readiness->>'submit_task_id')::uuid;
  select id into other_task from public.task_instances where household_id=hh and scheduled_date=workday and title='送り';

  -- The guard is unchanged: completing the submit task directly is refused.
  begin
    perform public.server_tx_complete_task(u1,gen_random_uuid(),submit_task,'self',true,'line');
    raise exception 'FAIL 96: direct submit completion must still be guarded';
  exception when others then
    if sqlerrm<>'CODMON_INPUTS_INCOMPLETE' then raise; end if;
  end;

  -- Acknowledging a non-Codmon task through the Codmon command is refused.
  begin
    perform public.server_tx_acknowledge_codmon_submission_v1(u1,gen_random_uuid(),other_task,'line');
    raise exception 'FAIL 96: non-codmon task accepted';
  exception when others then
    if sqlerrm<>'INVALID_INPUT' then raise; end if;
  end;

  -- One acknowledgement closes every open input and the submit task.
  result:=public.server_tx_acknowledge_codmon_submission_v1(u1,op,submit_task,'line');
  if (result->>'inputs_closed')::int<>4 then
    raise exception 'FAIL 96: expected 4 inputs closed, got %',result;
  end if;
  readiness:=private.fn_codmon_readiness_v1(hh,workday,null);
  if readiness->>'state'<>'acknowledged' then
    raise exception 'FAIL 96: expected acknowledged after the command, got %',readiness->>'state';
  end if;
  select count(*) into n from public.task_instances where id=submit_task and status='completed';
  if n<>1 then raise exception 'FAIL 96: submit task not completed'; end if;

  -- Inputs are recorded as done by their planned assignee.
  select count(*) into n
  from jsonb_array_elements(readiness->'inputs') i
  join public.task_instances t on t.id=(i->>'task_id')::uuid
  where t.status='completed' and t.actual_completed_by_id is not distinct from nullif(i->>'assignee_user_id','')::uuid;
  if n<>4 then raise exception 'FAIL 96: inputs not attributed to their assignees (% of 4)',n; end if;
  select count(*) into n from public.task_instances t
  where t.id=submit_task and t.actual_completed_by_id=u1;
  if n<>1 then raise exception 'FAIL 96: submit not attributed to the sender'; end if;

  -- A retried acknowledgement (same operation id) replays; nothing is redone.
  select count(*) into n from public.task_events e where e.task_instance_id=submit_task;
  replay:=public.server_tx_acknowledge_codmon_submission_v1(u1,op,submit_task,'line');
  if (select count(*) from public.task_events e where e.task_instance_id=submit_task)<>n then
    raise exception 'FAIL 96: replay produced new submit events';
  end if;

  -- A second, different acknowledgement of an already-sent day says so.
  begin
    perform public.server_tx_acknowledge_codmon_submission_v1(u2,gen_random_uuid(),submit_task,'pwa');
    raise exception 'FAIL 96: second acknowledgement accepted';
  exception when others then
    if sqlerrm<>'TASK_TERMINAL' then raise; end if;
  end;

  -- Handover end (§8.2 クリア): any adult of the household, not only the author.
  -- Status becomes expired, the row stays, and it leaves everyone's brief.
  ho:=(public.server_tx_create_handover(u1,gen_random_uuid(),'【言語通級】テスト','day',array['general'],workday)->>'handover_id')::uuid;
  if ho is null then
    select id into ho from public.handovers where household_id=hh and shared_text='【言語通級】テスト';
  end if;

  brief:=public.server_read_daily_brief_base_v1(u2,workday);
  if not exists (
    select 1 from jsonb_array_elements(coalesce(brief->'active_infos',brief->'handovers','[]'::jsonb)) i
    where i->>'handover_id'=ho::text
  ) then
    raise exception 'FAIL 96: precondition -- the new handover is not in the partner''s brief (keys: %)',
      (select string_agg(k,',') from jsonb_object_keys(brief) k);
  end if;

  begin
    perform public.server_tx_end_handover(gen_random_uuid(),gen_random_uuid(),ho);
    raise exception 'FAIL 96: an outsider ended a handover';
  exception when others then
    if sqlerrm<>'NOT_HOUSEHOLD_MEMBER' then raise; end if;
  end;

  -- mama (not the author) clears papa's note.
  op:=gen_random_uuid();
  ended:=public.server_tx_end_handover(u2,op,ho);
  if ended->>'status'<>'expired' then raise exception 'FAIL 96: end_handover result %',ended; end if;
  if (select status from public.handovers where id=ho)<>'expired' then
    raise exception 'FAIL 96: handover not expired';
  end if;
  if public.server_tx_end_handover(u2,op,ho)<>ended then
    raise exception 'FAIL 96: end_handover replay differs';
  end if;

  brief:=public.server_read_daily_brief_base_v1(u2,workday);
  if exists (
    select 1 from jsonb_array_elements(coalesce(brief->'active_infos',brief->'handovers','[]'::jsonb)) i
    where i->>'handover_id'=ho::text
  ) then
    raise exception 'FAIL 96: ended handover still in the daily brief';
  end if;
  if exists (
    select 1 from jsonb_array_elements(coalesce(public.server_read_daily_brief_base_v1(u1,workday)->'active_infos','[]'::jsonb)) i
    where i->>'handover_id'=ho::text
  ) then
    raise exception 'FAIL 96: ended handover still in the author''s brief';
  end if;
  if (select count(*) from public.handovers where id=ho)<>1 then
    raise exception 'FAIL 96: ended handover must stay as history';
  end if;
end;
$$;

rollback;
\echo 'PASS 96: codmon submitted closes inputs + submit; any adult can end a handover'
