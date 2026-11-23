-- Issue #196: quiet delivery is personal, and reflects deliberate actions only.
-- The snapshot is the beginning of the current Tokyo day: a return to activity
-- takes effect the following morning, not halfway through a notification day.
alter table public.notification_preferences
  add column quiet_mode text not null default 'auto' check (quiet_mode in ('auto','quiet','normal'));

create index quiet_activity_task_events_idx on public.task_events (actor_id,created_at desc)
  where test_context_id is null;
create index quiet_activity_mutation_receipts_idx on private.mutation_receipts (actor_id,created_at desc)
  where test_context_id is null;
create index quiet_activity_canonical_receipts_idx on private.canonical_operation_receipts (operator_user_id,created_at desc)
  where test_context_id is null and completed_at is not null;
create index quiet_activity_line_inbox_idx on private.webhook_inbox (source_external_user_id,received_at desc)
  where provider='line' and payload->>'type' in ('message','postback');

create function private.fn_recipient_quiet_mode_v1(p_household uuid,p_user uuid,p_at timestamptz)
returns boolean language plpgsql stable security definer set search_path='' as $$
declare preference text; day_start timestamptz; active boolean;
begin
  select n.quiet_mode into preference from public.notification_preferences n
    where n.household_id=p_household and n.user_id=p_user;
  -- Unknown or non-member recipients retain existing delivery behaviour.
  if preference is null or p_at is null then return false; end if;
  if preference='quiet' then return true; end if;
  if preference='normal' then return false; end if;
  day_start:=date_trunc('day',p_at at time zone 'Asia/Tokyo') at time zone 'Asia/Tokyo';
  select exists (
    select 1 from private.line_user_links l join private.webhook_inbox w
      on w.provider='line' and w.source_external_user_id=l.line_user_id
      and w.payload->>'type' in ('message','postback')
      and w.received_at>=l.linked_at and w.received_at>=day_start-interval '7 days' and w.received_at<day_start
    where l.household_id=p_household and l.user_id=p_user and l.status='active'
    union all
    select 1 from public.task_events e where e.household_id=p_household and e.actor_id=p_user
      and e.test_context_id is null and e.source in ('pwa','line','routine_editor')
      and e.event_type in ('completed','skipped','subtask_completed','subtask_uncompleted','work_progress_recorded','completion_reverted','assignment_changed')
      and e.created_at>=day_start-interval '7 days' and e.created_at<day_start
    union all
    select 1 from private.mutation_receipts r where r.actor_id=p_user and r.test_context_id is null
      and r.result_payload is not null and r.created_at>=day_start-interval '7 days' and r.created_at<day_start
    union all
    select 1 from private.canonical_operation_receipts c join public.domain_actor_refs ar
      on ar.household_id=c.household_id and ar.id=c.actor_ref_id and ar.actor_kind='real_user'
      and ar.real_user_id=p_user and ar.test_context_id is null
    where c.household_id=p_household and c.operator_user_id=p_user and c.test_context_id is null
      and c.completed_at is not null and c.created_at>=day_start-interval '7 days' and c.created_at<day_start
      and (c.action_type like 'shopping.%' or c.action_type in ('assignment.review','checklist.complete','checklist.undo','task.progress.record'))
  ) into active;
  return not active;
end $$;
revoke all on function private.fn_recipient_quiet_mode_v1(uuid,uuid,timestamptz) from public,anon,authenticated,service_role;

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
    elsif key='quiet_mode' then
      if jsonb_typeof(p_settings->key)<>'string' or p_settings->>key not in ('auto','quiet','normal') then raise exception 'INVALID_INPUT'; end if;
    elsif key='morning_nudge_local_time' then
      -- null = off; otherwise a time between 05:00 and 10:59.
      if jsonb_typeof(p_settings->key)<>'null' and (jsonb_typeof(p_settings->key)<>'string'
        or (p_settings->>key) !~ '^(0[5-9]|10):[0-5][0-9]$') then raise exception 'INVALID_INPUT'; end if;
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
  if p_settings ? 'morning_nudge_local_time' then
    update public.households set morning_nudge_local_time=nullif(p_settings->>'morning_nudge_local_time','')::time where id=h;
  end if;
  if p_settings ? 'schedule_line_with_push' then
    update public.notification_preferences set schedule_line_with_push=(p_settings->>'schedule_line_with_push')::boolean
    where household_id=h and user_id=p_actor_id;
  end if;
  if p_settings ? 'quiet_mode' then
    update public.notification_preferences set quiet_mode=p_settings->>'quiet_mode'
    where household_id=h and user_id=p_actor_id;
  end if;
  result:=jsonb_build_object('ok',true);
  update private.mutation_receipts set result_type='reminder_settings',result_id=h,result_payload=result
  where actor_id=p_actor_id and operation_id=p_operation_id;
  return result;
