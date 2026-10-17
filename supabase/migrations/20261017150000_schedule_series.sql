-- Repeating 予定 as a series (owner 2026-10-17, TimeTree parity):
--  * no end date is allowed; occurrences exist only a horizon ahead and the daily
--    materialize-recurring run extends them (a 1-year daily repeat used to create 366
--    tasks at once, and "forever" was impossible);
--  * 平日, 隔週, 毎月第N曜日 and 毎年 join 毎日 / 毎週 / 毎月;
--  * editing can apply to この回だけ or これ以降すべて, deleting also to すべて.
-- Occurrences stay ordinary task_instances; task_schedule_details.details.series_id links
-- them. Repeats saved before this migration have no series and keep working per date.

create table public.schedule_series (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  created_by uuid not null references auth.users(id) on delete cascade,
  frequency text not null check (frequency in ('daily','weekdays','weekly','biweekly','monthly','monthly_nth','yearly')),
  starts_on date not null,
  until date null check (until is null or until >= starts_on - 1),
  -- The save payload every new occurrence is created from (title, times, details …).
  template jsonb not null check (jsonb_typeof(template)='object'),
  materialized_through date not null,
  ended_at timestamptz null,
  created_at timestamptz not null default now()
);
create index schedule_series_active_idx on public.schedule_series(materialized_through) where ended_at is null;
alter table public.schedule_series enable row level security;
create policy schedule_series_read on public.schedule_series for select to authenticated
  using (public.is_household_member(household_id));
grant select on public.schedule_series to authenticated;
grant all on public.schedule_series to service_role;

-- Dates of a series within [p_from, p_to]. 毎月 on the 31st falls on the month's last
-- day (same clamping as the old monthly repeat); 第5○曜日 means the last one.
create or replace function private.schedule_series_dates(p_frequency text, p_start date, p_from date, p_to date)
returns setof date language sql immutable set search_path='' as $$
  select d from (select g::date as d from generate_series(greatest(p_start,p_from), p_to, interval '1 day') g) days
  where case p_frequency
    when 'daily' then true
    when 'weekdays' then extract(isodow from d) between 1 and 5
    when 'weekly' then (d-p_start)%7=0
    when 'biweekly' then (d-p_start)%14=0
    when 'monthly' then d=(p_start+make_interval(months=>((extract(year from d)-extract(year from p_start))*12
      +extract(month from d)-extract(month from p_start))::int))::date
    when 'monthly_nth' then extract(dow from d)=extract(dow from p_start) and case
      when ceil(extract(day from p_start)/7)<5 then ceil(extract(day from d)/7)=ceil(extract(day from p_start)/7)
      else extract(month from d+7)<>extract(month from d) end
    when 'yearly' then d=(p_start+make_interval(years=>(extract(year from d)-extract(year from p_start))::int))::date
    else false
  end
$$;

-- How far ahead occurrences exist, so the calendar shows them without flooding tasks.
create or replace function private.schedule_series_horizon(p_frequency text)
returns int language sql immutable set search_path='' as $$
  select case p_frequency when 'daily' then 62 when 'weekdays' then 62 when 'weekly' then 190
    when 'biweekly' then 190 when 'yearly' then 800 else 400 end
$$;

create or replace function private.create_schedule_occurrence(p_series public.schedule_series, p_date date)
returns uuid language plpgsql security definer set search_path='' as $$
declare
  t jsonb:=p_series.template; d jsonb:=coalesce(p_series.template->'scheduler_details','{}'::jsonb);
  starts time:=nullif(t->>'due_local_time','')::time; ends time:=nullif(t->>'calendar_end_local_time','')::time;
  span int:=greatest(coalesce((t->>'duration_days')::int,0),0); v_id uuid;
begin
  if not exists(select 1 from public.household_members where household_id=p_series.household_id and user_id=p_series.created_by) then
    return null;
  end if;
  v_id:=(public.server_tx_create_task_with_calendar(p_series.created_by,gen_random_uuid(),t->>'title',t->>'category',p_date,starts,null,
    coalesce(t->>'calendar_visibility','hidden'),(t->>'planned_assignee_user_id')::uuid,
    coalesce(t->>'completion_mode','whole'),coalesce(t->>'routine_phase','anytime'),t->'subtasks')->>'task_id')::uuid;
  update public.task_instances set calendar_ends_at=case
      when starts is null then ((p_date+span)+time '23:59:59') at time zone 'Asia/Tokyo'
      when ends is null then null else ((p_date+span)+ends) at time zone 'Asia/Tokyo' end
    where household_id=p_series.household_id and id=v_id;
  insert into public.task_schedule_details(task_id,household_id,details)
  values(v_id,p_series.household_id,d||jsonb_build_object('ends_on',(p_date+span)::text,'series_id',p_series.id))
  on conflict(task_id) do update set details=excluded.details;
  return v_id;
