\set ON_ERROR_STOP on
begin;
set role service_role;
do $$
declare
 actor uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid(); household uuid; other_household uuid;
 operation uuid:=gen_random_uuid(); target uuid; payload jsonb; result jsonb; revision int; google_connection uuid; calendar_connection uuid; mirror jsonb; rejected boolean:=false;
 scheduled date := (now() at time zone 'Asia/Tokyo')::date+3;
begin
 insert into auth.users(id) values(actor),(outsider);
 household := (public.server_tx_create_household(actor,gen_random_uuid(),'Scheduler test','Owner')->>'household_id')::uuid;
 other_household := (public.server_tx_create_household(outsider,gen_random_uuid(),'Other scheduler','Other')->>'household_id')::uuid;
 payload:=jsonb_build_object('title','園のお知らせ','scheduled_date',scheduled,'due_local_time','09:00','calendar_end_local_time','08:00',
   'calendar_visibility','special','completion_mode','whole','scheduler_details',jsonb_build_object(
     'ends_on',scheduled+1,'notes','長いお知らせを保存','location','公園','url','https://example.com/notice','label_color','#28b78d',
     'participants',jsonb_build_array(actor),'checklist',jsonb_build_array('水筒','帽子'),'repeat_frequency','weekly','repeat_until',scheduled+14));
 result:=public.server_tx_save_scheduled_task(actor,operation,null,null,payload);
 target:=(result->>'task_id')::uuid;
 if (result->>'count')::int<>3 then raise exception 'FAIL weekly materialization: %',result; end if;
 if public.server_tx_save_scheduled_task(actor,operation,null,null,payload)<>result then raise exception 'FAIL idempotent scheduler save'; end if;
 if not exists(select 1 from public.task_instances where id=target and calendar_ends_at=(scheduled+1+time '08:00') at time zone 'Asia/Tokyo') then raise exception 'FAIL cross-day end'; end if;
 begin
   perform public.server_tx_save_scheduled_task(actor,operation,null,null,payload||jsonb_build_object('title','changed'));
 exception when raise_exception then if sqlerrm='IDEMPOTENCY_CONFLICT' then rejected:=true; else raise; end if; end;
 if not rejected then raise exception 'FAIL changed retry'; end if;
 select t.revision into revision from public.task_instances t where id=target;
 rejected:=false;
 begin perform public.server_tx_save_scheduled_task(outsider,gen_random_uuid(),target,revision,payload);
 exception when raise_exception then if sqlerrm='CROSS_HOUSEHOLD_RESOURCE' then rejected:=true; else raise; end if; end;
 if not rejected then raise exception 'FAIL cross-household edit'; end if;
 rejected:=false;
 begin perform public.server_tx_save_scheduled_task(actor,gen_random_uuid(),target,revision-1,payload);
 exception when raise_exception then if sqlerrm='AGGREGATE_REVISION_CONFLICT' then rejected:=true; else raise; end if; end;
 if not rejected then raise exception 'FAIL stale edit'; end if;
 perform public.server_tx_save_scheduled_task(actor,gen_random_uuid(),target,revision,payload||jsonb_build_object('title','この回の更新'));
 if (select count(*) from public.task_instances where household_id=household and title='園のお知らせ')<>2 then raise exception 'FAIL edit must not duplicate or modify other occurrences'; end if;
 perform public.server_tx_complete_task(actor,gen_random_uuid(),target,'self',false,'pwa');
 select t.revision into revision from public.task_instances t where id=target;
 perform public.server_tx_save_scheduled_task(actor,gen_random_uuid(),target,revision,payload||jsonb_build_object('title','完了後メモも編集'));
 if not exists(select 1 from public.task_instances where id=target and status='completed' and actual_completed_by_id=actor) then raise exception 'FAIL edits retain actuals'; end if;
 -- Shared-calendar writes carry the rich scheduler fields too.
 insert into private.google_connections(household_id,owner_user_id,google_subject,encrypted_refresh_token,encryption_version,scopes,status)
 values(household,actor,'scheduler-test','cipher',1,array['https://www.googleapis.com/auth/calendar.events'],'active') returning id into google_connection;
 insert into public.calendar_connections(household_id,external_calendar_id,google_connection_id,active)
 values(household,'scheduler-test@group.calendar.google.com',google_connection,true) returning id into calendar_connection;
 perform public.server_tx_set_family_calendar_target(actor,gen_random_uuid(),calendar_connection);
 delete from private.family_ops_calendar_mirrors where household_id=household;
 -- An all-day interval is readable even when it began before the month.
 payload:=jsonb_build_object('title','旅行','scheduled_date',scheduled,'completion_mode','whole','calendar_visibility','special','scheduler_details',jsonb_build_object('ends_on',scheduled+2));
 result:=public.server_tx_save_scheduled_task(actor,gen_random_uuid(),null,null,payload);
 if not exists(select 1 from public.task_instances where id=(result->>'task_id')::uuid and due_at is null and calendar_ends_at>(scheduled+2)::timestamp at time zone 'Asia/Tokyo') then raise exception 'FAIL all-day interval'; end if;
 mirror:=public.server_tx_claim_family_ops_calendar_mirror('scheduler-test',120);
 if mirror->'event'->'end'->>'date'<>(scheduled+3)::text then raise exception 'FAIL Google all-day end: %',mirror; end if;
 -- Ready reminders use the existing queue and cannot be dispatched twice.
 payload:=jsonb_build_object('title','開始前のお知らせ','scheduled_date',((now()+interval '20 minutes') at time zone 'Asia/Tokyo')::date,
   'due_local_time',to_char((now()+interval '20 minutes') at time zone 'Asia/Tokyo','HH24:MI'), 'completion_mode','whole',
   'scheduler_details',jsonb_build_object('reminder_minutes',30,'participants',jsonb_build_array(actor)));
 result:=public.server_tx_save_scheduled_task(actor,gen_random_uuid(),null,null,payload);
 if public.server_tx_dispatch_schedule_reminders(40)<>1 or public.server_tx_dispatch_schedule_reminders(40)<>0 then raise exception 'FAIL reminder exactly once'; end if;
 if not exists(select 1 from public.user_notifications where household_id=household and type='schedule_reminder') then raise exception 'FAIL in-app reminder'; end if;
 operation:=gen_random_uuid();
 payload:=jsonb_build_object('body','水筒を持っていく');
 result:=public.server_tx_mutate_schedule_sharing(actor,operation,target,'add_comment',payload);
 if public.server_tx_mutate_schedule_sharing(actor,operation,target,'add_comment',payload)<>result then raise exception 'FAIL comment replay'; end if;
 if (select count(*) from public.schedule_comments where task_id=target)<>1 then raise exception 'FAIL duplicate comment'; end if;
 rejected:=false;
 begin perform public.server_tx_mutate_schedule_sharing(outsider,gen_random_uuid(),target,'add_comment',payload);
 exception when raise_exception then if sqlerrm='CROSS_HOUSEHOLD_RESOURCE' then rejected:=true; else raise; end if; end;
 if not rejected then raise exception 'FAIL cross-household comment'; end if;
 if has_table_privilege('authenticated','public.schedule_comments','insert') or has_table_privilege('authenticated','public.schedule_attachments','insert') then raise exception 'FAIL direct metadata mutations must be denied'; end if;
end $$;
reset role;
rollback;
select 'scheduler_details: PASS' as result;
