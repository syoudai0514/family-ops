-- Scheduler details use canonical tasks; attachment bytes stay in private Storage.
create table public.task_schedule_details (
  task_id uuid primary key,
  household_id uuid not null,
  details jsonb not null default '{}'::jsonb check (jsonb_typeof(details)='object'),
  reminder_sent boolean not null default false,
  foreign key(household_id,task_id) references public.task_instances(household_id,id) on delete cascade
);
alter table public.task_schedule_details enable row level security;
create policy task_schedule_details_read on public.task_schedule_details for select to authenticated
  using (public.is_household_member(household_id));
grant select on public.task_schedule_details to authenticated;
grant all on public.task_schedule_details to service_role;

create table public.schedule_attachments (
  id uuid primary key default gen_random_uuid(), household_id uuid not null, task_id uuid not null,
  added_by uuid not null default auth.uid(), file_name text not null check(length(file_name) between 1 and 255),
  object_path text not null unique, mime_type text not null,
  size_bytes int not null check(size_bytes between 0 and 10485760), created_at timestamptz not null default now(),
  foreign key(household_id,task_id) references public.task_instances(household_id,id) on delete cascade,
  check(object_path like household_id::text || '/' || task_id::text || '/%'),
  check(mime_type in ('image/jpeg','image/png','image/webp','image/heic','image/heif','application/pdf','text/plain'))
);
alter table public.schedule_attachments enable row level security;
create policy schedule_attachments_read on public.schedule_attachments for select to authenticated using(public.is_household_member(household_id));
grant select on public.schedule_attachments to authenticated;
grant all on public.schedule_attachments to service_role;

create table public.schedule_comments (
  id uuid primary key default gen_random_uuid(), household_id uuid not null, task_id uuid not null,
  author_id uuid not null default auth.uid(), body text not null check(length(btrim(body)) between 1 and 4000),
  created_at timestamptz not null default now(),
  foreign key(household_id,task_id) references public.task_instances(household_id,id) on delete cascade
);
alter table public.schedule_comments enable row level security;
create policy schedule_comments_read on public.schedule_comments for select to authenticated using(public.is_household_member(household_id));
grant select on public.schedule_comments to authenticated;
grant all on public.schedule_comments to service_role;

-- Storage is present on Supabase; the lightweight SQL-only harness omits it.
do $storage$
begin
  if to_regclass('storage.buckets') is not null then
    insert into storage.buckets(id,name,public,file_size_limit,allowed_mime_types)
      values('schedule-attachments','schedule-attachments',false,10485760,array['image/jpeg','image/png','image/webp','image/heic','image/heif','application/pdf','text/plain']) on conflict(id) do nothing;
    execute $policy$create policy schedule_files_read on storage.objects for select to authenticated using (
      bucket_id='schedule-attachments' and exists(select 1 from public.task_instances t
        where t.household_id::text=split_part(name,'/',1) and t.id::text=split_part(name,'/',2)
          and t.test_context_id is null and public.is_household_member(t.household_id)))$policy$;
    execute $policy$create policy schedule_files_upload on storage.objects for insert to authenticated with check (
      bucket_id='schedule-attachments' and exists(select 1 from public.task_instances t
        where t.household_id::text=split_part(name,'/',1) and t.id::text=split_part(name,'/',2)
          and t.test_context_id is null and t.status<>'cancelled' and public.is_household_member(t.household_id)))$policy$;
    execute $policy$create policy schedule_files_remove on storage.objects for delete to authenticated using (
      bucket_id='schedule-attachments' and exists(select 1 from public.task_instances t
        where t.household_id::text=split_part(name,'/',1) and t.id::text=split_part(name,'/',2)
          and t.test_context_id is null and public.is_household_member(t.household_id)))$policy$;
  end if;
end $storage$;

