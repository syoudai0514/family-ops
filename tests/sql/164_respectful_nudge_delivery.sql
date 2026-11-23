\set ON_ERROR_STOP on
begin;
do $$
declare a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); h uuid; token text; own uuid; shared uuid; transport uuid; td uuid;
  day date:=(now() at time zone 'Asia/Tokyo')::date; actor_out uuid; bundle_out uuid; legacy_bundle uuid; empty_out uuid;
  suba uuid; subb uuid; pusha uuid; pushb uuid; rows jsonb; row jsonb; p record; found_push boolean:=false;
begin
  update private.notification_outbox set status='dead',lease_owner=null,lease_token=null,lease_until=null where status in ('queued','sending');
  update private.web_push_outbox set status='dead',lease_until=null where status in ('pending','processing');
  insert into auth.users(id) values(a),(b);
  h:=(public.server_tx_create_household(a,gen_random_uuid(),'nudge delivery','A')->>'household_id')::uuid;
  token:=public.server_tx_create_household_invite(a,gen_random_uuid())->>'raw_token'; perform public.server_tx_join_household(b,gen_random_uuid(),token,'B');
  update public.notification_preferences set quiet_mode='normal' where household_id=h;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,planned_assignee_id,assignment_mode,completion_mode,status,source,created_by)
    values(h,'manual','本人の朝','household','morning',day,a,'person','whole','todo','test',a) returning id into own;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by)
    values(h,'manual','共通の朝','household','morning',day,'anyone','whole','todo','test',a) returning id into shared;
  select id into td from public.task_definitions where household_id=h and code='dropoff';
  insert into public.task_instances(household_id,task_definition_id,origin,title,category,routine_phase,scheduled_date,planned_assignee_id,assignment_mode,completion_mode,status,source,created_by)
    values(h,td,'manual','送り','household','morning',day,b,'person','whole','todo','test',a) returning id into transport;
  insert into public.task_events(household_id,task_instance_id,actor_id,event_type,source,created_at)
    values(h,own,a,'completed','pwa',now()-interval '1 minute');
  insert into private.notification_outbox(household_id,recipient_user_id,channel,type,payload,dedup_key,priority,business_expires_at)
    values(h,a,'line','morning_nudge',jsonb_build_object('items',jsonb_build_array(
      jsonb_build_object('title','⏰ 朝の残り','body','古い内容'),jsonb_build_object('type','request.received','title','お願い','body','大切なお願い'))),
      'morning-nudge:'||day||':actor','normal',now()+interval '1 hour') returning id into actor_out;
  insert into private.notification_outbox(household_id,recipient_user_id,channel,type,payload,dedup_key,priority,business_expires_at)
    values(h,b,'line','morning_nudge',jsonb_build_object('items',jsonb_build_array(
      jsonb_build_object('title','⏰ 朝の残り','body','古い内容'),jsonb_build_object('type','request.received','title','お願い','body','別の大切なお願い'))),
      'morning-nudge:'||day||':bundle','normal',now()+interval '1 hour') returning id into bundle_out;
  insert into private.notification_outbox(household_id,recipient_user_id,channel,type,payload,dedup_key,priority,business_expires_at)
    values(h,b,'line','morning_nudge',jsonb_build_object('items',jsonb_build_array(
      jsonb_build_object('title','⏰ 朝の残り','body','古い内容'),jsonb_build_object('title','大事な知らせ','body','型のない大切な連絡'))),
      'morning-nudge:'||day||':legacy-bundle','normal',now()+interval '1 hour') returning id into legacy_bundle;
  insert into private.notification_outbox(household_id,recipient_user_id,channel,type,payload,dedup_key,priority,business_expires_at)
    values(h,b,'line','morning_nudge',jsonb_build_object('items',jsonb_build_array(jsonb_build_object('title','⏰ 朝の残り','body','古い内容'))),
      'morning-nudge:'||day||':empty','normal',now()+interval '1 hour') returning id into empty_out;
  insert into private.web_push_subscriptions(household_id,user_id,endpoint,p256dh,auth)
    values(h,a,'https://example.test/nudge-a',repeat('a',20),repeat('b',8)) returning id into suba;
  insert into private.web_push_subscriptions(household_id,user_id,endpoint,p256dh,auth)
    values(h,b,'https://example.test/nudge-b',repeat('a',20),repeat('b',8)) returning id into subb;
  insert into private.web_push_outbox(subscription_id,household_id,recipient_user_id,title,body,url,tag,dedup_key,expires_at)
    values(suba,h,a,'朝の残り','古い内容','/','morning-nudge','morning-nudge:'||day||':pusha',now()+interval '1 hour') returning id into pusha;
  insert into private.web_push_outbox(subscription_id,household_id,recipient_user_id,title,body,url,tag,dedup_key,expires_at)
    values(subb,h,b,'朝の残り','古い内容','/','morning-nudge','morning-nudge:'||day||':pushb',now()+interval '1 hour') returning id into pushb;
  rows:=public.server_tx_claim_notification_outbox_batch('nudge-test',20,60);
  select value into row from jsonb_array_elements(rows) where value->>'id'=actor_out::text;
  if row is null or row::text not like '%まだのもの%' or row::text like '%朝の残り%' or row::text like '%古い内容%'
    or row::text not like '%本人の朝%' or row::text not like '%共通の朝%' or row::text not like '%大切なお願い%'
    then raise exception 'recorded user nudge wrong: %',row; end if;
  select value into row from jsonb_array_elements(rows) where value->>'id'=bundle_out::text;
  if row is null or row->>'type'<>'request.received' or row::text like '%古い内容%' or row::text not like '%別の大切なお願い%'
    then raise exception 'unrecorded user request lost: %',row; end if;
  select value into row from jsonb_array_elements(rows) where value->>'id'=legacy_bundle::text;
  if row is null or row::text like '%古い内容%' or row::text not like '%型のない大切な連絡%'
    then raise exception 'legacy bundled notice lost: %',row; end if;
  if exists(select 1 from jsonb_array_elements(rows) where value->>'id'=empty_out::text)
    or (select status from private.notification_outbox where id=empty_out)<>'fallback' then raise exception 'no-recording nudge delivered'; end if;
  for p in select * from public.server_tx_claim_web_push_batch(20,60) loop
    if p.outbox_id=pushb then raise exception 'no-recording web push delivered'; end if;
    if p.outbox_id=pusha then
      found_push:=true;
      if p.title<>'まだのもの' or p.body not like '%本人の朝%' or p.body not like '%共通の朝%' then raise exception 'web push wrong: %',p; end if;
    end if;
  end loop;
  if not found_push or (select status from private.web_push_outbox where id=pushb)<>'dead' then raise exception 'push filtering failed'; end if;
end $$;
rollback;
select 'respectful_nudge_delivery: PASS' as result;