end $$;

-- Only shared calendar information, special family events and transport are
-- shown here. Consent remains a separate decision and is never inferred.
create function private.fn_quiet_calendar_day_v1(p_household uuid,p_user uuid,p_day date)
returns text language plpgsql stable security definer set search_path='' as $$
declare dropoff text; pickup text; special text; calendar_lines text; content text;
begin
  select case when t.planned_assignee_id=p_user and t.recurrence_rule_id is not null
      and not private.fn_task_assignment_consent_v1(p_household,p_user,t.id) then '相談中'
      else regexp_replace(coalesce(p.display_name,'未定'),'（仮）$','') end
    into dropoff from public.task_instances t
    join public.task_definitions d on d.household_id=t.household_id and d.id=t.task_definition_id
    left join public.profiles p on p.user_id=t.planned_assignee_id
    where t.household_id=p_household and t.scheduled_date=p_day and t.test_context_id is null
      and d.code='dropoff' and t.status in ('todo','in_progress') order by t.id limit 1;
  select case when t.planned_assignee_id=p_user and t.recurrence_rule_id is not null
      and not private.fn_task_assignment_consent_v1(p_household,p_user,t.id) then '相談中'
      else regexp_replace(coalesce(p.display_name,'未定'),'（仮）$','') end
    into pickup from public.task_instances t
    join public.task_definitions d on d.household_id=t.household_id and d.id=t.task_definition_id
    left join public.profiles p on p.user_id=t.planned_assignee_id
    where t.household_id=p_household and t.scheduled_date=p_day and t.test_context_id is null
      and d.code='pickup' and t.status in ('todo','in_progress') order by t.id limit 1;
  select string_agg('・'||t.title,E'\n' order by t.due_at nulls last,t.title,t.id) into special
    from public.task_instances t
    where t.household_id=p_household and t.scheduled_date=p_day and t.test_context_id is null
      and t.calendar_visibility='special' and t.status in ('todo','in_progress')
      and (t.planned_assignee_id is distinct from p_user or t.recurrence_rule_id is null
        or private.fn_task_assignment_consent_v1(p_household,p_user,t.id));
  calendar_lines:=private.fn_calendar_day_lines(p_household,p_day);
  calendar_lines:=private.fn_weekly_preview_lines_v1(calendar_lines,special,null,dropoff is not null or pickup is not null);
  content:=case when dropoff is not null or pickup is not null
    then '送り '||coalesce(dropoff,'-')||' / 迎え '||coalesce(pickup,'-') else null end;
  return nullif(concat_ws(E'\n',content,calendar_lines),'');
end $$;
revoke all on function private.fn_quiet_calendar_day_v1(uuid,uuid,date) from public,anon,authenticated,service_role;

