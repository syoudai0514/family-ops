\set ON_ERROR_STOP on
begin;
do $$
declare a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); h uuid; token text; own uuid; shared uuid; transport uuid; td uuid; rule uuid; actor_ref uuid;
  day date:=(now() at time zone 'Asia/Tokyo')::date; result text; at_time timestamptz:=now();
begin
  insert into auth.users(id) values(a),(b);
  h:=(public.server_tx_create_household(a,gen_random_uuid(),'nudge scope','A')->>'household_id')::uuid;
  token:=public.server_tx_create_household_invite(a,gen_random_uuid())->>'raw_token'; perform public.server_tx_join_household(b,gen_random_uuid(),token,'B');
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,planned_assignee_id,assignment_mode,completion_mode,status,source,created_by)
    values(h,'manual','本人の朝','household','morning',day,a,'person','whole','todo','test',a) returning id into own;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by)
    values(h,'manual','共通の朝','household','morning',day,'anyone','whole','todo','test',a) returning id into shared;
  if private.fn_morning_nudge_lines_v2(h,a,day,at_time) is not null then raise exception 'no recording still got nudge'; end if;
  insert into public.task_events(household_id,task_instance_id,actor_id,event_type,source,created_at) values
    (h,own,a,'created','pwa',at_time-interval '1 hour'),
    (h,own,a,'completed','scheduler',at_time-interval '1 hour'),
    (h,own,a,'completed','pwa',at_time+interval '1 hour');
  if private.fn_morning_nudge_lines_v2(h,a,day,at_time) is not null then raise exception 'creation, automation or future event counted'; end if;
  insert into public.task_events(household_id,task_instance_id,actor_id,event_type,source,created_at)
    values(h,own,a,'completed','pwa',at_time-interval '8 days');
  if private.fn_morning_nudge_lines_v2(h,a,day,at_time) is not null then raise exception 'expired recording counted'; end if;
  insert into public.task_events(household_id,task_instance_id,actor_id,event_type,source,created_at)
    values(h,own,a,'completed','pwa',at_time-interval '1 day');
  result:=private.fn_morning_nudge_lines_v2(h,a,day,at_time);
  if result not like '%本人の朝%' or result like '%共通の朝%' then raise exception 'unknown dropoff scope: %',result; end if;
  if private.fn_morning_nudge_lines_v2(h,b,day,at_time) is not null then raise exception 'other user record counted'; end if;
  select id into td from public.task_definitions where household_id=h and code='dropoff';
  insert into public.task_instances(household_id,task_definition_id,origin,title,category,routine_phase,scheduled_date,planned_assignee_id,assignment_mode,completion_mode,status,source,created_by)
    values(h,td,'manual','送り','household','morning',day,b,'person','whole','todo','test',a) returning id into transport;
  result:=private.fn_morning_nudge_lines_v2(h,a,day,at_time);
  if result not like '%本人の朝%' or result not like '%共通の朝%' then raise exception 'first departure missing: %',result; end if;
  insert into public.task_events(household_id,task_instance_id,actor_id,event_type,source,created_at)
    values(h,transport,b,'completed','line',at_time-interval '1 day');
  result:=private.fn_morning_nudge_lines_v2(h,b,day,at_time);
  if result like '%共通の朝%' or result not like '%送り%' then raise exception 'shared work assigned to both: %',result; end if;
  insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,planned_assignee_id,effective_from,created_by)
    values(h,td,extract(isodow from day)::integer,'nudge-test','fixed',b,day,a) returning id into rule;
  update public.task_instances set recurrence_rule_id=rule,origin='recurring' where id=transport;
  result:=private.fn_morning_nudge_lines_v2(h,a,day,at_time);
  if result like '%共通の朝%' then raise exception 'unagreed dropoff was treated as definite: %',result; end if;
  select id into actor_ref from public.domain_actor_refs where household_id=h and real_user_id=a and test_context_id is null;
  update public.task_instances set active_claimant_actor_ref_id=actor_ref,claimed_at=at_time where id=shared;
  result:=private.fn_morning_nudge_lines_v2(h,a,day,at_time);
  if result not like '%共通の朝%' then raise exception 'self-claimed shared work omitted: %',result; end if;
  result:=private.fn_morning_nudge_lines_v2(h,b,day,at_time);
  if result like '%共通の朝%' then raise exception 'someone else’s claimed work was shown: %',result; end if;
  if has_function_privilege('authenticated','private.fn_morning_nudge_lines_v2(uuid,uuid,date,timestamp with time zone)','EXECUTE') then raise exception 'private function exposed'; end if;
end $$;
rollback;
select 'respectful_nudge_scope: PASS' as result;
