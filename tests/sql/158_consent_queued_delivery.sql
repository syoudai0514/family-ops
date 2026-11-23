\set ON_ERROR_STOP on
begin;
do $$
declare a uuid:=gen_random_uuid(); b uuid:=gen_random_uuid(); h uuid; token text; d uuid; rule_id uuid; task_id uuid;
  note uuid; daily_out uuid; nudge_out uuid; bundle_out uuid; sub uuid; push_out uuid; other_push uuid; offer uuid;
  rows jsonb; row jsonb; p record; count_push int; today date:=(now() at time zone 'Asia/Tokyo')::date; key text;
begin
  -- Isolate this test from other outbox fixtures in the SQL suite.
  update private.notification_outbox set status='dead',lease_owner=null,lease_token=null,lease_until=null where status in ('queued','sending');
  update private.web_push_outbox set status='dead',lease_until=null where status in ('pending','processing');
  insert into auth.users(id) values(a),(b);
  h:=(public.server_tx_create_household(a,gen_random_uuid(),'queued consent','A')->>'household_id')::uuid;
  token:=public.server_tx_create_household_invite(a,gen_random_uuid())->>'raw_token'; perform public.server_tx_join_household(b,gen_random_uuid(),token,'B');
  -- This is the normal-delivery consent regression; automatic quiet delivery
  -- has its own coverage in 160_automatic_quiet_delivery.sql.
  update public.notification_preferences set quiet_mode='normal' where household_id=h;
  insert into public.task_definitions(household_id,code,title,category,routine_phase,completion_mode,created_by)
    values(h,'queued_test','仮の作業','household','morning','whole',a) returning id into d;
  insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,planned_assignee_id,effective_from,created_by)
    values(h,d,extract(isodow from today)::int,'queued','fixed',b,today,a) returning id into rule_id;
  insert into public.task_instances(household_id,task_definition_id,recurrence_rule_id,origin,title,category,routine_phase,scheduled_date,
    planned_assignee_id,assignment_mode,completion_mode,status,source,created_by,due_at)
    values(h,d,rule_id,'recurring','仮の作業','household','morning',today,b,'person','whole','todo','test',a,
      (today::timestamp+time '08:00') at time zone 'Asia/Tokyo') returning id into task_id;
  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
    values(h,b,'daily_brief.v2','朝のおうちノート','古い本文 仮の作業',jsonb_build_object('brief',jsonb_build_object('local_date',today,
      'display_recipient_user_id',b,'schedule',jsonb_build_array(jsonb_build_object('title','共通の予定')),
      'own_task_groups',jsonb_build_object('morning',jsonb_build_array(jsonb_build_object('task_id',task_id,'title','仮の作業',
        'display_title','仮の作業','assignment_mode','person')),'daytime','[]'::jsonb,'evening','[]'::jsonb,'optional','[]'::jsonb))),
      'queued-old-note') returning id into note;
  insert into private.notification_outbox(household_id,recipient_user_id,channel,type,payload,dedup_key,priority,business_expires_at)
    values(h,b,'line','daily_brief.v2',jsonb_build_object('items',jsonb_build_array(
      jsonb_build_object('type','daily_brief.v2','title','朝のおうちノート','body','古い本文 仮の作業','user_notification_id',note),
      jsonb_build_object('type','request.received','title','お願い','body','大切なお願い'))),
      'queued-daily','normal',now()+interval '1 hour') returning id into daily_out;
  key:='morning-nudge:'||today::text||':'||b::text;
  insert into private.notification_outbox(household_id,recipient_user_id,channel,type,payload,dedup_key,priority,business_expires_at)
    values(h,b,'line','morning_nudge',jsonb_build_object('items',jsonb_build_array(jsonb_build_object('title','朝の残り','body','仮の作業'))),
      key,'reminder',now()+interval '1 hour') returning id into nudge_out;
  insert into private.notification_outbox(household_id,recipient_user_id,channel,type,payload,dedup_key,priority,business_expires_at)
    values(h,b,'line','morning_nudge',jsonb_build_object('items',jsonb_build_array(jsonb_build_object('title','朝の残り','body','仮の作業'),
      jsonb_build_object('type','request.received','title','お願い','body','別の大切なお願い'))),
      'morning-nudge:'||today::text||':bundle','normal',now()+interval '1 hour') returning id into bundle_out;
  insert into private.web_push_subscriptions(household_id,user_id,endpoint,p256dh,auth) values(h,b,'https://example.test/push',repeat('a',20),repeat('b',8)) returning id into sub;
  insert into private.web_push_outbox(subscription_id,household_id,recipient_user_id,title,body,url,tag,dedup_key,expires_at)
    values(sub,h,b,'朝の残り','仮の作業','/','morning-nudge',key,now()+interval '1 hour') returning id into push_out;
  insert into private.web_push_outbox(subscription_id,household_id,recipient_user_id,title,body,url,tag,dedup_key,expires_at)
    values(sub,h,b,'予定','守るべき他の通知','/','calendar','other',now()+interval '1 hour') returning id into other_push;
  rows:=public.server_tx_claim_notification_outbox_batch('test',20,60);
  select value into row from jsonb_array_elements(rows) where value->>'id'=daily_out::text;
  if row::text like '%仮の作業%' or row::text not like '%大切なお願い%' or row::text not like '%共通の予定%' then raise exception 'old daily note was not safely rewritten: %',row; end if;
  if exists(select 1 from jsonb_array_elements(rows) where value->>'id'=nudge_out::text)
    or (select status from private.notification_outbox where id=nudge_out)<>'fallback' then raise exception 'empty nudge delivered'; end if;
  select value into row from jsonb_array_elements(rows) where value->>'id'=bundle_out::text;
  if row::text like '%仮の作業%' or row::text not like '%別の大切なお願い%' then raise exception 'bundled important notice lost: %',row; end if;
  count_push:=0;
  for p in select * from public.server_tx_claim_web_push_batch(20,60) loop
    if p.outbox_id=push_out then raise exception 'unsafe push delivered'; end if;
    if p.outbox_id=other_push and p.body='守るべき他の通知' then count_push:=count_push+1; end if;
  end loop;
  if count_push<>1 or (select status from private.web_push_outbox where id=push_out)<>'dead' then raise exception 'push filtering lost another notice'; end if;
  -- Once the person agrees, the same work can appear in a newly claimed nudge.
  offer:=(public.server_tx_prepare_assignment_consent_v1(b,'rule',rule_id)->>'offer_id')::uuid;
  perform public.server_tx_accept_assignment_consent_v1(b,offer);
  insert into private.notification_outbox(household_id,recipient_user_id,channel,type,payload,dedup_key,priority,business_expires_at)
    values(h,b,'line','morning_nudge',jsonb_build_object('items',jsonb_build_array(jsonb_build_object('title','朝の残り','body','古い本文'))),
      'morning-nudge:'||today::text||':new','reminder',now()+interval '1 hour') returning id into nudge_out;
  rows:=public.server_tx_claim_notification_outbox_batch('test2',20,60);
  select value into row from jsonb_array_elements(rows) where value->>'id'=nudge_out::text;
  if row::text not like '%仮の作業%' or row::text like '%古い本文%' then raise exception 'agreed nudge not refreshed: %',row; end if;
end $$;
rollback;
select 'consent_queued_delivery: PASS' as result;