create or replace function public.server_tx_save_scheduled_task(
 p_actor_id uuid,p_operation_id uuid,p_task_id uuid,p_expected_revision int,p_payload jsonb
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare
 h uuid; d jsonb:=coalesce(p_payload->'scheduler_details','{}'::jsonb); r record; task public.task_instances%rowtype;
 request_hash text; result jsonb; v_id uuid; ids uuid[]:='{}'; date date; last_date date; end_date date;
 initial_date date; frequency text; starts time; ends time; participant text; i int:=0;
begin
 select household_id into h from public.household_members where user_id=p_actor_id;
 if h is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
 if jsonb_typeof(p_payload)<>'object' or jsonb_typeof(d)<>'object' or length(btrim(coalesce(p_payload->>'title',''))) not between 1 and 80
   or coalesce(p_payload->>'calendar_visibility','hidden') not in ('hidden','special') then raise exception 'INVALID_INPUT'; end if;
 initial_date:=(p_payload->>'scheduled_date')::date; date:=initial_date;
 if date is null then raise exception 'INVALID_INPUT'; end if;
 end_date:=coalesce((d->>'ends_on')::date,date);
 starts:=nullif(p_payload->>'due_local_time','')::time; ends:=nullif(p_payload->>'calendar_end_local_time','')::time;
 if end_date<date or end_date>date+366 or (starts is null and ends is not null)
   or (starts is not null and ends is not null and end_date=date and ends<=starts) then raise exception 'INVALID_INPUT'; end if;
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
 frequency:=coalesce(d->>'repeat_frequency','none'); last_date:=coalesce((d->>'repeat_until')::date,date);
 if frequency not in ('none','daily','weekly','monthly') or (p_task_id is null and (last_date<date or last_date>date+366
   or (frequency<>'none' and d->>'repeat_until' is null))) then raise exception 'INVALID_INPUT'; end if;
 if p_payload->>'planned_assignee_user_id' is not null and not exists(select 1 from public.household_members where household_id=h and user_id=(p_payload->>'planned_assignee_user_id')::uuid) then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
 request_hash:=encode(sha256(convert_to(jsonb_build_object('task',p_task_id,'revision',p_expected_revision,'payload',p_payload)::text,'UTF8')),'hex');
 insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash)
  values(p_actor_id,p_operation_id,'save-scheduled-task',request_hash) on conflict(actor_id,operation_id) do nothing;
 if not found then
   select * into r from private.mutation_receipts where actor_id=p_actor_id and operation_id=p_operation_id for update;
   if r.request_hash<>request_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
   return r.result_payload;
 end if;
 if p_task_id is not null then
   select * into task from public.task_instances where household_id=h and id=p_task_id for update;
   if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
   if task.origin<>'manual' or task.status='cancelled' or task.test_context_id is not null then raise exception 'TASK_TERMINAL'; end if;
   if p_expected_revision is null or task.revision<>p_expected_revision then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
   -- Updating an occurrence never silently rewrites the other repeated dates.
   v_id:=p_task_id;
   if task.status='completed' then
     update public.task_instances set title=btrim(p_payload->>'title'), scheduled_date=date,
       due_at=case when starts is null then null else (date+starts) at time zone 'Asia/Tokyo' end,
       planned_assignee_id=(p_payload->>'planned_assignee_user_id')::uuid,
       calendar_visibility=coalesce(p_payload->>'calendar_visibility','hidden') where household_id=h and task_instances.id=v_id;
   else
     perform public.server_tx_edit_task_with_calendar(p_actor_id,gen_random_uuid(),v_id,p_payload->>'title',date,starts,null,
       p_payload->>'category',(p_payload->>'planned_assignee_user_id')::uuid,coalesce(p_payload->>'calendar_visibility','hidden'));
   end if;
 else
   v_id:=(public.server_tx_create_task_with_calendar(p_actor_id,gen_random_uuid(),p_payload->>'title',p_payload->>'category',date,starts,null,
     coalesce(p_payload->>'calendar_visibility','hidden'),(p_payload->>'planned_assignee_user_id')::uuid,
     coalesce(p_payload->>'completion_mode','whole'),coalesce(p_payload->>'routine_phase','anytime'),p_payload->'subtasks')->>'task_id')::uuid;
 end if;
 loop
   update public.task_instances set calendar_ends_at=case when starts is null then ((date+(end_date-initial_date))+time '23:59:59') at time zone 'Asia/Tokyo' when ends is null then null else ((date+(end_date-initial_date))+ends) at time zone 'Asia/Tokyo' end
     where household_id=h and task_instances.id=v_id;
   insert into public.task_schedule_details(task_id,household_id,details) values(v_id,h,jsonb_set(d,'{ends_on}',to_jsonb((date+(end_date-initial_date))::text)))
     on conflict(task_id) do update set details=excluded.details,
       reminder_sent=case when p_task_id is not null and task.scheduled_date=date
         and task.due_at is not distinct from (case when starts is null then null else (date+starts) at time zone 'Asia/Tokyo' end)
         and task_schedule_details.details->'reminder_minutes' is not distinct from excluded.details->'reminder_minutes'
         and coalesce(task_schedule_details.details->'participants','[]')=coalesce(excluded.details->'participants','[]')
         then task_schedule_details.reminder_sent else false end;
   ids:=array_append(ids,v_id);
   if p_task_id is not null or frequency='none' then exit; end if;
   i:=i+1;
   date:=case frequency when 'daily' then initial_date+i when 'weekly' then initial_date+(i*7) else (initial_date+make_interval(months=>i))::date end;
   exit when date>last_date;
   v_id:=(public.server_tx_create_task_with_calendar(p_actor_id,gen_random_uuid(),p_payload->>'title',p_payload->>'category',date,starts,null,
     coalesce(p_payload->>'calendar_visibility','hidden'),(p_payload->>'planned_assignee_user_id')::uuid,
     coalesce(p_payload->>'completion_mode','whole'),coalesce(p_payload->>'routine_phase','anytime'),p_payload->'subtasks')->>'task_id')::uuid;
 end loop;
 result:=jsonb_build_object('task_id',ids[1],'task_ids',ids,'count',cardinality(ids));
 update private.mutation_receipts set result_type='task_instance',result_id=ids[1],result_payload=result where actor_id=p_actor_id and operation_id=p_operation_id;
 return result;
