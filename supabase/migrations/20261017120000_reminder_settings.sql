-- The reminder defaults and the push/LINE choice become settings instead of constants
-- (owner 2026-10-17: 「変えられるようにはしておいてね」).
--  * households.default_timed_reminders / default_all_day_reminders: what a new 予定
--    gets, from the PWA form and from LINE / AI入力 alike. Shared by the family.
--  * notification_preferences.schedule_line_with_push: per person, also send the
--    reminder by LINE when a device already gets it as a push (off by default to
--    keep the household's 200 LINE messages a month).

create or replace function public.is_valid_reminder_list(p_value jsonb)
returns boolean language sql immutable set search_path='' as $$
  select jsonb_typeof(p_value)='array' and jsonb_array_length(p_value)<=5
    and not exists(select 1 from jsonb_array_elements(p_value) value
      where case when jsonb_typeof(value)<>'number' then true
        when (value::text)::numeric<>trunc((value::text)::numeric) then true
        else not ((value::text)::int = any(public.schedule_reminder_allowed_offsets())) end)
$$;

alter table public.households
  add column default_timed_reminders jsonb not null default '[60]'::jsonb
    check (public.is_valid_reminder_list(default_timed_reminders)),
  add column default_all_day_reminders jsonb not null default '[780]'::jsonb
    check (public.is_valid_reminder_list(default_all_day_reminders));

alter table public.notification_preferences
  add column schedule_line_with_push boolean not null default false;

create or replace function public.default_schedule_reminders(p_household_id uuid, p_has_start_time boolean)
returns jsonb language sql stable set search_path='' as $$
  select coalesce((select case when p_has_start_time then h.default_timed_reminders else h.default_all_day_reminders end
    from public.households h where h.id=p_household_id),
    case when p_has_start_time then '[60]'::jsonb else '[780]'::jsonb end)
$$;

create or replace function private.apply_default_schedule_reminders()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.origin='manual' and new.calendar_visibility='special' and new.test_context_id is null then
    insert into public.task_schedule_details(task_id,household_id,details)
    values(new.id,new.household_id,jsonb_build_object(
      'ends_on',new.scheduled_date::text,
      'reminders',public.default_schedule_reminders(new.household_id,new.due_at is not null)))
    on conflict(task_id) do nothing;
  end if;
  return new;
end $$;

-- p_settings keys (all optional): default_timed_reminders, default_all_day_reminders
-- (the household's), schedule_line_with_push (the actor's own).
create or replace function public.server_tx_update_reminder_settings(
  p_actor_id uuid, p_operation_id uuid, p_settings jsonb
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare h uuid; hash text; r private.mutation_receipts%rowtype; key text; result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or jsonb_typeof(p_settings)<>'object' then
    raise exception 'INVALID_INPUT';
  end if;
  for key in select jsonb_object_keys(p_settings) loop
    if key in ('default_timed_reminders','default_all_day_reminders') then
      if not public.is_valid_reminder_list(p_settings->key) then raise exception 'INVALID_INPUT'; end if;
    elsif key='schedule_line_with_push' then
      if jsonb_typeof(p_settings->key)<>'boolean' then raise exception 'INVALID_INPUT'; end if;
    else
      raise exception 'INVALID_INPUT';
    end if;
  end loop;
  select household_id into h from public.household_members where user_id=p_actor_id;
  if h is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  hash:=encode(sha256(convert_to('update-reminder-settings|'||p_settings::text,'UTF8')),'hex');
  insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash)
  values(p_actor_id,p_operation_id,'update-reminder-settings',hash) on conflict(actor_id,operation_id) do nothing;
  if not found then
    select * into r from private.mutation_receipts where actor_id=p_actor_id and operation_id=p_operation_id for update;
    if r.request_hash<>hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    return r.result_payload;
  end if;
  update public.households set
    default_timed_reminders=coalesce(p_settings->'default_timed_reminders',default_timed_reminders),
    default_all_day_reminders=coalesce(p_settings->'default_all_day_reminders',default_all_day_reminders)
  where id=h;
  if p_settings ? 'schedule_line_with_push' then
    update public.notification_preferences set schedule_line_with_push=(p_settings->>'schedule_line_with_push')::boolean
    where household_id=h and user_id=p_actor_id;
  end if;
  result:=jsonb_build_object('ok',true);
  update private.mutation_receipts set result_type='reminder_settings',result_id=h,result_payload=result
  where actor_id=p_actor_id and operation_id=p_operation_id;
  return result;
end $$;

-- Same dispatcher as 20261017090000; LINE also goes out when the person asked for both.
create or replace function public.server_tx_dispatch_schedule_reminders(p_limit int default 40)
returns int language plpgsql security invoker set search_path='' as $$
declare
  item record; recipient uuid; key text; message text; lead text; total int:=0;
  due_offsets int[]; send_offset int; days_ahead int; push_devices int;
begin
  for item in
    select d.task_id,d.household_id,d.details,t.title,t.scheduled_date,t.due_at,a.anchor_at,a.offsets
    from public.task_schedule_details d
    join public.task_instances t on t.id=d.task_id and t.household_id=d.household_id
    cross join lateral (select
      coalesce(t.due_at,(t.scheduled_date+time '09:00') at time zone 'Asia/Tokyo') as anchor_at,
      public.schedule_reminder_offsets(d.details) as offsets) a
    where t.status in ('todo','in_progress') and t.test_context_id is null
      and cardinality(a.offsets)>0
      -- Left to Google Calendar only while the family calendar is actually written there;
      -- otherwise おうちノート still reminds, so a disconnected calendar loses nothing.
      and not (d.details->>'reminder_channel'='google' and t.calendar_visibility='special'
        and exists(select 1 from public.calendar_connections c
          where c.household_id=d.household_id and c.active and c.is_family_write_target))
      and a.anchor_at+interval '1 hour'>now()
      and exists(select 1 from unnest(a.offsets) o
        where a.anchor_at-make_interval(mins=>o)<=now()
          and not exists(select 1 from private.schedule_reminder_deliveries r
            where r.task_id=d.task_id and r.offset_minutes=o and r.anchor_at=a.anchor_at))
    order by a.anchor_at limit least(greatest(p_limit,1),100) for update of d skip locked
  loop
    select array_agg(o order by o) into due_offsets from unnest(item.offsets) o
    where item.anchor_at-make_interval(mins=>o)<=now()
      and not exists(select 1 from private.schedule_reminder_deliveries r
        where r.task_id=item.task_id and r.offset_minutes=o and r.anchor_at=item.anchor_at);
    send_offset:=due_offsets[1];
    insert into private.schedule_reminder_deliveries(task_id,offset_minutes,anchor_at)
    select item.task_id,o,item.anchor_at from unnest(due_offsets) o on conflict do nothing;

    days_ahead:=item.scheduled_date-(now() at time zone 'Asia/Tokyo')::date;
    lead:=case
      when item.due_at is not null and days_ahead=0 and send_offset=0 then 'まもなく'
      when item.due_at is not null and days_ahead=0 and item.due_at-now()<interval '1 hour'
        then 'あと'||greatest(ceil(extract(epoch from item.due_at-now())/60)::int,1)||'分'
      when item.due_at is not null and days_ahead=0 and item.due_at-now()<interval '6 hours'
        then 'あと'||round(extract(epoch from item.due_at-now())/3600)::int||'時間'
      when days_ahead<=0 then '今日'
      when days_ahead=1 then '明日'
      when days_ahead=2 then 'あさって'
      else days_ahead||'日後'
    end;
    message:=lead||' '||to_char(item.scheduled_date,'MM/DD')||'('||substr('日月火水木金土',extract(dow from item.scheduled_date)::int+1,1)||') '||
      case when item.due_at is null then '終日' else to_char(item.due_at at time zone 'Asia/Tokyo','HH24:MI') end||' '||item.title||
      coalesce(E'\n📍 '||nullif(btrim(item.details->>'location'),''),'');
    key:='schedule-reminder:'||item.task_id||':'||send_offset||':'||extract(epoch from item.anchor_at)::bigint;
    for recipient in select user_id from public.household_members where household_id=item.household_id and
      (jsonb_array_length(coalesce(item.details->'participants','[]'))=0 or (item.details->'participants') ? user_id::text)
    loop
      insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
        values(item.household_id,recipient,'schedule_reminder','予定のお知らせ',message,
          jsonb_build_object('task_id',item.task_id,'date',item.scheduled_date,'offset_minutes',send_offset),key)
        on conflict do nothing;
      push_devices:=public.server_tx_enqueue_web_push(item.household_id,recipient,item.title,message,
        '/month?date='||item.scheduled_date::text,'schedule-'||item.task_id,key,item.anchor_at+interval '1 hour');
      if exists(select 1 from public.notification_preferences
        where household_id=item.household_id and user_id=recipient and calendar_line
          and (push_devices=0 or schedule_line_with_push)) then
        insert into private.notification_outbox(household_id,recipient_user_id,channel,type,payload,dedup_key,priority,business_expires_at)
        values(item.household_id,recipient,'line','schedule_reminder',
          jsonb_build_object('items',jsonb_build_array(jsonb_build_object('title','予定のお知らせ','body',message))),
          key,'reminder',now()+interval '1 hour') on conflict do nothing;
      end if;
    end loop;
    total:=total+1;
  end loop;
  return total;
end $$;

drop function if exists public.default_schedule_reminders(boolean);
revoke all on function public.is_valid_reminder_list(jsonb) from public,anon,authenticated;
revoke all on function public.default_schedule_reminders(uuid,boolean) from public,anon,authenticated;
revoke all on function private.apply_default_schedule_reminders() from public,anon,authenticated;
revoke all on function public.server_tx_update_reminder_settings(uuid,uuid,jsonb) from public,anon,authenticated;
revoke all on function public.server_tx_dispatch_schedule_reminders(int) from public,anon,authenticated;
grant execute on function public.is_valid_reminder_list(jsonb) to authenticated, service_role;
grant execute on function public.schedule_reminder_allowed_offsets() to authenticated;
grant execute on function public.default_schedule_reminders(uuid,boolean) to service_role;
grant execute on function public.server_tx_update_reminder_settings(uuid,uuid,jsonb) to service_role;
grant execute on function public.server_tx_dispatch_schedule_reminders(int) to service_role;
