-- #235: an unanswered LINE is not a record, and an unclaimed shared chore
-- must not be assigned to both adults. This helper is shared by enqueue and
-- revalidation; it performs no writes and works at a supplied clock instant.
create function private.fn_morning_nudge_lines_v2(p_household uuid,p_recipient uuid,p_day date,p_at timestamptz)
returns text language plpgsql stable security definer set search_path='' as $$
declare items jsonb; noon_at timestamptz; dropoff_assignee uuid;
begin
  if p_household is null or p_recipient is null or p_day is null or p_at is null then return null; end if;
  if not exists(select 1 from public.task_events e where e.household_id=p_household and e.actor_id=p_recipient
    and e.test_context_id is null and e.source in ('pwa','line','routine_editor')
    and e.event_type in ('completed','skipped','subtask_completed','subtask_completion_reverted','work_progress_recorded','completion_reverted')
    and e.created_at>=p_at-interval '7 days' and e.created_at<=p_at) then return null; end if;
  -- Only a single, genuinely agreed and person-assigned dropoff is definite.
  select case when count(*)=1 and bool_and(t.assignment_mode='person' and t.planned_assignee_id is not null
      and private.fn_task_assignment_consent_v1(p_household,t.planned_assignee_id,t.id))
    then (array_agg(t.planned_assignee_id))[1] end
    into dropoff_assignee from public.task_instances t
    join public.task_definitions d on d.household_id=t.household_id and d.id=t.task_definition_id
    where t.household_id=p_household and t.scheduled_date=p_day and t.test_context_id is null
      and d.code='dropoff' and t.status in ('todo','in_progress','completed');
  noon_at:=(p_day::timestamp+time '12:00') at time zone 'Asia/Tokyo';
  select coalesce(jsonb_agg(jsonb_build_object('task_id',t.id,'title',t.title) order by t.due_at nulls last,t.title,t.id),'[]'::jsonb)
    into items from public.task_instances t
    left join public.task_definitions d on d.household_id=t.household_id and d.id=t.task_definition_id
    left join public.domain_actor_refs ar on ar.household_id=t.household_id and ar.id=t.active_claimant_actor_ref_id
      and ar.actor_kind='real_user' and ar.test_context_id is null
    where t.household_id=p_household and t.scheduled_date=p_day and t.test_context_id is null
      and t.status in ('todo','in_progress') and coalesce(t.expectation,'normal')<>'optional'
      and (t.routine_phase='morning' or t.due_at<noon_at) and coalesce(d.code,'') not like 'codmon%'
      and ((t.assignment_mode='anyone' and (ar.real_user_id=p_recipient
            or (ar.real_user_id is null and dropoff_assignee is not null and dropoff_assignee<>p_recipient)))
        or (t.assignment_mode<>'anyone' and t.planned_assignee_id=p_recipient
            and private.fn_task_assignment_consent_v1(p_household,p_recipient,t.id)));
  if jsonb_array_length(items)=0 then return null; end if;
  return private.fn_line_task_timeline_v1(private.fn_task_display_items_v1(p_household,items),p_recipient::text);
end $$;
revoke all on function private.fn_morning_nudge_lines_v2(uuid,uuid,date,timestamptz) from public,anon,authenticated,service_role;
grant execute on function private.fn_morning_nudge_lines_v2(uuid,uuid,date,timestamptz) to service_role;

-- Enqueue and revalidation share one scope and one activity rule.
create or replace function public.server_tx_dispatch_morning_nudges(p_now timestamptz default now())
returns integer language plpgsql security invoker set search_path = '' as $$
declare
  v_local timestamp := p_now at time zone 'Asia/Tokyo';
  v_date date := (p_now at time zone 'Asia/Tokyo')::date;
  v_noon timestamptz := ((v_date + time '12:00') at time zone 'Asia/Tokyo');
  h record; m record; v_items jsonb; v_part text; v_message text; v_header text; v_key text; v_note uuid; v_sent integer := 0;
begin
  if private.is_jp_nonworkday(v_date) then return 0; end if;
  for h in
    select id, morning_nudge_local_time as nudge_at from public.households
    where morning_nudge_local_time is not null
      and v_local >= (v_date + morning_nudge_local_time)
      and v_local < (v_date + morning_nudge_local_time) + interval '45 minutes'
  loop
    for m in select user_id from public.household_members where household_id = h.id loop
      v_part:=private.fn_morning_nudge_lines_v2(h.id,m.user_id,v_date,p_now);
      continue when v_part is null;
      v_header := '⏰ まだのもの（' || to_char(v_local, 'HH24:MI') || '）';
      v_message := v_header || E'\n' || v_part;  -- opens with the LINE item title, so it is shown once
      v_key := 'morning-nudge:' || v_date::text || ':' || m.user_id::text;
      v_note := null;
      insert into public.user_notifications(household_id, recipient_user_id, type, title, body, payload, dedup_key)
      values (h.id, m.user_id, 'morning_nudge', 'まだのもの', v_message,
        jsonb_build_object('date', v_date, 'task_count', cardinality(string_to_array(v_part,E'\n'))), v_key)
      on conflict do nothing returning id into v_note;
      continue when v_note is null;
      perform public.server_tx_enqueue_web_push(h.id, m.user_id, 'まだのもの', v_part, '/', 'morning-nudge', v_key, v_noon);
      if exists (select 1 from public.notification_preferences
        where household_id = h.id and user_id = m.user_id and daily_assignment_line) then
        insert into private.notification_outbox(household_id, recipient_user_id, channel, type, payload, dedup_key, priority, business_expires_at)
        values (h.id, m.user_id, 'line', 'morning_nudge',
          jsonb_build_object('items', jsonb_build_array(jsonb_build_object('title', v_header, 'body', v_message))),
          v_key, 'reminder', p_now + interval '90 minutes') on conflict do nothing;
      end if;
      v_sent := v_sent + 1;
    end loop;
  end loop;
  return v_sent;
