\set ON_ERROR_STOP on
begin;
set role service_role;
do $$
declare
 actor uuid:=gen_random_uuid(); household uuid; result jsonb; rejected boolean:=false; op uuid:=gen_random_uuid();
 soon timestamptz:=now()+interval '20 minutes';
begin
 insert into auth.users(id) values(actor);
 household := (public.server_tx_create_household(actor,gen_random_uuid(),'Settings test','Owner')->>'household_id')::uuid;
 if (select default_timed_reminders from public.households where id=household)<>'[60]'::jsonb then raise exception 'FAIL default timed'; end if;

 -- The household default follows LINE / AI入力 schedules.
 result:=public.server_tx_update_reminder_settings(actor,op,'{"default_timed_reminders":[30,1440],"default_all_day_reminders":[1440]}');
 if public.server_tx_update_reminder_settings(actor,op,'{"default_timed_reminders":[30,1440],"default_all_day_reminders":[1440]}')<>result then
   raise exception 'FAIL idempotent settings'; end if;
 result:=public.server_tx_create_task_with_calendar(p_actor_id=>actor,p_operation_id=>gen_random_uuid(),p_title=>'歯医者',
   p_category=>'other',p_scheduled_date=>(now() at time zone 'Asia/Tokyo')::date+2,p_due_local_time=>'11:00'::time,
   p_calendar_end_local_time=>null,p_calendar_visibility=>'special',p_planned_assignee_user_id=>null,
   p_completion_mode=>'whole',p_routine_phase=>'anytime',p_subtasks=>null);
 if (select details->'reminders' from public.task_schedule_details where task_id=(result->>'task_id')::uuid)<>'[30,1440]'::jsonb then
   raise exception 'FAIL household timed default not applied'; end if;
 result:=public.server_tx_create_task_with_calendar(p_actor_id=>actor,p_operation_id=>gen_random_uuid(),p_title=>'遠足',
   p_category=>'other',p_scheduled_date=>(now() at time zone 'Asia/Tokyo')::date+2,p_due_local_time=>null,
   p_calendar_end_local_time=>null,p_calendar_visibility=>'special',p_planned_assignee_user_id=>null,
   p_completion_mode=>'whole',p_routine_phase=>'anytime',p_subtasks=>null);
 if (select details->'reminders' from public.task_schedule_details where task_id=(result->>'task_id')::uuid)<>'[1440]'::jsonb then
   raise exception 'FAIL household all-day default not applied'; end if;

 begin perform public.server_tx_update_reminder_settings(actor,gen_random_uuid(),'{"default_timed_reminders":[7]}');
 exception when raise_exception then if sqlerrm='INVALID_INPUT' then rejected:=true; else raise; end if; end;
 if not rejected then raise exception 'FAIL invalid default accepted'; end if;
 rejected:=false;
 begin perform public.server_tx_update_reminder_settings(actor,gen_random_uuid(),'{"calendar_line":false}');
 exception when raise_exception then if sqlerrm='INVALID_INPUT' then rejected:=true; else raise; end if; end;
 if not rejected then raise exception 'FAIL unknown setting accepted'; end if;

 -- With schedule_line_with_push the reminder goes to the device and to LINE.
 perform public.server_tx_upsert_web_push_subscription(actor,'https://web.push.apple.com/settings-test','p'||repeat('a',86),'auth-secret-123',null);
 perform public.server_tx_update_reminder_settings(actor,gen_random_uuid(),'{"schedule_line_with_push":true}');
 perform public.server_tx_save_scheduled_task(actor,gen_random_uuid(),null,null,jsonb_build_object(
   'title','面談','scheduled_date',(soon at time zone 'Asia/Tokyo')::date,
   'due_local_time',to_char(soon at time zone 'Asia/Tokyo','HH24:MI'),'completion_mode','whole','calendar_visibility','special',
   'scheduler_details',jsonb_build_object('reminders',jsonb_build_array(30))));
 if public.server_tx_dispatch_schedule_reminders(40)<1 then raise exception 'FAIL dispatch'; end if;
 if not exists(select 1 from private.web_push_outbox where recipient_user_id=actor)
   or not exists(select 1 from private.notification_outbox where recipient_user_id=actor and type='schedule_reminder') then
   raise exception 'FAIL push and LINE both expected'; end if;
end $$;
reset role;
rollback;
select 'reminder_settings: PASS' as result;
