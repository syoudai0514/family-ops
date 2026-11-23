\set ON_ERROR_STOP on
begin;
set local role service_role;
do $$
declare a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); h uuid; token text; own uuid; own_b uuid; shared uuid; transport uuid; td uuid;
  day date:=(now() at time zone 'Asia/Tokyo')::date+1; dispatch_at timestamptz; body_a text; body_b text;
begin
  update public.households set morning_nudge_local_time=null;
  insert into auth.users(id) values(a),(b);
  h:=(public.server_tx_create_household(a,gen_random_uuid(),'nudge dispatch','A')->>'household_id')::uuid;
  token:=public.server_tx_create_household_invite(a,gen_random_uuid())->>'raw_token'; perform public.server_tx_join_household(b,gen_random_uuid(),token,'B');
  update public.notification_preferences set quiet_mode='normal' where household_id=h;
  while private.is_jp_nonworkday(day) loop day:=day+1; end loop;
  dispatch_at:=(day::timestamp+time '07:30') at time zone 'Asia/Tokyo';
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,planned_assignee_id,assignment_mode,completion_mode,status,source,created_by)
    values(h,'manual','本人の朝','household','morning',day,a,'person','whole','todo','test',a) returning id into own;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,planned_assignee_id,assignment_mode,completion_mode,status,source,created_by)
    values(h,'manual','相手の朝','household','morning',day,b,'person','whole','todo','test',a) returning id into own_b;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by)
    values(h,'manual','共通の朝','household','morning',day,'anyone','whole','todo','test',a) returning id into shared;
  select id into td from public.task_definitions where household_id=h and code='dropoff';
  insert into public.task_instances(household_id,task_definition_id,origin,title,category,routine_phase,scheduled_date,planned_assignee_id,assignment_mode,completion_mode,status,source,created_by)
    values(h,td,'manual','送り','household','morning',day,b,'person','whole','todo','test',a) returning id into transport;
  insert into public.task_events(household_id,task_instance_id,actor_id,event_type,source,created_at)
    values(h,own,a,'completed','pwa',dispatch_at-interval '1 hour');
  if public.server_tx_dispatch_morning_nudges(dispatch_at)<>1 then raise exception 'expected only recording user'; end if;
  select body into body_a from public.user_notifications where household_id=h and recipient_user_id=a and type='morning_nudge';
  if body_a not like '%まだのもの%' or body_a like '%朝の残り%' or body_a not like '%本人の朝%' or body_a not like '%共通の朝%'
    then raise exception 'first user nudge wrong: %',body_a; end if;
  if exists(select 1 from public.user_notifications where household_id=h and recipient_user_id=b and type='morning_nudge')
    then raise exception 'user with no record received nudge'; end if;
  insert into public.task_events(household_id,task_instance_id,actor_id,event_type,source,created_at)
    values(h,own_b,b,'completed','line',dispatch_at-interval '1 hour');
  if public.server_tx_dispatch_morning_nudges(dispatch_at)<>1 then raise exception 'second recording user did not get nudge'; end if;
  select body into body_b from public.user_notifications where household_id=h and recipient_user_id=b and type='morning_nudge';
  if body_b not like '%まだのもの%' or body_b not like '%相手の朝%' or body_b like '%共通の朝%'
    then raise exception 'second user nudge wrong: %',body_b; end if;
  if public.server_tx_dispatch_morning_nudges(dispatch_at+interval '1 minute')<>0 then raise exception 'duplicate nudge'; end if;
end $$;
reset role;
rollback;
select 'respectful_nudge_dispatch: PASS' as result;
