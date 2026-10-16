\set ON_ERROR_STOP on
begin;
set role service_role;
do $$
declare
 actor uuid:=gen_random_uuid(); partner uuid:=gen_random_uuid(); household uuid; result jsonb; target uuid; revision int;
 rejected boolean:=false; soon timestamptz:=now()+interval '20 minutes'; payload jsonb; sent int;
begin
 insert into auth.users(id) values(actor),(partner);
 household := (public.server_tx_create_household(actor,gen_random_uuid(),'Reminder test','Owner')->>'household_id')::uuid;

 -- Two reminders that are both overdue (created late) send one message, the nearer one.
 payload:=jsonb_build_object('title','歯医者','scheduled_date',(soon at time zone 'Asia/Tokyo')::date,
   'due_local_time',to_char(soon at time zone 'Asia/Tokyo','HH24:MI'),'completion_mode','whole','calendar_visibility','special',
   'scheduler_details',jsonb_build_object('reminders',jsonb_build_array(1440,30),'location','駅前',
     'participants',jsonb_build_array(actor)));
 result:=public.server_tx_save_scheduled_task(actor,gen_random_uuid(),null,null,payload);
 target:=(result->>'task_id')::uuid;
 sent:=public.server_tx_dispatch_schedule_reminders(40);
 if sent<>1 then raise exception 'FAIL one dispatch for overdue reminders: %',sent; end if;
 if public.server_tx_dispatch_schedule_reminders(40)<>0 then raise exception 'FAIL reminders must not repeat'; end if;
 if (select count(*) from public.user_notifications where household_id=household and type='schedule_reminder')<>1 then
   raise exception 'FAIL exactly one in-app reminder'; end if;
 if not exists(select 1 from public.user_notifications where household_id=household and type='schedule_reminder'
   and (user_notifications.payload->>'offset_minutes')::int=30 and body like 'あと%分%歯医者%' and body like '%駅前%') then
   raise exception 'FAIL reminder text: %',(select body from public.user_notifications where household_id=household and type='schedule_reminder'); end if;

 -- Moving the start re-arms the reminder; editing only notes does not.
 select t.revision into revision from public.task_instances t where id=target;
 perform public.server_tx_save_scheduled_task(actor,gen_random_uuid(),target,revision,
   jsonb_set(payload,'{scheduler_details,notes}',to_jsonb('メモだけ'::text)));
 if public.server_tx_dispatch_schedule_reminders(40)<>0 then raise exception 'FAIL note edit resent reminder'; end if;
 select t.revision into revision from public.task_instances t where id=target;
 perform public.server_tx_save_scheduled_task(actor,gen_random_uuid(),target,revision,
   payload||jsonb_build_object('due_local_time',to_char((soon+interval '5 minutes') at time zone 'Asia/Tokyo','HH24:MI')));
 if (soon at time zone 'Asia/Tokyo')::date=((soon+interval '5 minutes') at time zone 'Asia/Tokyo')::date
   and public.server_tx_dispatch_schedule_reminders(40)<>1 then raise exception 'FAIL moved start must re-arm'; end if;

 -- Future reminders wait.
 payload:=jsonb_build_object('title','運動会','scheduled_date',(now() at time zone 'Asia/Tokyo')::date+5,
   'completion_mode','whole','calendar_visibility','special',
   'scheduler_details',jsonb_build_object('reminders',jsonb_build_array(780,1440)));
 perform public.server_tx_save_scheduled_task(actor,gen_random_uuid(),null,null,payload);
 if public.server_tx_dispatch_schedule_reminders(40)<>0 then raise exception 'FAIL future reminder fired'; end if;

 -- Unknown offsets and too many reminders are rejected.
 begin
   perform public.server_tx_save_scheduled_task(actor,gen_random_uuid(),null,null,
     jsonb_set(payload,'{scheduler_details,reminders}','[7]'::jsonb));
 exception when raise_exception then if sqlerrm='INVALID_INPUT' then rejected:=true; else raise; end if; end;
 if not rejected then raise exception 'FAIL unknown offset accepted'; end if;
 rejected:=false;
 begin
   perform public.server_tx_save_scheduled_task(actor,gen_random_uuid(),null,null,
     jsonb_set(payload,'{scheduler_details,reminders}','["30"]'::jsonb));
 exception when raise_exception then if sqlerrm='INVALID_INPUT' then rejected:=true; else raise; end if; end;
 if not rejected then raise exception 'FAIL non-number offset accepted'; end if;

 -- LINE / AI入力 create schedules without a form: they get the default reminder.
 result:=public.server_tx_create_task_with_calendar(p_actor_id=>actor,p_operation_id=>gen_random_uuid(),p_title=>'皮膚科',
   p_category=>'other',p_scheduled_date=>(now() at time zone 'Asia/Tokyo')::date+2,p_due_local_time=>'11:00'::time,
   p_calendar_end_local_time=>null,p_calendar_visibility=>'special',p_planned_assignee_user_id=>null,
   p_completion_mode=>'whole',p_routine_phase=>'anytime',p_subtasks=>null);
 if (select details->'reminders' from public.task_schedule_details where task_id=(result->>'task_id')::uuid)<>'[60]'::jsonb then
   raise exception 'FAIL timed default reminder'; end if;
 result:=public.server_tx_create_task_with_calendar(p_actor_id=>actor,p_operation_id=>gen_random_uuid(),p_title=>'遠足',
   p_category=>'other',p_scheduled_date=>(now() at time zone 'Asia/Tokyo')::date+2,p_due_local_time=>null,
   p_calendar_end_local_time=>null,p_calendar_visibility=>'special',p_planned_assignee_user_id=>null,
   p_completion_mode=>'whole',p_routine_phase=>'anytime',p_subtasks=>null);
 if (select details->'reminders' from public.task_schedule_details where task_id=(result->>'task_id')::uuid)<>'[780]'::jsonb then
   raise exception 'FAIL all-day default reminder'; end if;
 -- Hidden to-dos are not schedules and get no reminder.
 result:=public.server_tx_create_task_with_calendar(p_actor_id=>actor,p_operation_id=>gen_random_uuid(),p_title=>'洗濯',
   p_category=>'other',p_scheduled_date=>(now() at time zone 'Asia/Tokyo')::date,p_due_local_time=>null,
   p_calendar_end_local_time=>null,p_calendar_visibility=>'hidden',p_planned_assignee_user_id=>null,
   p_completion_mode=>'whole',p_routine_phase=>'anytime',p_subtasks=>null);
 if exists(select 1 from public.task_schedule_details where task_id=(result->>'task_id')::uuid) then
   raise exception 'FAIL hidden task got reminder'; end if;
 -- An explicit "通知しない" from the form replaces the default.
 payload:=jsonb_build_object('title','美容院','scheduled_date',(now() at time zone 'Asia/Tokyo')::date+3,'due_local_time','10:00',
   'completion_mode','whole','calendar_visibility','special','scheduler_details',jsonb_build_object('reminders','[]'::jsonb));
 result:=public.server_tx_save_scheduled_task(actor,gen_random_uuid(),null,null,payload);
 if public.schedule_reminder_offsets((select details from public.task_schedule_details where task_id=(result->>'task_id')::uuid))<>'{}'::int[] then
   raise exception 'FAIL explicit no reminder'; end if;
 -- Legacy scalar reminder_minutes still works.
 if public.schedule_reminder_offsets('{"reminder_minutes":10}'::jsonb)<>array[10] then raise exception 'FAIL legacy scalar'; end if;
end $$;
reset role;
rollback;
select 'schedule_multi_reminders: PASS' as result;