create function private.fn_quiet_morning_text_v1(p_household uuid,p_user uuid,p_day date)
returns text language plpgsql stable security definer set search_path='' as $$
declare content text; day_content text; requests text; d date; all_days text:='';
begin
  if extract(isodow from p_day)=7 then
    for d in select x::date from generate_series(p_day+1,p_day+7,interval '1 day') x loop
      day_content:=private.fn_quiet_calendar_day_v1(p_household,p_user,d);
      if day_content is not null then
        all_days:=all_days||case when all_days='' then '' else E'\n\n' end
          ||to_char(d,'FMMM/FMDD')||'('||(array['月','火','水','木','金','土','日'])[extract(isodow from d)::int]||')'
          ||E'\n'||day_content;
      end if;
    end loop;
    if all_days='' then return null; end if;
    return left('おはようございます。来週の予定です。'||E'\n\n'||all_days,5000);
  end if;
  content:=private.fn_quiet_calendar_day_v1(p_household,p_user,p_day);
  select string_agg('・'||r.shared_title,E'\n' order by r.created_at,r.id) into requests
    from public.requests r where r.household_id=p_household and r.recipient_id=p_user
      and r.requester_id<>p_user and r.status='pending' and r.test_context_id is null;
  if content is null and requests is null then return null; end if;
  return left('おはようございます。'||E'\n\n'||concat_ws(E'\n\n',content,
    case when requests is not null then '家族からのお願い'||E'\n'||requests end),5000);
end $$;
revoke all on function private.fn_quiet_morning_text_v1(uuid,uuid,date) from public,anon,authenticated,service_role;

-- This BEFORE INSERT is shared by LINE and the associated web-push path.
-- Essential/non-normal notices and unrelated notification types pass through.
create function private.fn_apply_auto_quiet_notification_v1()
returns trigger language plpgsql security definer set search_path='' as $$
declare day_text text; local_day date; safe text;
begin
  if new.test_context_id is not null or new.safety_class is distinct from 'normal'
      or not private.fn_recipient_quiet_mode_v1(new.household_id,new.recipient_user_id,now()) then return new; end if;
  if new.type in ('morning_nudge','codmon.deadline') then return null; end if;
  if new.type<>'daily_brief.v2' then return new; end if;
  if new.title='夜のおうちノート' then return null; end if;
  if new.title<>'朝のおうちノート' then return new; end if;
  day_text:=new.payload#>>'{brief,local_date}';
  if day_text is null or day_text !~ '^\d{4}-\d{2}-\d{2}$' then return null; end if;
  begin local_day:=day_text::date; exception when invalid_datetime_format or datetime_field_overflow then return null; end;
  safe:=private.fn_quiet_morning_text_v1(new.household_id,new.recipient_user_id,local_day);
  if safe is null then return null; end if;
  new.body:=safe;
  new.payload:=new.payload||jsonb_build_object('quiet_mode',true);
  return new;
end $$;
revoke all on function private.fn_apply_auto_quiet_notification_v1() from public,anon,authenticated,service_role;
create trigger apply_auto_quiet_notification before insert on public.user_notifications
  for each row execute function private.fn_apply_auto_quiet_notification_v1();

-- Re-evaluate already queued items at claim time. Preserve unrelated bundled
-- requests, and never release a quota reservation on an ambiguous retry.
alter function public.server_tx_claim_notification_outbox_batch(text,int,int) rename to server_tx_claim_notification_before_auto_quiet_v1;
revoke all on function public.server_tx_claim_notification_before_auto_quiet_v1(text,int,int) from public,anon,authenticated,service_role;
create function public.server_tx_claim_notification_outbox_batch(p_worker_id text,p_limit int,p_lease_seconds int)
returns jsonb language plpgsql security definer set search_path='' as $$
declare raw jsonb; entry jsonb; item jsonb; kept jsonb; output jsonb:='[]'::jsonb; hh uuid; actor uuid;
  note public.user_notifications%rowtype; note_id uuid; ordinal bigint; first_type text; safe text; day_text text; local_day date;
  item_type text; should_remove boolean; changed boolean;