end $$;
revoke all on function public.server_tx_save_scheduled_task(uuid,uuid,uuid,int,jsonb) from public,anon,authenticated;
grant execute on function public.server_tx_save_scheduled_task(uuid,uuid,uuid,int,jsonb) to service_role;

create or replace function public.server_tx_dispatch_schedule_reminders(p_limit int default 40)
returns int language plpgsql security invoker set search_path='' as $$
declare item record; recipient uuid; key text; message text; total int:=0;
begin
 for item in select d.task_id,d.household_id,d.details,t.title,t.scheduled_date,t.due_at,t.revision
   from public.task_schedule_details d join public.task_instances t on t.id=d.task_id and t.household_id=d.household_id
   where d.reminder_sent=false and d.details->>'reminder_minutes' is not null
     and t.status in ('todo','in_progress') and t.test_context_id is null
     and coalesce(t.due_at,(t.scheduled_date+time '09:00') at time zone 'Asia/Tokyo')-make_interval(mins=>(d.details->>'reminder_minutes')::int)<=now()
     and coalesce(t.due_at,(t.scheduled_date+time '09:00') at time zone 'Asia/Tokyo')+interval '1 hour'>now()
   order by t.scheduled_date limit least(greatest(p_limit,1),100) for update of d skip locked
 loop
   message:=to_char(item.scheduled_date,'MM/DD')||'('||substr('日月火水木金土',extract(dow from item.scheduled_date)::int+1,1)||') '||
     case when item.due_at is null then '終日' else to_char(item.due_at at time zone 'Asia/Tokyo','HH24:MI') end||' '||item.title;
   for recipient in select user_id from public.household_members where household_id=item.household_id and
     (jsonb_array_length(coalesce(item.details->'participants','[]'))=0 or (item.details->'participants') ? user_id::text)
   loop
     key:='schedule-reminder:'||item.task_id||':'||item.revision;
     insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
       values(item.household_id,recipient,'schedule_reminder','予定のお知らせ',message,jsonb_build_object('task_id',item.task_id,'date',item.scheduled_date),key) on conflict do nothing;
     if exists(select 1 from public.notification_preferences where household_id=item.household_id and user_id=recipient and calendar_line) then
       insert into private.notification_outbox(household_id,recipient_user_id,channel,type,payload,dedup_key,priority,business_expires_at)
       values(item.household_id,recipient,'line','schedule_reminder',jsonb_build_object('items',jsonb_build_array(jsonb_build_object('title','予定のお知らせ','body',message))),key,'reminder',now()+interval '1 hour') on conflict do nothing;
     end if;
   end loop;
   update public.task_schedule_details set reminder_sent=true where task_id=item.task_id;
   total:=total+1;
 end loop;
 return total;