end $$;

-- Creates the series' occurrences after materialized_through up to its horizon.
create or replace function private.materialize_schedule_series(p_series_id uuid, p_today date)
returns int language plpgsql security definer set search_path='' as $$
declare s public.schedule_series%rowtype; v_to date; v_date date; n int:=0;
begin
  select * into s from public.schedule_series where id=p_series_id for update;
  if not found or s.ended_at is not null then return 0; end if;
  v_to:=p_today+private.schedule_series_horizon(s.frequency);
  if s.until is not null then v_to:=least(v_to,s.until); end if;
  if v_to<=s.materialized_through then return 0; end if;
  for v_date in select * from private.schedule_series_dates(s.frequency,s.starts_on,s.materialized_through+1,v_to) loop
    if private.create_schedule_occurrence(s,v_date) is not null then n:=n+1; end if;
  end loop;
  update public.schedule_series set materialized_through=v_to where id=s.id;
  return n;
end $$;

-- Daily extension, run by materialize-recurring.
create or replace function public.server_tx_extend_schedule_series(p_today date)
returns int language plpgsql security invoker set search_path='' as $$
declare s record; total int:=0;
begin
  for s in select id from public.schedule_series
    where ended_at is null and (until is null or materialized_through<until)
      and materialized_through<p_today+private.schedule_series_horizon(frequency)
    order by materialized_through limit 200 for update skip locked
  loop
    total:=total+private.materialize_schedule_series(s.id,p_today);
  end loop;
  return total;
end $$;

-- Ends a series before p_from and cancels its open occurrences from p_from on (except
-- p_keep_task). Completed ones and the past stay as they were.
create or replace function private.end_schedule_series_from(p_actor_id uuid, p_series_id uuid, p_from date, p_keep_task uuid)
returns int language plpgsql security definer set search_path='' as $$
declare s public.schedule_series%rowtype; occurrence record; n int:=0;
begin
  select * into s from public.schedule_series where id=p_series_id for update;
  if not found then return 0; end if;
  update public.schedule_series set until=greatest(p_from-1,starts_on-1),
    ended_at=case when p_from<=starts_on then now() else ended_at end where id=s.id;
  for occurrence in select t.id from public.task_instances t
    join public.task_schedule_details d on d.task_id=t.id
    where t.household_id=s.household_id and d.details->>'series_id'=s.id::text
      and t.scheduled_date>=p_from and t.status in ('todo','in_progress')
      and t.id is distinct from p_keep_task
  loop
    perform public.server_tx_cancel_task(p_actor_id,gen_random_uuid(),occurrence.id);
    n:=n+1;
  end loop;
  return n;
end $$;