end $$;

create or replace function private.fn_consent_safe_nudge_lines_v1(p_household uuid,p_recipient uuid,p_day date)
returns text language plpgsql stable security definer set search_path='' as $$
begin
  if p_day is distinct from (now() at time zone 'Asia/Tokyo')::date then return null; end if;
  return private.fn_morning_nudge_lines_v2(p_household,p_recipient,p_day,now());
end $$;

-- Normalize queued old titles and repeat the same eligibility check at claim.
-- Keep unrelated bundled messages; do not release an ambiguous retry quota.
alter function public.server_tx_claim_notification_outbox_batch(text,int,int) rename to server_tx_claim_notification_before_respectful_nudge_v1;
revoke all on function public.server_tx_claim_notification_before_respectful_nudge_v1(text,int,int) from public,anon,authenticated,service_role;
create function public.server_tx_claim_notification_outbox_batch(p_worker_id text,p_limit int,p_lease_seconds int)
returns jsonb language plpgsql security definer set search_path='' as $$
declare raw jsonb; entry jsonb; item jsonb; kept jsonb; output jsonb:='[]'::jsonb; ordinal bigint;
  hh uuid; actor uuid; safe text; first_type text; day_text text; local_day date; changed boolean;
begin
  raw:=public.server_tx_claim_notification_before_respectful_nudge_v1(p_worker_id,p_limit,p_lease_seconds);
  for entry in select value from jsonb_array_elements(raw) loop
    if entry->>'type'<>'morning_nudge' or entry->>'priority'='critical'
      or jsonb_typeof(entry#>'{payload,items}') is distinct from 'array' then
      output:=output||jsonb_build_array(entry); continue;
    end if;
    hh:=(entry->>'household_id')::uuid; actor:=(entry->>'recipient_user_id')::uuid;
    day_text:=split_part(coalesce(entry->>'dedup_key',''),':',2); local_day:=null;
    if day_text ~ '^\d{4}-\d{2}-\d{2}$' then
      begin local_day:=day_text::date; exception when invalid_datetime_format or datetime_field_overflow then local_day:=null; end;
    end if;
    safe:=private.fn_consent_safe_nudge_lines_v1(hh,actor,local_day);
    kept:='[]'::jsonb; changed:=false;
    for item,ordinal in select value,ord from jsonb_array_elements(entry#>'{payload,items}') with ordinality x(value,ord) order by ord loop
      if ordinal=1 and (item->>'type'='morning_nudge'
        or (item->>'type' is null and coalesce(item->>'title','') ~ '^(⏰\s*)?(朝の残り|まだのもの)')) then
        changed:=true;
        if safe is null then continue; end if;
        item:=item||jsonb_build_object('title','まだのもの','body','まだのもの'||E'\n'||safe);
      end if;
      kept:=kept||jsonb_build_array(item);
    end loop;
    if changed and jsonb_array_length(kept)=0 then
      update private.notification_outbox set
        status=case when (entry->>'attempts')::int=1 and entry->>'quota_reservation_id' is null then 'fallback' else 'dead' end,
        last_error='no_recent_recorded_nudge',lease_owner=null,lease_token=null,lease_until=null
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

alter function public.server_tx_claim_web_push_batch(int,int) rename to server_tx_claim_web_push_before_respectful_nudge_v1;
revoke all on function public.server_tx_claim_web_push_before_respectful_nudge_v1(int,int) from public,anon,authenticated,service_role;
create function public.server_tx_claim_web_push_batch(p_limit int default 50,p_lease_seconds int default 60)
returns table(outbox_id uuid,subscription_id uuid,endpoint text,p256dh text,auth text,title text,body text,url text,tag text,attempts int,expires_at timestamptz)
language plpgsql security definer set search_path='' as $$
declare r record;
begin
  for r in select * from public.server_tx_claim_web_push_before_respectful_nudge_v1(p_limit,p_lease_seconds) loop
    if r.tag='morning-nudge' then r.title:='まだのもの'; end if;
    return query select r.outbox_id,r.subscription_id,r.endpoint,r.p256dh,r.auth,r.title,r.body,r.url,r.tag,r.attempts,r.expires_at;
  end loop;
end $$;
revoke all on function public.server_tx_claim_web_push_batch(int,int) from public,anon,authenticated;
grant execute on function public.server_tx_claim_web_push_batch(int,int) to service_role;
