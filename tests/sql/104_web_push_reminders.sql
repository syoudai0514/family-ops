\set ON_ERROR_STOP on
begin;
set role service_role;
do $$
declare
 actor uuid:=gen_random_uuid(); partner uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid(); household uuid;
 sub jsonb; rejected boolean:=false; soon timestamptz:=now()+interval '20 minutes'; claimed record; n int;
 google_connection uuid; calendar_connection uuid; google_task uuid; push_endpoint text:='https://push.example.com/send/device-1';
begin
 insert into auth.users(id) values(actor),(partner),(outsider);
 household := (public.server_tx_create_household(actor,gen_random_uuid(),'Push test','Owner')->>'household_id')::uuid;
 insert into public.household_members(household_id,user_id,member_role) values(household,partner,'adult');
 insert into public.notification_preferences(household_id,user_id) values(household,partner) on conflict do nothing;
 perform public.server_tx_create_household(outsider,gen_random_uuid(),'Other','Other');

 -- Subscriptions are validated and tied to the actor's household.
 begin perform public.server_tx_upsert_web_push_subscription(actor,'http://insecure.example.com','x'||repeat('a',40),'auth-secret',null);
 exception when raise_exception then if sqlerrm='INVALID_INPUT' then rejected:=true; else raise; end if; end;
 if not rejected then raise exception 'FAIL non-https endpoint accepted'; end if;
 sub:=public.server_tx_upsert_web_push_subscription(actor,push_endpoint,'p'||repeat('a',86),'auth-secret-123','iPhone');
 if public.server_tx_upsert_web_push_subscription(actor,push_endpoint,'p'||repeat('b',86),'auth-secret-456','iPhone')->>'subscription_id'
   <>sub->>'subscription_id' then raise exception 'FAIL re-subscribe must update the same endpoint'; end if;
 if public.server_tx_get_web_push_subscription(outsider,push_endpoint) is not null then raise exception 'FAIL other user reads subscription'; end if;

 -- A reminder goes to the actor's device by push and skips LINE; the partner without push gets LINE.
 perform public.server_tx_save_scheduled_task(actor,gen_random_uuid(),null,null,jsonb_build_object(
   'title','歯医者','scheduled_date',(soon at time zone 'Asia/Tokyo')::date,
   'due_local_time',to_char(soon at time zone 'Asia/Tokyo','HH24:MI'),'completion_mode','whole','calendar_visibility','special',
   'scheduler_details',jsonb_build_object('reminders',jsonb_build_array(30))));
 if public.server_tx_dispatch_schedule_reminders(40)<>1 then raise exception 'FAIL reminder dispatch'; end if;
 if (select count(*) from private.web_push_outbox where recipient_user_id=actor and status='pending')<>1 then
   raise exception 'FAIL push not queued'; end if;
 if exists(select 1 from private.notification_outbox where recipient_user_id=actor and type='schedule_reminder') then
   raise exception 'FAIL LINE sent although the device gets push'; end if;
 if not exists(select 1 from private.notification_outbox where recipient_user_id=partner and type='schedule_reminder') then
   raise exception 'FAIL partner without push must still get LINE'; end if;

 -- Claim, then an expired endpoint (410) disables the subscription.
 select * into claimed from public.server_tx_claim_web_push_batch(10,60);
 if claimed.endpoint<>push_endpoint or claimed.title<>'歯医者' or claimed.url not like '/month?date=%' then
   raise exception 'FAIL claim payload: %',row_to_json(claimed); end if;
 if exists(select 1 from public.server_tx_claim_web_push_batch(10,60)) then raise exception 'FAIL double claim'; end if;
 perform public.server_tx_complete_web_push(claimed.outbox_id,'retry','503');
 if (select status from private.web_push_outbox where id=claimed.outbox_id)<>'pending' then raise exception 'FAIL retry'; end if;
 update private.web_push_outbox set next_attempt_at=now() where id=claimed.outbox_id;
 select * into claimed from public.server_tx_claim_web_push_batch(10,60);
 perform public.server_tx_complete_web_push(claimed.outbox_id,'gone','410');
 if (select disabled_at from private.web_push_subscriptions where web_push_subscriptions.endpoint=push_endpoint) is null then
   raise exception 'FAIL gone endpoint stays active'; end if;
 n:=public.server_tx_enqueue_web_push(household,actor,'t','b','/','tag','after-gone',now()+interval '1 hour');
 if n<>0 then raise exception 'FAIL disabled device still counted'; end if;

 -- Subscribing again revives it, and deleting removes only the actor's own endpoint.
 perform public.server_tx_upsert_web_push_subscription(actor,push_endpoint,'p'||repeat('c',86),'auth-secret-789',null);
 if (public.server_tx_get_web_push_subscription(actor,push_endpoint)->>'active')::boolean is not true then raise exception 'FAIL revive'; end if;
 if (public.server_tx_delete_web_push_subscription(outsider,push_endpoint)->>'deleted')::int<>0 then raise exception 'FAIL foreign delete'; end if;
 if (public.server_tx_delete_web_push_subscription(actor,push_endpoint)->>'deleted')::int<>1 then raise exception 'FAIL own delete'; end if;
 if has_function_privilege('authenticated','public.server_tx_enqueue_web_push(uuid,uuid,text,text,text,text,text,timestamptz)','execute') then
   raise exception 'FAIL push enqueue exposed to clients'; end if;

 -- reminder_channel=google: Google Calendar reminds while the family calendar is written there.
 insert into private.google_connections(household_id,owner_user_id,google_subject,encrypted_refresh_token,encryption_version,scopes,status)
 values(household,actor,'push-test','cipher',1,array['https://www.googleapis.com/auth/calendar.events'],'active') returning id into google_connection;
 insert into public.calendar_connections(household_id,external_calendar_id,google_connection_id,active)
 values(household,'push-test@group.calendar.google.com',google_connection,true) returning id into calendar_connection;
 perform public.server_tx_set_family_calendar_target(actor,gen_random_uuid(),calendar_connection);
 google_task:=(public.server_tx_save_scheduled_task(actor,gen_random_uuid(),null,null,jsonb_build_object(
   'title','面談','scheduled_date',(soon at time zone 'Asia/Tokyo')::date,
   'due_local_time',to_char(soon at time zone 'Asia/Tokyo','HH24:MI'),
   'calendar_end_local_time',to_char((soon+interval '5 minutes') at time zone 'Asia/Tokyo','HH24:MI'),
   'completion_mode','whole','calendar_visibility','special',
   'scheduler_details',jsonb_build_object('reminders',jsonb_build_array(30),'reminder_channel','google')))->>'task_id')::uuid;
 if public.server_tx_dispatch_schedule_reminders(40)<>0 then raise exception 'FAIL google-channel reminder also sent by the app'; end if;
 -- Disconnecting the family calendar must not silently drop the reminder.
 update public.calendar_connections set is_family_write_target=false where id=calendar_connection;
 if public.server_tx_dispatch_schedule_reminders(40)<>1 then raise exception 'FAIL fallback after Google disconnect'; end if;
 rejected:=false;
 begin
   perform public.server_tx_save_scheduled_task(actor,gen_random_uuid(),null,null,jsonb_build_object(
     'title','x','scheduled_date',(now() at time zone 'Asia/Tokyo')::date+3,'completion_mode','whole',
     'calendar_visibility','special','scheduler_details',jsonb_build_object('reminder_channel','email')));
 exception when raise_exception then if sqlerrm='INVALID_INPUT' then rejected:=true; else raise; end if; end;
 if not rejected then raise exception 'FAIL unknown reminder channel accepted'; end if;
end $$;
reset role;
rollback;
select 'web_push_reminders: PASS' as result;
