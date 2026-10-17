-- Push notifications to the installed PWA (iPhone home-screen app / Android / desktop).
-- LINE's free tier is 200 messages a month for the whole household, so schedule
-- reminders could not be relied on like a calendar app's. A device that turned on
-- push gets reminders there instead, and LINE is used only for people without one.

create table private.web_push_subscriptions (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null references public.households(id) on delete cascade,
  user_id uuid not null references auth.users(id) on delete cascade,
  endpoint text not null unique check (endpoint ~ '^https://[^[:space:]]+$' and length(endpoint) <= 2048),
  p256dh text not null check (length(p256dh) between 20 and 200),
  auth text not null check (length(auth) between 8 and 100),
  device_label text null check (device_label is null or length(device_label) <= 120),
  created_at timestamptz not null default now(),
  updated_at timestamptz not null default now(),
  last_success_at timestamptz null,
  failure_count int not null default 0,
  disabled_at timestamptz null
);
create index web_push_subscriptions_user_idx on private.web_push_subscriptions(household_id, user_id) where disabled_at is null;
grant all on private.web_push_subscriptions to service_role;

create table private.web_push_outbox (
  id uuid primary key default gen_random_uuid(),
  subscription_id uuid not null references private.web_push_subscriptions(id) on delete cascade,
  household_id uuid not null,
  recipient_user_id uuid not null,
  title text not null check (length(title) between 1 and 120),
  body text not null check (length(body) <= 1000),
  url text not null default '/' check (url ~ '^/'),
  tag text null,
  dedup_key text not null,
  status text not null default 'pending' check (status in ('pending','processing','sent','dead')),
  attempts int not null default 0,
  next_attempt_at timestamptz not null default now(),
  lease_until timestamptz null,
  expires_at timestamptz not null,
  last_error text null,
  created_at timestamptz not null default now(),
  sent_at timestamptz null,
  unique (subscription_id, dedup_key)
);
create index web_push_outbox_claim_idx on private.web_push_outbox(status, next_attempt_at);
grant all on private.web_push_outbox to service_role;

