-- A one-day, per-recipient pause for the morning nudge and evening note.
-- It does not alter the household's usual notification preferences.
create table private.line_quiet_days (
  household_id uuid not null,
  user_id uuid not null,
  local_date date not null,
  created_at timestamptz not null default now(),
  primary key (household_id,user_id,local_date),
  foreign key (household_id,user_id) references public.household_members(household_id,user_id)
);
revoke all on private.line_quiet_days from public,anon,authenticated;
grant select,insert on private.line_quiet_days to service_role;

-- These notification writes are shared by LINE and web push. Returning null
-- before the morning nudge's RETURNING clause also prevents its web push.
create function private.fn_skip_quiet_day_notification_v1()
returns trigger language plpgsql security invoker set search_path='' as $$
declare v_local_date date; date_text text;
begin
  if new.safety_class is distinct from 'normal' then return new; end if;
  if new.type='morning_nudge' then
    date_text:=new.payload->>'date';
  elsif new.type='daily_brief.v2' and new.title='夜のおうちノート' then
    date_text:=new.payload#>>'{brief,local_date}';
  else
    return new;
  end if;
  if date_text ~ '^\d{4}-\d{2}-\d{2}$' then
    begin
      v_local_date:=date_text::date;
    exception when invalid_datetime_format or datetime_field_overflow then
      return new;
    end;
  else
    -- Unexpected payloads are never silently suppressed.
    return new;
  end if;
  -- Serialize with a same-day pause: otherwise the scheduler could create a
  -- notification concurrently just after the pause checked the queue.
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'line-quiet:'||new.household_id::text||':'||new.recipient_user_id::text||':'||v_local_date::text,0));
  if exists(select 1 from private.line_quiet_days q where q.household_id=new.household_id
    and q.user_id=new.recipient_user_id and q.local_date=v_local_date) then return null; end if;
  return new;
end $$;
revoke all on function private.fn_skip_quiet_day_notification_v1() from public,anon,authenticated;
grant execute on function private.fn_skip_quiet_day_notification_v1() to service_role;
create trigger skip_quiet_day_notification
  before insert on public.user_notifications for each row execute function private.fn_skip_quiet_day_notification_v1();

create function public.server_tx_line_quiet_today_v1(p_actor_id uuid,p_local_date date)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare
  ctx jsonb; hh uuid; o record; kept jsonb; removed integer; first_type text;
  morning_key text;
begin
  if p_actor_id is null or p_local_date is null or p_local_date<>(now() at time zone 'Asia/Tokyo')::date then
    raise exception 'INVALID_INPUT';
  end if;
  ctx:=private.fn_require_production_actor_context_v1(p_actor_id);
  hh:=(ctx->>'household_id')::uuid;
  perform pg_catalog.pg_advisory_xact_lock(pg_catalog.hashtextextended(
    'line-quiet:'||hh::text||':'||p_actor_id::text||':'||p_local_date::text,0));
  insert into private.line_quiet_days(household_id,user_id,local_date)
  values(hh,p_actor_id,p_local_date) on conflict do nothing;
  morning_key:='morning-nudge:'||p_local_date::text||':'||p_actor_id::text;

  -- Only change rows never claimed by a sender. A claimed/retried request may
  -- already have reached LINE; changing its body would violate the provider's
  -- retry-key contract. Keep other bundled notifications intact.
  for o in select * from private.notification_outbox
    where household_id=hh and recipient_user_id=p_actor_id and channel='line'
      and status='queued' and attempts=0 and jsonb_typeof(payload->'items')='array'
      and quota_reservation_id is null and provider_first_attempt_at is null and provider_retry_key is null
    order by id for update
  loop
    select coalesce(jsonb_agg(item order by ord) filter(where not suppress),'[]'::jsonb),
      count(*) filter(where suppress)::integer
    into kept,removed from (
      select x.item,x.ord,
        coalesce((o.dedup_key=morning_key and x.ord=1 and o.type='morning_nudge' and o.priority<>'critical'),false)
        or coalesce((x.item->>'type'='daily_brief.v2' and x.item->>'title'='夜のおうちノート'
          and exists(select 1 from public.user_notifications n where n.id::text=x.item->>'user_notification_id'
            and n.household_id=hh and n.recipient_user_id=p_actor_id
            and n.safety_class='normal'
            and n.payload#>>'{brief,local_date}'=p_local_date::text)),false) suppress
      from jsonb_array_elements(o.payload->'items') with ordinality x(item,ord)
    ) items;
    if removed>0 then
      if jsonb_array_length(kept)=0 then
        update private.notification_outbox set status='dead',last_error='quiet_today'
          where id=o.id;
      else
        first_type:=coalesce(nullif(kept->0->>'type',''),o.type);
        update private.notification_outbox set payload=jsonb_set(payload,'{items}',kept),type=first_type
          where id=o.id;
      end if;
    end if;
  end loop;
  update private.web_push_outbox set status='dead',last_error='quiet_today'
    where household_id=hh and recipient_user_id=p_actor_id and dedup_key=morning_key
      and status='pending' and attempts=0;
  return jsonb_build_object('ok',true);
end $$;
revoke all on function public.server_tx_line_quiet_today_v1(uuid,date) from public,anon,authenticated;
grant execute on function public.server_tx_line_quiet_today_v1(uuid,date) to service_role;
