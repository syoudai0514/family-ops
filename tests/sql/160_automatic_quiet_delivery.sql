\set ON_ERROR_STOP on
begin;
do $$
declare a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); h uuid; token text; task uuid; note uuid; nudge uuid; transport_def uuid; transport_rule uuid;
  daily_out uuid; legacy_out uuid; bundle_out uuid; nudge_out uuid; critical_note uuid; sub uuid; push_id uuid; rows jsonb; row jsonb;
  today date:=(now() at time zone 'Asia/Tokyo')::date; weekday date:=date '2026-11-24'; sunday date:=date '2026-11-29'; rendered text;
begin
  update private.notification_outbox set status='dead',lease_owner=null,lease_token=null,lease_until=null where status in ('queued','sending');
  update private.web_push_outbox set status='dead',lease_until=null where status in ('pending','processing');
  insert into auth.users(id) values(a),(b);
  h:=(public.server_tx_create_household(a,gen_random_uuid(),'quiet delivery','A')->>'household_id')::uuid;
  token:=public.server_tx_create_household_invite(a,gen_random_uuid())->>'raw_token'; perform public.server_tx_join_household(b,gen_random_uuid(),token,'B');
  update public.notification_preferences set quiet_mode='normal' where household_id=h;
  -- Old notes were queued before the setting changed.
  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
    values(h,b,'daily_brief.v2','朝のおうちノート','古い担当一覧',jsonb_build_object('brief',jsonb_build_object('local_date',weekday)),
      'autoquiet-old') returning id into note;
  insert into private.notification_outbox(household_id,recipient_user_id,channel,type,payload,dedup_key,priority,business_expires_at)
    values(h,b,'line','daily_brief.v2',jsonb_build_object('items',jsonb_build_array(
      jsonb_build_object('type','daily_brief.v2','title','朝のおうちノート','body','古い担当一覧','user_notification_id',note),
      jsonb_build_object('type','request.received','title','お願い','body','大切なお願い'))),
      'autoquiet-daily','normal',now()+interval '1 hour') returning id into daily_out;
  insert into private.notification_outbox(household_id,recipient_user_id,channel,type,payload,dedup_key,priority,business_expires_at)
    values(h,b,'line','daily_brief.v2',jsonb_build_object('items',jsonb_build_array(
      jsonb_build_object('title','朝のおうちノート','body','古い担当一覧','user_notification_id',note))),
      'autoquiet-legacy-daily','normal',now()+interval '1 hour') returning id into legacy_out;
  insert into private.notification_outbox(household_id,recipient_user_id,channel,type,payload,dedup_key,priority,business_expires_at)
    values(h,b,'line','morning_nudge',jsonb_build_object('items',jsonb_build_array(
      jsonb_build_object('title','朝の残り','body','古い担当一覧'),
      jsonb_build_object('type','request.received','title','お願い','body','別の大切なお願い'))),
      'morning-nudge:'||today::text||':autoquiet','normal',now()+interval '1 hour') returning id into bundle_out;
  insert into private.web_push_subscriptions(household_id,user_id,endpoint,p256dh,auth)
    values(h,b,'https://example.test/autoquiet',repeat('a',20),repeat('b',8)) returning id into sub;
  insert into private.web_push_outbox(subscription_id,household_id,recipient_user_id,title,body,url,tag,dedup_key,expires_at)
    values(sub,h,b,'朝の残り','古い担当一覧','/','morning-nudge','morning-nudge:'||today::text||':autoquiet',now()+interval '1 hour') returning id into push_id;
  update public.notification_preferences set quiet_mode='quiet' where household_id=h and user_id=b;
  if private.fn_quiet_morning_text_v1(h,b,weekday) is not null then raise exception 'empty day was not empty'; end if;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by,calendar_visibility)
    values(h,'manual','家族の予定','other','anytime',weekday,'anyone','whole','todo','pwa',a,'special') returning id into task;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,assignment_mode,completion_mode,status,source,created_by,calendar_visibility)
    values(h,'manual','来週の予定','other','anytime',sunday+1,'anyone','whole','todo','pwa',a,'special');
  select id into transport_def from public.task_definitions where household_id=h and code='dropoff';
  insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,planned_assignee_id,effective_from,created_by)
    values(h,transport_def,extract(isodow from weekday)::integer,'autoquiet-test','fixed',b,weekday,a) returning id into transport_rule;
  insert into public.task_instances(household_id,task_definition_id,recurrence_rule_id,origin,title,category,routine_phase,scheduled_date,
    planned_assignee_id,assignment_mode,completion_mode,status,source,created_by)
    values(h,transport_def,transport_rule,'recurring','送り','household','morning',weekday,b,'person','whole','todo','test',a);
  insert into public.requests(household_id,requester_id,recipient_id,shared_title,status) values(h,a,b,'お迎えをお願い','pending');
  rendered:=private.fn_quiet_morning_text_v1(h,b,weekday);
  if rendered not like '%家族の予定%' or rendered not like '%お迎えをお願い%' or rendered like '%残り%' or rendered like '%忘れずに%' then
    raise exception 'unexpected quiet morning %',rendered; end if;
  if rendered not like '%送り 相談中%' then raise exception 'unagreed transport was presented as agreed: %',rendered; end if;
  rendered:=private.fn_quiet_morning_text_v1(h,b,sunday);
  if rendered not like '%来週の予定%' or rendered like '%お迎えをお願い%' then raise exception 'unexpected Sunday %',rendered; end if;
  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
    values(h,b,'daily_brief.v2','朝のおうちノート','元の担当一覧',jsonb_build_object('brief',jsonb_build_object('local_date',weekday)),
      'autoquiet-new-morning') returning id into nudge;
  if nudge is null or (select body from public.user_notifications where id=nudge) like '%元の担当一覧%'
    or (select body from public.user_notifications where id=nudge) not like '%家族の予定%'
    then raise exception 'new quiet morning not rewritten'; end if;
  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
    values(h,b,'daily_brief.v2','夜のおうちノート','夜の催促',jsonb_build_object('brief',jsonb_build_object('local_date',weekday)),
      'autoquiet-evening') returning id into nudge;
  if nudge is not null then raise exception 'quiet evening was inserted'; end if;
  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
    values(h,b,'morning_nudge','朝の残り','催促','{}','autoquiet-nudge') returning id into nudge;
  if nudge is not null then raise exception 'quiet nudge was inserted'; end if;
  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
    values(h,b,'codmon.deadline','コドモン','催促','{}','autoquiet-codmon') returning id into nudge;
  if nudge is not null then raise exception 'quiet Codmon reminder was inserted'; end if;
  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
    values(h,a,'morning_nudge','朝の残り','通常の催促','{}','normal-nudge') returning id into nudge;
  if nudge is null then raise exception 'other member normal reminder suppressed'; end if;
  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key,safety_class)
    values(h,b,'morning_nudge','安全','重要','{}','autoquiet-critical','safety_critical') returning id into critical_note;
  if critical_note is null then raise exception 'critical notification suppressed'; end if;
  rows:=public.server_tx_claim_notification_outbox_batch('autoquiet-test',20,60);
  select value into row from jsonb_array_elements(rows) where value->>'id'=daily_out::text;
  if row::text like '%古い担当一覧%' or row::text not like '%家族の予定%' or row::text not like '%大切なお願い%'
    or row#>>'{payload,items,0,quiet_mode}'<>'true' then raise exception 'old note was not rewritten %',row; end if;
  select value into row from jsonb_array_elements(rows) where value->>'id'=legacy_out::text;
  if row::text like '%古い担当一覧%' or row::text not like '%家族の予定%'
    or row#>>'{payload,items,0,quiet_mode}'<>'true' then raise exception 'legacy note was not rewritten %',row; end if;
  select value into row from jsonb_array_elements(rows) where value->>'id'=bundle_out::text;
  if row::text like '%古い担当一覧%' or row::text not like '%別の大切なお願い%' or row->>'type'<>'request.received'
    then raise exception 'bundled request lost %',row; end if;
  if exists(select 1 from public.server_tx_claim_web_push_batch(20,60) where outbox_id=push_id)
    then raise exception 'quiet push delivered'; end if;
  if (select status from private.web_push_outbox where id=push_id)<>'dead'
    then raise exception 'quiet push remained pending'; end if;
end $$;
rollback;
select 'automatic_quiet_delivery: PASS' as result;