create or replace function public.server_tx_upsert_web_push_subscription(
  p_actor_id uuid, p_endpoint text, p_p256dh text, p_auth text, p_device_label text default null
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare h uuid; v_id uuid;
begin
  select household_id into h from public.household_members where user_id=p_actor_id;
  if h is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  if coalesce(p_endpoint,'') !~ '^https://[^[:space:]]+$' or length(p_endpoint)>2048
    or length(coalesce(p_p256dh,'')) not between 20 and 200 or length(coalesce(p_auth,'')) not between 8 and 100
    or length(coalesce(p_device_label,''))>120 then raise exception 'INVALID_INPUT'; end if;
  -- A browser has one endpoint; signing in as someone else on the same phone moves it.
  insert into private.web_push_subscriptions(household_id,user_id,endpoint,p256dh,auth,device_label)
  values(h,p_actor_id,p_endpoint,p_p256dh,p_auth,nullif(btrim(p_device_label),''))
  on conflict(endpoint) do update set household_id=excluded.household_id,user_id=excluded.user_id,
    p256dh=excluded.p256dh,auth=excluded.auth,device_label=excluded.device_label,
    updated_at=now(),failure_count=0,disabled_at=null
  returning id into v_id;
  return jsonb_build_object('subscription_id',v_id);
end $$;

create or replace function public.server_tx_delete_web_push_subscription(p_actor_id uuid, p_endpoint text)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare n int;
begin
  delete from private.web_push_subscriptions where user_id=p_actor_id and endpoint=p_endpoint;
  get diagnostics n = row_count;
  return jsonb_build_object('deleted',n);
end $$;

-- The subscription keys for one of the actor's own devices (test push / status).
create or replace function public.server_tx_get_web_push_subscription(p_actor_id uuid, p_endpoint text)
returns jsonb language sql stable security invoker set search_path='' as $$
  select jsonb_build_object('subscription_id',id,'endpoint',endpoint,'p256dh',p256dh,'auth',auth,
    'active',disabled_at is null)
  from private.web_push_subscriptions where user_id=p_actor_id and endpoint=p_endpoint
$$;

create or replace function public.server_tx_enqueue_web_push(
  p_household_id uuid, p_recipient_user_id uuid, p_title text, p_body text, p_url text,
  p_tag text, p_dedup_key text, p_expires_at timestamptz
) returns int language plpgsql security invoker set search_path='' as $$
declare n int;
begin
  insert into private.web_push_outbox(subscription_id,household_id,recipient_user_id,title,body,url,tag,dedup_key,expires_at)
  select s.id,p_household_id,p_recipient_user_id,left(p_title,120),left(coalesce(p_body,''),1000),
    coalesce(nullif(p_url,''),'/'),p_tag,p_dedup_key,p_expires_at
  from private.web_push_subscriptions s
  where s.household_id=p_household_id and s.user_id=p_recipient_user_id and s.disabled_at is null
  on conflict(subscription_id,dedup_key) do nothing;
  get diagnostics n = row_count;
  -- Counts subscriptions that will (or already did) receive this push.
  return (select count(*) from private.web_push_subscriptions s
    where s.household_id=p_household_id and s.user_id=p_recipient_user_id and s.disabled_at is null);
end $$;

create or replace function public.server_tx_claim_web_push_batch(p_limit int default 50, p_lease_seconds int default 60)
returns table(outbox_id uuid, subscription_id uuid, endpoint text, p256dh text, auth text,
  title text, body text, url text, tag text, attempts int, expires_at timestamptz)
language plpgsql security invoker set search_path='' as $$
#variable_conflict use_column
begin
  update private.web_push_outbox o set status='dead',last_error='expired'
  where o.status in ('pending','processing') and o.expires_at<=now();
  return query
  with claimed as (
    select o.id from private.web_push_outbox o
    where (o.status='pending' and o.next_attempt_at<=now()) or (o.status='processing' and o.lease_until<now())
    order by o.next_attempt_at limit least(greatest(p_limit,1),100)
    for update skip locked
  ), updated as (
    update private.web_push_outbox o set status='processing',attempts=o.attempts+1,
      lease_until=now()+make_interval(secs=>greatest(p_lease_seconds,15))
    from claimed where o.id=claimed.id returning o.*
  )
  select u.id,s.id,s.endpoint,s.p256dh,s.auth,u.title,u.body,u.url,u.tag,u.attempts,u.expires_at
  from updated u join private.web_push_subscriptions s on s.id=u.subscription_id;
end $$;

-- p_outcome: sent | retry | gone (endpoint expired/unsubscribed) | dead (rejected).
create or replace function public.server_tx_complete_web_push(p_outbox_id uuid, p_outcome text, p_error text default null)
returns void language plpgsql security invoker set search_path='' as $$
declare v private.web_push_outbox%rowtype;
begin
  if p_outcome not in ('sent','retry','gone','dead') then raise exception 'INVALID_INPUT'; end if;
  select * into v from private.web_push_outbox where id=p_outbox_id for update;
  if not found then return; end if;
  if p_outcome='sent' then
    update private.web_push_outbox set status='sent',sent_at=now(),lease_until=null,last_error=null where id=v.id;
    update private.web_push_subscriptions set last_success_at=now(),failure_count=0 where id=v.subscription_id;
  elsif p_outcome='retry' and v.attempts<5 then
    update private.web_push_outbox set status='pending',lease_until=null,last_error=left(p_error,500),
      next_attempt_at=now()+make_interval(secs=>least(30*power(2,v.attempts)::int,900)) where id=v.id;
  else
    update private.web_push_outbox set status='dead',lease_until=null,last_error=left(coalesce(p_error,p_outcome),500) where id=v.id;
    if p_outcome='gone' then
      update private.web_push_subscriptions set disabled_at=now() where id=v.subscription_id;
    else
      update private.web_push_subscriptions set failure_count=failure_count+1,
        disabled_at=case when failure_count+1>=10 then now() else disabled_at end where id=v.subscription_id;
    end if;
  end if;
end $$;

-- Same dispatcher as 20261016090000, plus push. LINE is skipped for people who get
-- the reminder on a device, which keeps the shared LINE quota for everything else.
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
      if push_devices=0 and exists(select 1 from public.notification_preferences
        where household_id=item.household_id and user_id=recipient and calendar_line) then
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

revoke all on function public.server_tx_upsert_web_push_subscription(uuid,text,text,text,text) from public,anon,authenticated;
revoke all on function public.server_tx_delete_web_push_subscription(uuid,text) from public,anon,authenticated;
revoke all on function public.server_tx_get_web_push_subscription(uuid,text) from public,anon,authenticated;
revoke all on function public.server_tx_enqueue_web_push(uuid,uuid,text,text,text,text,text,timestamptz) from public,anon,authenticated;
revoke all on function public.server_tx_claim_web_push_batch(int,int) from public,anon,authenticated;
revoke all on function public.server_tx_complete_web_push(uuid,text,text) from public,anon,authenticated;
revoke all on function public.server_tx_dispatch_schedule_reminders(int) from public,anon,authenticated;
grant execute on function public.server_tx_upsert_web_push_subscription(uuid,text,text,text,text) to service_role;
grant execute on function public.server_tx_delete_web_push_subscription(uuid,text) to service_role;
grant execute on function public.server_tx_get_web_push_subscription(uuid,text) to service_role;
grant execute on function public.server_tx_enqueue_web_push(uuid,uuid,text,text,text,text,text,timestamptz) to service_role;
grant execute on function public.server_tx_claim_web_push_batch(int,int) to service_role;
grant execute on function public.server_tx_complete_web_push(uuid,text,text) to service_role;
grant execute on function public.server_tx_dispatch_schedule_reminders(int) to service_role;