end $$;
revoke all on function public.server_tx_dispatch_schedule_reminders(int) from public,anon,authenticated;
grant execute on function public.server_tx_dispatch_schedule_reminders(int) to service_role;

-- Keep Google mirrors aligned with scheduler notes, location and all-day range.
create or replace function public.server_tx_claim_family_ops_calendar_mirror(p_worker_id text, p_lease_seconds integer default 120)
 returns jsonb
 language plpgsql
 set search_path to ''
as $function$
declare
  v_mirror private.family_ops_calendar_mirrors%rowtype;
  v_lease uuid;
  v_dropoff uuid;
  v_pickup uuid;
  v_task public.task_instances%rowtype;
  v_details jsonb;
  v_title text;
  v_payload jsonb;
  v_event_id text;
  v_skipped integer := 0;
begin
  if coalesce(p_worker_id,'')='' then raise exception 'INVALID_INPUT'; end if;

  -- Bounded: a burst of invalid rows is parked a few at a time, never looped forever.
  while v_skipped < 10 loop
    v_lease := gen_random_uuid();
    select * into v_mirror
    from private.family_ops_calendar_mirrors
    where (sync_state in ('pending','failed') and next_attempt_at<=now())
       or (sync_state='processing' and lease_until<now())
    order by next_attempt_at,updated_at
    for update skip locked
    limit 1;
    if not found then return null; end if;

    update private.family_ops_calendar_mirrors
    set sync_state='processing',lease_token=v_lease,
        lease_until=now()+make_interval(secs=>greatest(coalesce(p_lease_seconds,120),30)),
        attempts=attempts+1,updated_at=now()
    where household_id=v_mirror.household_id and projection_key=v_mirror.projection_key
    returning * into v_mirror;

    v_event_id:=coalesce(v_mirror.provider_event_id,
      'fo'||substr(md5(v_mirror.household_id::text||':'||v_mirror.projection_key),1,32));

    if v_mirror.desired_action='delete' then
      return jsonb_build_object(
        'household_id',v_mirror.household_id,'projection_key',v_mirror.projection_key,
        'calendar_connection_id',v_mirror.calendar_connection_id,'lease_token',v_lease,
        'action','delete','provider_event_id',v_mirror.provider_event_id,
        'deterministic_event_id',v_event_id
      );
    end if;

    begin
      if v_mirror.kind='transport' then
        select ti.planned_assignee_id into v_dropoff
        from public.task_instances ti join public.task_definitions td
          on td.household_id=ti.household_id and td.id=ti.task_definition_id
        where ti.household_id=v_mirror.household_id and ti.scheduled_date=v_mirror.local_date
          and ti.status<>'cancelled' and td.code='dropoff'
          and ti.test_context_id is null
        order by ti.updated_at desc,ti.id desc limit 1;

        select ti.planned_assignee_id into v_pickup
        from public.task_instances ti join public.task_definitions td
          on td.household_id=ti.household_id and td.id=ti.task_definition_id
        where ti.household_id=v_mirror.household_id and ti.scheduled_date=v_mirror.local_date
          and ti.status<>'cancelled' and td.code='pickup'
          and ti.test_context_id is null
        order by ti.updated_at desc,ti.id desc limit 1;

        if v_dropoff is null and v_pickup is null then
          return jsonb_build_object(
            'household_id',v_mirror.household_id,'projection_key',v_mirror.projection_key,
            'calendar_connection_id',v_mirror.calendar_connection_id,'lease_token',v_lease,
            'action','delete','provider_event_id',v_mirror.provider_event_id,
            'deterministic_event_id',v_event_id
          );
        end if;

        v_title:=private.family_ops_transport_compact_title(v_mirror.household_id,v_dropoff,v_pickup);
        if v_title='' or v_title ~ '[[:space:]|｜/]' then raise exception 'TRANSPORT_COMPACT_TITLE_INVALID'; end if;
        if v_dropoff is not null and position('送' in v_title)=0 then raise exception 'TRANSPORT_COMPACT_ACTOR_TOKEN_REQUIRED'; end if;
        if v_pickup is not null and position('迎' in v_title)=0 then raise exception 'TRANSPORT_COMPACT_ACTOR_TOKEN_REQUIRED'; end if;

        v_payload:=jsonb_build_object(
          'id',v_event_id,'summary',v_title,
          'start',jsonb_build_object('date',v_mirror.local_date::text),
          'end',jsonb_build_object('date',(v_mirror.local_date+1)::text),
          'transparency','transparent'
        );
      else
        select * into v_task from public.task_instances
        where household_id=v_mirror.household_id and id=v_mirror.task_instance_id;
        if not found or v_task.test_context_id is not null
           or v_task.status='cancelled' or v_task.calendar_visibility<>'special' then
          return jsonb_build_object(
            'household_id',v_mirror.household_id,'projection_key',v_mirror.projection_key,
            'calendar_connection_id',v_mirror.calendar_connection_id,'lease_token',v_lease,
            'action','delete','provider_event_id',v_mirror.provider_event_id,
            'deterministic_event_id',v_event_id
          );
        end if;
        if v_task.calendar_ends_at is not null and v_task.calendar_ends_at<=v_task.due_at then
          raise exception 'INVALID_INPUT';
        end if;
        if v_task.due_at is null then
          v_payload:=jsonb_build_object(
            'id',v_event_id,'summary',v_task.title,
            'start',jsonb_build_object('date',v_task.scheduled_date::text),
            'end',jsonb_build_object('date',(v_task.scheduled_date+1)::text),
            'transparency','transparent'
          );
        elsif v_task.calendar_ends_at is null then
          -- A time without an end time (typically a deadline, "8:00までに準備"):
          -- all day on its date, the time at the head of the title. No end time is
          -- invented (owner decision 2026-09-30, Requirements §29.11 option A).
          v_payload:=jsonb_build_object(
            'id',v_event_id,
            'summary',to_char(v_task.due_at at time zone 'Asia/Tokyo','FMHH24:MI')||' '||v_task.title,
            'start',jsonb_build_object('date',v_task.scheduled_date::text),
            'end',jsonb_build_object('date',(v_task.scheduled_date+1)::text),
            'transparency','transparent'
          );
        else
          v_payload:=jsonb_build_object(
            'id',v_event_id,'summary',v_task.title,
            'start',jsonb_build_object('dateTime',v_task.due_at,'timeZone','Asia/Tokyo'),
            'end',jsonb_build_object('dateTime',v_task.calendar_ends_at,'timeZone','Asia/Tokyo')
          );
        end if;
      end if;

      if v_mirror.kind='special' then
        select details into v_details from public.task_schedule_details where task_id=v_task.id;
        if found then
          v_payload:=v_payload||jsonb_build_object('location',coalesce(v_details->>'location',''),
            'description',concat_ws(E'\n',nullif(v_details->>'notes',''),nullif(v_details->>'url','')));
          if v_task.due_at is null and v_details->>'ends_on' is not null then
            v_payload:=jsonb_set(v_payload,'{end,date}',to_jsonb(((v_details->>'ends_on')::date+1)::text));
          end if;
        end if;
      end if;

      v_payload:=v_payload||jsonb_build_object('extendedProperties',jsonb_build_object('private',jsonb_build_object(
        'familyOpsMirror','true','familyOpsProjectionKey',v_mirror.projection_key,
        'familyOpsKind',v_mirror.kind,
        'familyOpsTaskInstanceId',coalesce(v_mirror.task_instance_id::text,'')
      )));
      return jsonb_build_object(
        'household_id',v_mirror.household_id,'projection_key',v_mirror.projection_key,
        'calendar_connection_id',v_mirror.calendar_connection_id,'lease_token',v_lease,
        'action','upsert','provider_event_id',v_mirror.provider_event_id,
        'deterministic_event_id',v_event_id,'event',v_payload
      );
    exception when raise_exception then
      -- The row cannot be mirrored as it stands. Park it with the reason (same backoff
      -- as a provider failure) and move on; editing the task re-queues it as pending.
      update private.family_ops_calendar_mirrors
      set sync_state='failed',lease_token=null,lease_until=null,
          last_error=left(sqlerrm,1000),
          next_attempt_at=now()+make_interval(secs=>(2^least(v_mirror.attempts,6))::integer*30),
          updated_at=now()
      where household_id=v_mirror.household_id and projection_key=v_mirror.projection_key;
      v_skipped := v_skipped + 1;
    end;
  end loop;
  return null;