create or replace function public.server_tx_save_scheduled_task(
 p_actor_id uuid,p_operation_id uuid,p_task_id uuid,p_expected_revision int,p_payload jsonb
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare
 h uuid; d jsonb:=coalesce(p_payload->'scheduler_details','{}'::jsonb); r record; task public.task_instances%rowtype;
 request_hash text; result jsonb; v_id uuid; v_date date; end_date date; v_until date;
 frequency text; starts time; ends time; participant text; scope text:=coalesce(p_payload->>'edit_scope','this');
 old_series uuid; new_series uuid; template jsonb; v_today date:=(now() at time zone 'Asia/Tokyo')::date; created int:=0;
begin
 select household_id into h from public.household_members where user_id=p_actor_id;
 if h is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
 if jsonb_typeof(p_payload)<>'object' or jsonb_typeof(d)<>'object' or length(btrim(coalesce(p_payload->>'title',''))) not between 1 and 80
   or coalesce(p_payload->>'calendar_visibility','hidden') not in ('hidden','special') or scope not in ('this','following') then raise exception 'INVALID_INPUT'; end if;
 v_date:=(p_payload->>'scheduled_date')::date;
 if v_date is null then raise exception 'INVALID_INPUT'; end if;
 end_date:=coalesce((d->>'ends_on')::date,v_date);
 starts:=nullif(p_payload->>'due_local_time','')::time; ends:=nullif(p_payload->>'calendar_end_local_time','')::time;
 if end_date<v_date or end_date>v_date+366 or (starts is null and ends is not null)
   or (starts is not null and ends is not null and end_date=v_date and ends<=starts) then raise exception 'INVALID_INPUT'; end if;
 if length(coalesce(d->>'notes',''))>20000 or length(coalesce(d->>'location',''))>1000 or length(coalesce(d->>'url',''))>2048
   or coalesce(d->>'url','') !~ '^(|https?://[^[:space:]]+)$'
   or coalesce(d->>'label_color','#28b78d') !~ '^#[0-9a-fA-F]{6}$'
   or (d->>'reminder_minutes' is not null and (d->>'reminder_minutes')::int not in (0,5,10,30,60,1440))
   or jsonb_typeof(coalesce(d->'participants','[]'))<>'array' or jsonb_typeof(coalesce(d->'checklist','[]'))<>'array'
   or jsonb_typeof(coalesce(d->'checked_items','[]'))<>'array' or jsonb_array_length(coalesce(d->'checked_items','[]'))>50
   or jsonb_array_length(coalesce(d->'participants','[]'))>10 or jsonb_array_length(coalesce(d->'checklist','[]'))>50 then raise exception 'INVALID_INPUT'; end if;
 for participant in select jsonb_array_elements_text(coalesce(d->'participants','[]')) loop
   if not exists(select 1 from public.household_members where household_id=h and user_id=participant::uuid) then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
 end loop;
 frequency:=coalesce(d->>'repeat_frequency','none'); v_until:=nullif(d->>'repeat_until','')::date;
 if frequency not in ('none','daily','weekdays','weekly','biweekly','monthly','monthly_nth','yearly')
   or (frequency<>'none' and v_until is not null and (v_until<v_date or v_until>v_date+3660)) then raise exception 'INVALID_INPUT'; end if;
 if p_payload->>'planned_assignee_user_id' is not null and not exists(select 1 from public.household_members where household_id=h and user_id=(p_payload->>'planned_assignee_user_id')::uuid) then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
 request_hash:=encode(sha256(convert_to(jsonb_build_object('task',p_task_id,'revision',p_expected_revision,'payload',p_payload)::text,'UTF8')),'hex');
 insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash)
  values(p_actor_id,p_operation_id,'save-scheduled-task',request_hash) on conflict(actor_id,operation_id) do nothing;
 if not found then
   select * into r from private.mutation_receipts where actor_id=p_actor_id and operation_id=p_operation_id for update;
   if r.request_hash<>request_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
   return r.result_payload;
 end if;
 d:=d-'series_id';
 if p_task_id is not null then
   select * into task from public.task_instances where household_id=h and id=p_task_id for update;
   if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
   if task.origin<>'manual' or task.status='cancelled' or task.test_context_id is not null then raise exception 'TASK_TERMINAL'; end if;
   if p_expected_revision is null or task.revision<>p_expected_revision then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
   select nullif(details->>'series_id','')::uuid into old_series from public.task_schedule_details where task_id=p_task_id;
   v_id:=p_task_id;
   if task.status='completed' then
     update public.task_instances set title=btrim(p_payload->>'title'), scheduled_date=v_date,
       due_at=case when starts is null then null else (v_date+starts) at time zone 'Asia/Tokyo' end,
       planned_assignee_id=(p_payload->>'planned_assignee_user_id')::uuid,
       calendar_visibility=coalesce(p_payload->>'calendar_visibility','hidden') where household_id=h and task_instances.id=v_id;
   else
     perform public.server_tx_edit_task_with_calendar(p_actor_id,gen_random_uuid(),v_id,p_payload->>'title',v_date,starts,null,
       p_payload->>'category',(p_payload->>'planned_assignee_user_id')::uuid,coalesce(p_payload->>'calendar_visibility','hidden'));
   end if;
   if scope='following' and old_series is not null then
     -- これ以降すべて: the old series stops before this date and a new one starts here.
     perform private.end_schedule_series_from(p_actor_id,old_series,task.scheduled_date,v_id);
   elsif old_series is not null then
     -- この回だけ: the occurrence keeps its series and the series' repeat settings.
     d:=d||jsonb_build_object('series_id',old_series)||coalesce((select jsonb_build_object(
       'repeat_frequency',s.frequency,'repeat_until',s.until) from public.schedule_series s where s.id=old_series),'{}');
     frequency:='none';
   else
     frequency:='none'; -- an occurrence saved before series existed edits only itself
   end if;
 else
   v_id:=(public.server_tx_create_task_with_calendar(p_actor_id,gen_random_uuid(),p_payload->>'title',p_payload->>'category',v_date,starts,null,
     coalesce(p_payload->>'calendar_visibility','hidden'),(p_payload->>'planned_assignee_user_id')::uuid,
     coalesce(p_payload->>'completion_mode','whole'),coalesce(p_payload->>'routine_phase','anytime'),p_payload->'subtasks')->>'task_id')::uuid;
 end if;
 if frequency<>'none' then
   template:=(p_payload-'scheduled_date'-'edit_scope'-'expected_revision'-'operation_id'-'task_id')
     ||jsonb_build_object('duration_days',end_date-v_date,'scheduler_details',d-'ends_on'-'series_id');
   insert into public.schedule_series(household_id,created_by,frequency,starts_on,until,template,materialized_through)
   -- Past dates of a series started long ago are not back-filled; only from today on.
   values(h,p_actor_id,frequency,v_date,v_until,template,greatest(v_date,v_today-1)) returning id into new_series;
   d:=d||jsonb_build_object('series_id',new_series);
 end if;
 update public.task_instances set calendar_ends_at=case when starts is null then (end_date+time '23:59:59') at time zone 'Asia/Tokyo' when ends is null then null else (end_date+ends) at time zone 'Asia/Tokyo' end
   where household_id=h and task_instances.id=v_id;
 insert into public.task_schedule_details(task_id,household_id,details) values(v_id,h,jsonb_set(d,'{ends_on}',to_jsonb(end_date::text)))
   on conflict(task_id) do update set details=excluded.details,
     reminder_sent=case when p_task_id is not null and task.scheduled_date=v_date
       and task.due_at is not distinct from (case when starts is null then null else (v_date+starts) at time zone 'Asia/Tokyo' end)
       and task_schedule_details.details->'reminder_minutes' is not distinct from excluded.details->'reminder_minutes'
       and coalesce(task_schedule_details.details->'participants','[]')=coalesce(excluded.details->'participants','[]')
       then task_schedule_details.reminder_sent else false end;
 if new_series is not null then created:=private.materialize_schedule_series(new_series,greatest(v_today,v_date)); end if;
 result:=jsonb_build_object('task_id',v_id,'task_ids',jsonb_build_array(v_id),'count',1+created,'series_id',new_series);
 update private.mutation_receipts set result_type='task_instance',result_id=v_id,result_payload=result where actor_id=p_actor_id and operation_id=p_operation_id;
 return result;