begin
  raw:=public.server_tx_claim_notification_before_auto_quiet_v1(p_worker_id,p_limit,p_lease_seconds);
  for entry in select value from jsonb_array_elements(raw) loop
    hh:=(entry->>'household_id')::uuid; actor:=(entry->>'recipient_user_id')::uuid;
    if entry->>'priority'='critical' or not private.fn_recipient_quiet_mode_v1(hh,actor,now())
      or jsonb_typeof(entry#>'{payload,items}') is distinct from 'array' then
      output:=output||jsonb_build_array(entry); continue;
    end if;
    kept:='[]'::jsonb; changed:=false;
    for item,ordinal in select value,ord from jsonb_array_elements(entry#>'{payload,items}') with ordinality x(value,ord) order by ord loop
      item_type:=coalesce(nullif(item->>'type',''),case when ordinal=1 then entry->>'type' end);
      note_id:=null; note:=null; should_remove:=false;
      if coalesce(item->>'user_notification_id','') ~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$' then
        note_id:=(item->>'user_notification_id')::uuid;
        select * into note from public.user_notifications n where n.id=note_id
          and n.household_id=hh and n.recipient_user_id=actor and n.test_context_id is null;
      end if;
      if item_type='morning_nudge' and (note_id is null or note.safety_class='normal') then
        should_remove:=true;
      elsif item_type='codmon.deadline' and note.safety_class='normal' then
        should_remove:=true;
      elsif item_type='daily_brief.v2' and note.safety_class='normal' then
        if note.title='夜のおうちノート' then should_remove:=true;
        elsif note.title='朝のおうちノート' then
          day_text:=note.payload#>>'{brief,local_date}'; local_day:=null;
          if day_text ~ '^\d{4}-\d{2}-\d{2}$' then
            begin local_day:=day_text::date; exception when invalid_datetime_format or datetime_field_overflow then local_day:=null; end;
          end if;
          safe:=case when local_day is not null then private.fn_quiet_morning_text_v1(hh,actor,local_day) else null end;
          if safe is null then should_remove:=true;
          else item:=item||jsonb_build_object('body',safe,'quiet_mode',true); changed:=true; end if;
        end if;
      end if;
      if should_remove then changed:=true; continue; end if;
      kept:=kept||jsonb_build_array(item);
    end loop;
    if changed and jsonb_array_length(kept)=0 then
      update private.notification_outbox set
        status=case when (entry->>'attempts')::int=1 and entry->>'quota_reservation_id' is null then 'fallback' else 'dead' end,
        last_error='automatic_quiet_mode',lease_owner=null,lease_token=null,lease_until=null
        where id=(entry->>'id')::uuid and status='sending';
      continue;
    end if;
    first_type:=coalesce(nullif(kept->0->>'type',''),entry->>'type');
    if first_type is distinct from entry->>'type' then changed:=true; end if;
    if changed then
      entry:=jsonb_set(jsonb_set(entry,'{payload,items}',kept,true),'{type}',to_jsonb(first_type),true);
    end if;
    output:=output||jsonb_build_array(entry);
  end loop;
  return output;
end $$;
revoke all on function public.server_tx_claim_notification_outbox_batch(text,int,int) from public,anon,authenticated;
grant execute on function public.server_tx_claim_notification_outbox_batch(text,int,int) to service_role;

alter function public.server_tx_claim_web_push_batch(int,int) rename to server_tx_claim_web_push_before_auto_quiet_v1;
revoke all on function public.server_tx_claim_web_push_before_auto_quiet_v1(int,int) from public,anon,authenticated,service_role;
create function public.server_tx_claim_web_push_batch(p_limit int default 50,p_lease_seconds int default 60)
returns table(outbox_id uuid,subscription_id uuid,endpoint text,p256dh text,auth text,title text,body text,url text,tag text,attempts int,expires_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare r record; meta private.web_push_outbox%rowtype;
begin
  for r in select * from public.server_tx_claim_web_push_before_auto_quiet_v1(p_limit,p_lease_seconds) loop
    if r.tag='morning-nudge' then
      select * into meta from private.web_push_outbox o where o.id=r.outbox_id;
      if private.fn_recipient_quiet_mode_v1(meta.household_id,meta.recipient_user_id,now()) then
        update private.web_push_outbox o set status='dead',lease_until=null,last_error='automatic_quiet_mode'
          where o.id=r.outbox_id and o.status='processing';
        continue;
      end if;
    end if;
    return query select r.outbox_id,r.subscription_id,r.endpoint,r.p256dh,r.auth,r.title,r.body,r.url,r.tag,r.attempts,r.expires_at;
  end loop;
end $$;
revoke all on function public.server_tx_claim_web_push_batch(int,int) from public,anon,authenticated;
grant execute on function public.server_tx_claim_web_push_batch(int,int) to service_role;