end;
$function$;

revoke all on function public.server_tx_claim_family_ops_calendar_mirror(text,integer) from public,anon,authenticated;
grant execute on function public.server_tx_claim_family_ops_calendar_mirror(text,integer) to service_role;

create or replace function public.server_tx_mutate_schedule_sharing(p_actor_id uuid,p_operation_id uuid,p_task_id uuid,p_action text,p_payload jsonb)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare h uuid; task public.task_instances%rowtype; request_hash text; receipt record; result jsonb;
 attachment uuid; path text; stored jsonb; object_exists boolean;
begin
 select household_id into h from public.household_members where user_id=p_actor_id;
 if h is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
 select * into task from public.task_instances where household_id=h and id=p_task_id;
 if not found or task.test_context_id is not null then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
 if p_action not in ('register_attachment','delete_attachment','add_comment') then raise exception 'INVALID_INPUT'; end if;
 request_hash:=encode(sha256(convert_to(jsonb_build_object('action',p_action,'task',p_task_id,'payload',p_payload)::text,'UTF8')),'hex');
 insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash)
   values(p_actor_id,p_operation_id,'schedule-sharing',request_hash) on conflict(actor_id,operation_id) do nothing;
 if not found then
   select * into receipt from private.mutation_receipts where actor_id=p_actor_id and operation_id=p_operation_id for update;
   if receipt.request_hash<>request_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
   return receipt.result_payload;
 end if;
 if p_action='register_attachment' then
   path:=p_payload->>'object_path';
   if path<>h::text||'/'||p_task_id::text||'/'||p_operation_id::text then raise exception 'INVALID_INPUT'; end if;
   if to_regclass('storage.objects') is null then raise exception 'INVALID_INPUT'; end if;
   execute 'select exists(select 1 from storage.objects where bucket_id=$1 and name=$2)' into object_exists using 'schedule-attachments',path;
   if not object_exists then raise exception 'INVALID_INPUT'; end if;
   execute 'select metadata from storage.objects where bucket_id=$1 and name=$2' into stored using 'schedule-attachments',path;
   if (stored->>'size')::bigint<>(p_payload->>'size_bytes')::bigint or stored->>'mimetype'<>p_payload->>'mime_type' then raise exception 'INVALID_INPUT'; end if;
   insert into public.schedule_attachments(household_id,task_id,added_by,file_name,object_path,mime_type,size_bytes)
    values(h,p_task_id,p_actor_id,p_payload->>'file_name',path,p_payload->>'mime_type',(p_payload->>'size_bytes')::int) returning id into attachment;
   result:=jsonb_build_object('attachment_id',attachment);
 elsif p_action='delete_attachment' then
   delete from public.schedule_attachments where household_id=h and task_id=p_task_id and id=(p_payload->>'attachment_id')::uuid returning object_path into path;
   if not found then raise exception 'INVALID_INPUT'; end if;
   result:=jsonb_build_object('object_path',path);
 else
   insert into public.schedule_comments(household_id,task_id,author_id,body) values(h,p_task_id,p_actor_id,btrim(p_payload->>'body')) returning id into attachment;
   result:=jsonb_build_object('comment_id',attachment);
 end if;
 update private.mutation_receipts set result_type='schedule-sharing',result_id=attachment,result_payload=result where actor_id=p_actor_id and operation_id=p_operation_id;
 return result;
end $$;
revoke all on function public.server_tx_mutate_schedule_sharing(uuid,uuid,uuid,text,jsonb) from public,anon,authenticated;
grant execute on function public.server_tx_mutate_schedule_sharing(uuid,uuid,uuid,text,jsonb) to service_role;
