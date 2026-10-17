-- Schedule reminders that families can rely on (TimeTree parity):
--  * several reminders per schedule (e.g. 前日20時 + 1時間前) via details.reminders;
--  * each reminder is delivered once per start time, so moving a schedule re-arms it
--    while note/checklist edits never resend;
--  * schedules created from LINE / the AI入力 get a default reminder, because only the
--    PWA form could set one before and LINE-created 予定 were silently never reminded;
--  * details.reminder_channel='google' leaves a timed schedule to each person's Google
--    Calendar notifications while the family calendar is written to Google.
-- The legacy scalar details.reminder_minutes keeps working for old clients.

create table private.schedule_reminder_deliveries (
  task_id uuid not null references public.task_instances(id) on delete cascade,
  offset_minutes int not null,
  anchor_at timestamptz not null,
  delivered_at timestamptz not null default now(),
  primary key (task_id, offset_minutes, anchor_at)
);
grant all on private.schedule_reminder_deliveries to service_role;

-- Minutes before the start (all-day schedules start at 09:00 for reminders):
-- 780 = 前日20時 and 1440 = 前日 for all-day schedules.
create or replace function public.schedule_reminder_allowed_offsets()
returns int[] language sql immutable set search_path='' as $$
  select array[0,5,10,15,30,60,120,780,1440,2880,10080]
$$;

create or replace function public.schedule_reminder_offsets(p_details jsonb)
returns int[] language sql immutable set search_path='' as $$
  select case
    when jsonb_typeof(p_details->'reminders')='array' then coalesce((
      select array_agg(distinct value::int order by value::int)
      from jsonb_array_elements_text(p_details->'reminders') value), '{}')
    when p_details->>'reminder_minutes' is not null then array[(p_details->>'reminder_minutes')::int]
    else '{}'::int[]
  end
$$;

create or replace function private.validate_schedule_reminders()
returns trigger language plpgsql set search_path='' as $$
begin
  if new.details ? 'reminders' and (
    jsonb_typeof(new.details->'reminders')<>'array'
    or jsonb_array_length(new.details->'reminders')>5
    or exists(select 1 from jsonb_array_elements(new.details->'reminders') value
      where case when jsonb_typeof(value)<>'number' then true
        when (value::text)::numeric<>trunc((value::text)::numeric) then true
        else not ((value::text)::int = any(public.schedule_reminder_allowed_offsets())) end)
  ) then raise exception 'INVALID_INPUT'; end if;
  if new.details ? 'reminder_channel' and coalesce(new.details->>'reminder_channel','') not in ('app','google') then
    raise exception 'INVALID_INPUT';
  end if;
  return new;
end $$;
create trigger task_schedule_details_validate_reminders
  before insert or update on public.task_schedule_details
  for each row execute function private.validate_schedule_reminders();

-- A schedule typed into LINE or the AI入力 has no form to pick a reminder, so it gets
-- the household default. Saving the PWA form replaces these details entirely, so an
-- explicit "通知しない" still wins.
create or replace function public.default_schedule_reminders(p_has_start_time boolean)
returns jsonb language sql immutable set search_path='' as $$
  select case when p_has_start_time then '[60]'::jsonb else '[780]'::jsonb end
$$;

create or replace function private.apply_default_schedule_reminders()
returns trigger language plpgsql security definer set search_path='' as $$
begin
  if new.origin='manual' and new.calendar_visibility='special' and new.test_context_id is null then
    insert into public.task_schedule_details(task_id,household_id,details)
    values(new.id,new.household_id,jsonb_build_object(
      'ends_on',new.scheduled_date::text,
      'reminders',public.default_schedule_reminders(new.due_at is not null)))
    on conflict(task_id) do nothing;
  end if;
  return new;
end $$;
create trigger task_instances_default_schedule_reminders
  after insert on public.task_instances
  for each row execute function private.apply_default_schedule_reminders();

revoke all on function public.schedule_reminder_allowed_offsets() from public,anon,authenticated;
revoke all on function public.schedule_reminder_offsets(jsonb) from public,anon,authenticated;
revoke all on function public.default_schedule_reminders(boolean) from public,anon,authenticated;
revoke all on function private.validate_schedule_reminders() from public,anon,authenticated;
revoke all on function private.apply_default_schedule_reminders() from public,anon,authenticated;
grant execute on function public.schedule_reminder_allowed_offsets() to service_role;
grant execute on function public.schedule_reminder_offsets(jsonb) to service_role;
grant execute on function public.default_schedule_reminders(boolean) to service_role;

-- Reminders already sent under the one-shot flag must not fire again after deploy.
insert into private.schedule_reminder_deliveries(task_id,offset_minutes,anchor_at)
select d.task_id,(d.details->>'reminder_minutes')::int,
  coalesce(t.due_at,(t.scheduled_date+time '09:00') at time zone 'Asia/Tokyo')
from public.task_schedule_details d join public.task_instances t on t.id=d.task_id
where d.reminder_sent and d.details->>'reminder_minutes' is not null
on conflict do nothing;

create or replace function public.server_tx_dispatch_schedule_reminders(p_limit int default 40)
returns int language plpgsql security invoker set search_path='' as $$
declare
  item record; recipient uuid; key text; message text; lead text; total int:=0;
  due_offsets int[]; send_offset int; days_ahead int;
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
    -- When several reminders are overdue at once (created late, worker outage), send only
    -- the one closest to the start; the earlier ones would just repeat it.
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
      if exists(select 1 from public.notification_preferences where household_id=item.household_id and user_id=recipient and calendar_line) then
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
revoke all on function public.server_tx_dispatch_schedule_reminders(int) from public,anon,authenticated;
grant execute on function public.server_tx_dispatch_schedule_reminders(int) to service_role;
