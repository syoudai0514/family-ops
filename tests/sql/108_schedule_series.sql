\set ON_ERROR_STOP on
begin;
set role service_role;
do $$
declare
 actor uuid:=gen_random_uuid(); household uuid; result jsonb; series uuid; start date:=(now() at time zone 'Asia/Tokyo')::date+1;
 occurrences uuid[]; third uuid; fifth uuid; revision int; n int; first_count int;
 base jsonb;
begin
 insert into auth.users(id) values(actor);
 household := (public.server_tx_create_household(actor,gen_random_uuid(),'Series test','Owner')->>'household_id')::uuid;
 base:=jsonb_build_object('title','スイミング','scheduled_date',start,'due_local_time','16:00','calendar_end_local_time','17:00',
   'completion_mode','whole','calendar_visibility','special',
   'scheduler_details',jsonb_build_object('repeat_frequency','weekly','reminders',jsonb_build_array(60),'location','市民プール'));

 -- 毎週・終了日なし: a horizon of occurrences, not "until forever".
 result:=public.server_tx_save_scheduled_task(actor,gen_random_uuid(),null,null,base);
 series:=(result->>'series_id')::uuid;
 select count(*) into first_count from public.task_instances t join public.task_schedule_details d on d.task_id=t.id
   where d.details->>'series_id'=series::text;
 if series is null or (select until from public.schedule_series where id=series) is not null
   or first_count<20 or first_count>30 then raise exception 'FAIL weekly no-end series: % occurrences',first_count; end if;
 if exists(select 1 from public.task_instances t join public.task_schedule_details d on d.task_id=t.id
   where d.details->>'series_id'=series::text and ((t.scheduled_date-start)%7<>0 or d.details->>'location'<>'市民プール'
     or d.details->'reminders'<>'[60]'::jsonb or t.calendar_ends_at is null)) then
   raise exception 'FAIL occurrence content'; end if;

 -- The daily run extends the horizon.
 n:=public.server_tx_extend_schedule_series(start+60);
 if n<8 then raise exception 'FAIL extension added %',n; end if;
 if public.server_tx_extend_schedule_series(start+60)<>0 then raise exception 'FAIL extension must be idempotent'; end if;

 select array_agg(t.id order by t.scheduled_date) into occurrences from public.task_instances t
   join public.task_schedule_details d on d.task_id=t.id where d.details->>'series_id'=series::text;
 third:=occurrences[3]; fifth:=occurrences[5];

 -- この回だけ: only this date changes and stays in the series.
 select t.revision into revision from public.task_instances t where id=occurrences[2];
 perform public.server_tx_save_scheduled_task(actor,gen_random_uuid(),occurrences[2],revision,
   jsonb_set(base,'{title}','"スイミング（振替）"')||jsonb_build_object('scheduled_date',start+8,'edit_scope','this'));
 if (select count(*) from public.task_instances where household_id=household and title='スイミング（振替）')<>1
   or (select details->>'series_id' from public.task_schedule_details where task_id=occurrences[2])<>series::text then
   raise exception 'FAIL this-only edit'; end if;

 -- これ以降すべて: earlier dates keep the old title, the rest follow the new one.
 perform public.server_tx_complete_task(actor,gen_random_uuid(),occurrences[4],'self',false,'pwa');
 select t.revision into revision from public.task_instances t where id=third;
 result:=public.server_tx_save_scheduled_task(actor,gen_random_uuid(),third,revision,
   jsonb_set(base,'{title}','"水泳教室"')||jsonb_build_object('scheduled_date',(select scheduled_date from public.task_instances where id=third),'edit_scope','following'));
 if (select status from public.task_instances where id=occurrences[1])<>'todo'
   or (select title from public.task_instances where id=occurrences[1])<>'スイミング' then raise exception 'FAIL earlier occurrence changed'; end if;
 if (select title from public.task_instances where id=third)<>'水泳教室' then raise exception 'FAIL edited occurrence'; end if;
 if exists(select 1 from public.task_instances where household_id=household and title='スイミング' and status='todo'
   and scheduled_date>(select scheduled_date from public.task_instances where id=third)) then raise exception 'FAIL old title left after split'; end if;
 if (select status from public.task_instances where id=occurrences[4])<>'completed' then raise exception 'FAIL completed occurrence touched'; end if;
 if not exists(select 1 from public.task_instances where household_id=household and title='水泳教室' and status='todo'
   and scheduled_date>(select scheduled_date from public.task_instances where id=third)) then raise exception 'FAIL new series not materialized'; end if;
 series:=(result->>'series_id')::uuid;

 -- 削除 これ以降すべて from the next occurrence of the new series.
 select t.id into fifth from public.task_instances t join public.task_schedule_details d on d.task_id=t.id
   where d.details->>'series_id'=series::text and t.status='todo' order by t.scheduled_date offset 1 limit 1;
 result:=public.server_tx_cancel_schedule_series(actor,gen_random_uuid(),fifth,'following');
 if (result->>'cancelled')::int<5 or exists(select 1 from public.task_instances t join public.task_schedule_details d on d.task_id=t.id
   where d.details->>'series_id'=series::text and t.status='todo' and t.scheduled_date>=(select scheduled_date from public.task_instances where id=fifth)) then
   raise exception 'FAIL following delete: %',result; end if;
 if (select status from public.task_instances where id=third)<>'todo' then raise exception 'FAIL earlier occurrence deleted'; end if;
 if public.server_tx_extend_schedule_series(start+400)<>0 and exists(select 1 from public.task_instances t join public.task_schedule_details d on d.task_id=t.id
   where d.details->>'series_id'=series::text and t.status='todo' and t.scheduled_date>=(select scheduled_date from public.task_instances where id=fifth)) then
   raise exception 'FAIL ended series grew again'; end if;

 -- 削除 すべて, and 平日 never lands on a weekend.
 result:=public.server_tx_save_scheduled_task(actor,gen_random_uuid(),null,null,
   jsonb_set(base,'{scheduler_details,repeat_frequency}','"weekdays"')||jsonb_build_object('title','送迎メモ',
   'scheduler_details',jsonb_build_object('repeat_frequency','weekdays','repeat_until',start+20)));
 if exists(select 1 from public.task_instances where household_id=household and title='送迎メモ'
   and scheduled_date<>start and extract(isodow from scheduled_date)>5) then raise exception 'FAIL weekday on weekend'; end if;
 if exists(select 1 from public.task_instances where household_id=household and title='送迎メモ' and scheduled_date>start+20) then
   raise exception 'FAIL until ignored'; end if;
 perform public.server_tx_cancel_schedule_series(actor,gen_random_uuid(),(result->>'task_id')::uuid,'all');
 if exists(select 1 from public.task_instances where household_id=household and title='送迎メモ' and status='todo') then
   raise exception 'FAIL delete all'; end if;
end $$;
reset role;
rollback;
select 'schedule_series: PASS' as result;