end $$;

-- 削除: this occurrence only (cancel-task as before), これ以降すべて, or すべて.
create or replace function public.server_tx_cancel_schedule_series(p_actor_id uuid, p_operation_id uuid, p_task_id uuid, p_scope text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare h uuid; task public.task_instances%rowtype; series uuid; hash text; r record; n int; result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_task_id is null or p_scope not in ('following','all') then
    raise exception 'INVALID_INPUT';
  end if;
  select household_id into h from public.household_members where user_id=p_actor_id;
  if h is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  hash:=encode(sha256(convert_to('cancel-schedule-series|'||p_task_id||'|'||p_scope,'UTF8')),'hex');
  insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash)
  values(p_actor_id,p_operation_id,'cancel-schedule-series',hash) on conflict(actor_id,operation_id) do nothing;
  if not found then
    select * into r from private.mutation_receipts where actor_id=p_actor_id and operation_id=p_operation_id for update;
    if r.request_hash<>hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    return r.result_payload;
  end if;
  select * into task from public.task_instances where household_id=h and id=p_task_id;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  select nullif(details->>'series_id','')::uuid into series from public.task_schedule_details where task_id=p_task_id;
  if series is null then raise exception 'INVALID_INPUT'; end if;
  n:=private.end_schedule_series_from(p_actor_id,series,
    case when p_scope='all' then (select starts_on from public.schedule_series where id=series) else task.scheduled_date end,null);
  if p_scope='all' then
    -- すべて also drops open occurrences left before the series' first date (moved ones).
    update public.schedule_series set ended_at=coalesce(ended_at,now()) where id=series;
  end if;
  result:=jsonb_build_object('ok',true,'cancelled',n);
  update private.mutation_receipts set result_type='schedule_series',result_id=series,result_payload=result
  where actor_id=p_actor_id and operation_id=p_operation_id;
  return result;
end $$;

revoke all on function private.schedule_series_dates(text,date,date,date) from public,anon,authenticated;
revoke all on function private.schedule_series_horizon(text) from public,anon,authenticated;
revoke all on function private.create_schedule_occurrence(public.schedule_series,date) from public,anon,authenticated;
revoke all on function private.materialize_schedule_series(uuid,date) from public,anon,authenticated;
revoke all on function private.end_schedule_series_from(uuid,uuid,date,uuid) from public,anon,authenticated;
revoke all on function public.server_tx_extend_schedule_series(date) from public,anon,authenticated;
revoke all on function public.server_tx_save_scheduled_task(uuid,uuid,uuid,int,jsonb) from public,anon,authenticated;
revoke all on function public.server_tx_cancel_schedule_series(uuid,uuid,uuid,text) from public,anon,authenticated;
grant execute on function private.schedule_series_dates(text,date,date,date) to service_role;
grant execute on function private.schedule_series_horizon(text) to service_role;
grant execute on function private.materialize_schedule_series(uuid,date) to service_role;
grant execute on function private.end_schedule_series_from(uuid,uuid,date,uuid) to service_role;
grant execute on function public.server_tx_extend_schedule_series(date) to service_role;
grant execute on function public.server_tx_save_scheduled_task(uuid,uuid,uuid,int,jsonb) to service_role;
grant execute on function public.server_tx_cancel_schedule_series(uuid,uuid,uuid,text) to service_role;
