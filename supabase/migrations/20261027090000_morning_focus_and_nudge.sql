-- 朝のLINEで、朝やるべきことを見落とさない (owner request 2026-10-27).
--
-- Live: the 06:30 note was one long digest -- the morning chores sat among the evening list,
-- "余裕があれば", the partner's items and tomorrow's schedule -- and nothing reminded anyone
-- when 07:20 体操着 / 07:30 ゴミ出し actually came round. Two changes:
--  1. The scheduled morning note ('morning_focus') leads with 朝やること in time order, shows
--     the evening list as a count, and drops 余裕があれば and tomorrow (the evening note
--     carries those). The 今日 reply ('morning') and the PWA keep the full brief.
--  2. 朝の残り: once a workday at households.morning_nudge_local_time (default 07:30, null =
--     off) each adult gets ONE message listing what is still open from this morning, only if
--     something is. Nothing is sent when everything is done, so it costs at most one LINE
--     message per adult per workday (the household's free quota is 200 a month); the PWA push
--     goes out too when a device is registered. Codmon inputs are left to the 09:00 reminder.

alter table public.households
  add column morning_nudge_local_time time default time '07:30'
    check (morning_nudge_local_time is null
      or (morning_nudge_local_time >= time '05:00' and morning_nudge_local_time < time '11:00'));

-- p_settings keys (all optional): default_timed_reminders, default_all_day_reminders,
-- morning_nudge_local_time (the household's), schedule_line_with_push (the actor's own).
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
  result:=jsonb_build_object('ok',true);
  update private.mutation_receipts set result_type='reminder_settings',result_id=h,result_payload=result
  where actor_id=p_actor_id and operation_id=p_operation_id;
  return result;
end $$;
revoke all on function public.server_tx_update_reminder_settings(uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.server_tx_update_reminder_settings(uuid,uuid,jsonb) to service_role;

-- One time-ordered list for "what do I do this morning": the person's own tasks and the shared
-- ones nobody has taken, with the shared ones marked. (fn_line_task_groups_v1 groups by who, which
-- would put a 09:15 own task above a 07:00 shared one.)
create or replace function private.fn_line_task_timeline_v1(p_items jsonb, p_recipient text)
returns text language sql immutable security invoker set search_path = '' as $$
  select string_agg('・'
    || case when nullif(item->>'due_at','') is not null
         then to_char((item->>'due_at')::timestamptz at time zone 'Asia/Tokyo','HH24:MI')||' ' else '' end
    || coalesce(nullif(item->>'display_title',''),nullif(item->>'title',''),'確認が必要な項目')
    || case when item->>'assignment_mode'='anyone' and nullif(item->>'active_claimant_user_id','') is null
         then case when item->>'responsibility_hint'='先に家を出る人' then '（先に家を出る人）' else '（誰でもOK）' end
         else '' end,
    E'\n' order by (nullif(item->>'due_at','')::timestamptz) nulls last, ord)
  from jsonb_array_elements(coalesce(p_items,'[]'::jsonb)) with ordinality x(item,ord)
  where item->>'assignment_mode' is distinct from 'anyone'
    or nullif(item->>'active_claimant_user_id','') is null
    or p_recipient is null or item->>'active_claimant_user_id'=p_recipient;
$$;
revoke all on function private.fn_line_task_timeline_v1(jsonb,text) from public,anon,authenticated;
grant execute on function private.fn_line_task_timeline_v1(jsonb,text) to service_role;

create or replace function private.fn_render_daily_brief_text_v4(p_brief jsonb,p_mode text)
returns text language plpgsql immutable security invoker set search_path = '' as $$
declare
  -- 'morning_focus' is the scheduled 06:30 note: what to do this morning comes first,
  -- in time order, and the evening list is a count. 'morning' (the 今日 reply) stays full.
  focus boolean:=p_mode='morning_focus';
  mode text:=case when p_mode in ('morning','morning_focus') then 'morning' when p_mode in ('daytime','evening') then p_mode else 'daytime' end;
  body text:=case mode when 'morning' then '朝のおうちノート' when 'evening' then '夜のおうちノート' else '今日のおうちノート' end;
  part text; phase text; heading text; recipient text:=p_brief->>'display_recipient_user_id';
  all_tasks jsonb; partner_items jsonb; optional_items jsonb; tomorrow jsonb; tomorrow_date date; later_count integer;
begin
  part:=private.fn_daily_brief_urgent_lines_v2(p_brief->'urgent_actions');
  if part is not null then body:=body||E'\n\nまず確認\n'||part; end if;
  part:=private.fn_line_task_groups_v1(p_brief->'special_today',recipient,true);
  if part is not null then body:=body||E'\n\n⭐ 今日、忘れずに\n'||part; end if;
  if focus then
    part:=private.fn_line_task_timeline_v1(p_brief->'own_task_groups'->'morning',recipient);
    if part is not null then body:=body||E'\n\n⏰ 朝やること（時刻順）\n'||part; end if;
  end if;
  part:=private.fn_daily_brief_lines_v1(coalesce(p_brief->'exceptions','[]'::jsonb)||coalesce(p_brief->'carryovers','[]'::jsonb));
  if part is not null then body:=body||E'\n\nいつもと違うこと\n'||part; end if;
  part:=private.fn_daily_brief_lines_v1(p_brief->'schedule');
  if part is not null then body:=body||E'\n\n今日の予定\n'||part; end if;
  if mode='morning' then
    part:=private.fn_daily_brief_lines_v1(p_brief->'already_handled');
    if part is not null then body:=body||E'\n\nもう済んでいる\n'||part; end if;
  end if;
  part:=private.fn_daily_brief_lines_v1(p_brief->'waiting_checks');
  if part is not null then body:=body||E'\n\n待ち・確認\n'||part; end if;
  for phase in select unnest(array['morning','daytime','evening']) loop
    continue when focus and phase in ('morning','evening');
    heading:=case phase when 'morning' then case mode when 'morning' then '朝やること' else '朝の残り' end
      when 'daytime' then case mode when 'evening' then '日中の残り' when 'daytime' then '今やること' else '日中にやること' end
      else case mode when 'daytime' then 'このあと（夜）' else '夜にやること' end end;
    part:=private.fn_line_task_groups_v1(p_brief->'own_task_groups'->phase,recipient,focus);
    if part is not null then body:=body||E'\n\n'||heading||E'\n'||part; end if;
  end loop;
  part:=private.fn_daily_brief_handover_lines_v1(p_brief->'active_infos');
  if part is not null then body:=body||E'\n\n引き継ぎ・共有\n'||part; end if;
  if focus then
    later_count:=jsonb_array_length(coalesce(p_brief->'own_task_groups'->'evening','[]'::jsonb));
    if later_count>0 then body:=body||E'\n\n夜にやること\n・'||later_count||E'件（夜のおうちノートでお知らせします）'; end if;
  end if;
  select coalesce(jsonb_agg(item order by ord),'[]'::jsonb) into optional_items
  from jsonb_array_elements(coalesce(p_brief->'own_task_groups'->'optional','[]'::jsonb)) with ordinality x(item,ord)
  where nullif(item->>'active_claimant_user_id','') is null or recipient is null or item->>'active_claimant_user_id'=recipient;
  part:=case when focus then null else private.fn_line_task_lines_v1(optional_items,false,true) end;
  if part is not null then body:=body||E'\n\n余裕があれば\n'||part; end if;

  all_tasks:=coalesce(p_brief->'special_today','[]'::jsonb)||coalesce(p_brief->'own_task_groups'->'morning','[]'::jsonb)
    ||coalesce(p_brief->'own_task_groups'->'daytime','[]'::jsonb)||coalesce(p_brief->'own_task_groups'->'evening','[]'::jsonb)
    ||coalesce(p_brief->'own_task_groups'->'optional','[]'::jsonb);
  select coalesce(jsonb_agg(item order by ord),'[]'::jsonb) into partner_items
  from (select distinct on (coalesce(item->>'task_id',item->>'title')) item,ord
    from jsonb_array_elements(coalesce(p_brief->'partner_summary'->'critical_items','[]'::jsonb)||all_tasks) with ordinality x(item,ord)
    where ord<=jsonb_array_length(coalesce(p_brief->'partner_summary'->'critical_items','[]'::jsonb))
      or (recipient is not null and nullif(item->>'active_claimant_user_id','') is not null and item->>'active_claimant_user_id'<>recipient)
    order by coalesce(item->>'task_id',item->>'title'),ord) unique_items;
  part:=private.fn_line_task_lines_v1((select coalesce(jsonb_agg(item order by ord),'[]'::jsonb)
    from jsonb_array_elements(partner_items) with ordinality x(item,ord) where ord<=3));
  if part is not null then
    body:=body||E'\n\n相手の担当で確認したいこと\n'||part;
    if jsonb_array_length(partner_items)>3 then body:=body||E'\n・ほか '||(jsonb_array_length(partner_items)-3)::text||'件'; end if;
  end if;
  tomorrow:=coalesce(p_brief->'tomorrow_impact','{}'::jsonb);
  tomorrow_date:=nullif(tomorrow->>'local_date','')::date;
  part:=case when focus then null else private.fn_line_task_lines_v1(coalesce(tomorrow->'tasks','[]'::jsonb)||coalesce(tomorrow->'schedule','[]'::jsonb)
    ||coalesce(tomorrow->'carryovers','[]'::jsonb),true) end;
  if part is not null then
    heading:=case when tomorrow_date is null then '明日の予定・作業' else '明日 '||to_char(tomorrow_date,'FMMM/FMDD')
      ||'('||(array['月','火','水','木','金','土','日'])[extract(isodow from tomorrow_date)::int]||')の予定・作業' end;
    body:=body||E'\n\n'||heading||E'\n'||part;
  end if;
  if coalesce((p_brief#>>'{reconciliation,remaining_count}')::integer,0)>0 then
    body:=body||E'\n\n朝・夜の記録\n・未確認 '||(p_brief#>>'{reconciliation,remaining_count}')||'件';
  end if;
  if mode='evening' then
    part:=private.fn_daily_brief_lines_v1(p_brief->'shopping');
    if part is not null then body:=body||E'\n\n買い物\n'||part; end if;
  end if;
  return left(body,5000);
end $$;
revoke all on function private.fn_render_daily_brief_text_v4(jsonb,text) from public,anon,authenticated;
grant execute on function private.fn_render_daily_brief_text_v4(jsonb,text) to service_role;

-- The scheduled morning note uses the focused layout.
create or replace function public.server_tx_dispatch_daily_briefs(p_now timestamptz default now())
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_enabled boolean;
  r record;
  v_brief jsonb;
  v_receipt uuid;
  v_actor_ref uuid;
  v_dispatched int := 0;
  v_dedup text;
  v_mode text;
  v_body text;
  v_week text;
begin
  select writer_enabled and not mutation_paused and release_stage='P1' into v_enabled
  from private.canonical_capability_gates where capability='daily_brief_v2';
  if coalesce(v_enabled,false) is not true then
    return jsonb_build_object('enabled',false,'dispatched',0,'reason','CAPABILITY_NOT_AT_P1');
  end if;

  for r in select * from jsonb_to_recordset(public.server_read_due_daily_brief_slots(p_now)) as x(
    household_id uuid,recipient_user_id uuid,schedule_kind text,local_date date,
    local_time time,scheduled_at timestamptz,schedule_source text,dispatch_slot_key text
  ) loop
    v_receipt := null;
    insert into private.scheduled_dispatch_receipts(
      household_id,schedule_kind,scheduled_local_date,recipient_user_id,dispatch_slot_key
    ) values (r.household_id,r.schedule_kind,r.local_date,r.recipient_user_id,r.dispatch_slot_key)
    on conflict do nothing returning id into v_receipt;
    if v_receipt is null then continue; end if;

    v_brief := public.server_read_daily_brief(r.recipient_user_id,r.local_date);
    v_mode := case when r.schedule_kind='evening_brief' then 'evening' else 'morning' end;
    v_body := private.fn_render_daily_brief_text_v4(
      private.fn_daily_brief_for_line_v1(v_brief, r.recipient_user_id, r.scheduled_at, v_mode),
      case when v_mode='morning' then 'morning_focus' else v_mode end);

    v_week := null;
    if r.schedule_kind='nonworkday_morning_brief' and extract(isodow from r.local_date)=7 then
      begin
        v_week := private.fn_render_weekly_preview_v1(r.household_id, r.local_date + 1);
      exception when others then
        v_week := null; -- never lose the morning brief over the preview
      end;
      v_body := v_body || E'\n\n📅 来週の予定' || E'\n' || coalesce(v_week, '（登録された予定はありません）');
    end if;
    v_body := left(v_body, 5000); -- LINE text message limit

    select id into v_actor_ref from public.domain_actor_refs where household_id=r.household_id
      and actor_kind='real_user' and real_user_id=r.recipient_user_id;
    v_dedup := 'daily-brief:'||r.dispatch_slot_key;

    insert into public.user_notifications(
      household_id,recipient_user_id,type,title,body,payload,dedup_key,
      recipient_actor_ref_id,notification_kind,urgency,safety_class,bundle_key,
      business_expires_at,aggregate_type,aggregate_revision,test_context_id
    ) values (
      r.household_id,r.recipient_user_id,'daily_brief.v2',
      case when r.schedule_kind='evening_brief' then '夜のおうちノート' else '朝のおうちノート' end,
      v_body,
      jsonb_build_object('brief',v_brief,'schedule_kind',r.schedule_kind,
        'weekly_preview', v_week is not null),
      v_dedup,
      v_actor_ref,'daily_brief.v2','immediate','normal','daily-brief:'||r.recipient_user_id::text,
      r.scheduled_at+interval '8 hours','daily_brief',1,null
    ) on conflict(recipient_user_id,dedup_key) do nothing;
    v_dispatched := v_dispatched+1;
  end loop;

  return jsonb_build_object('enabled',true,'dispatched',v_dispatched);
end;
$$;
revoke all on function public.server_tx_dispatch_daily_briefs(timestamptz) from public, anon, authenticated;
grant execute on function public.server_tx_dispatch_daily_briefs(timestamptz) to service_role;

-- 朝の残り. Runs every minute from send-notifications; the window and the dedup key make it
-- one message per person per day even when the worker is late or runs twice.
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
      -- This person's open morning work: their own, shared ones nobody has taken, and ones they took.
      select coalesce(jsonb_agg(jsonb_build_object('task_id', t.id, 'title', t.title)
          order by t.due_at nulls last, t.title, t.id), '[]'::jsonb)
      into v_items
      from public.task_instances t
      left join public.task_definitions d on d.household_id = t.household_id and d.id = t.task_definition_id
      left join public.domain_actor_refs ar on ar.household_id = t.household_id
        and ar.id = t.active_claimant_actor_ref_id and ar.actor_kind = 'real_user' and ar.test_context_id is null
      where t.household_id = h.id and t.scheduled_date = v_date and t.test_context_id is null
        and t.status in ('todo', 'in_progress')
        and coalesce(t.expectation, 'normal') <> 'optional'
        and (t.routine_phase = 'morning' or t.due_at < v_noon)
        and coalesce(d.code, '') not like 'codmon%'
        and (t.planned_assignee_id = m.user_id or t.assignment_mode = 'anyone')
        and (ar.real_user_id is null or ar.real_user_id = m.user_id);
      continue when jsonb_array_length(v_items) = 0;
      v_part := private.fn_line_task_timeline_v1(private.fn_task_display_items_v1(h.id, v_items), m.user_id::text);
      continue when v_part is null;
      v_header := '⏰ 朝の残り（' || to_char(v_local, 'HH24:MI') || '）';
      v_message := v_header || E'\n' || v_part;  -- opens with the LINE item title, so it is shown once
      v_key := 'morning-nudge:' || v_date::text || ':' || m.user_id::text;
      v_note := null;
      insert into public.user_notifications(household_id, recipient_user_id, type, title, body, payload, dedup_key)
      values (h.id, m.user_id, 'morning_nudge', '朝の残り', v_message,
        jsonb_build_object('date', v_date, 'task_count', jsonb_array_length(v_items)), v_key)
      on conflict do nothing returning id into v_note;
      continue when v_note is null;
      perform public.server_tx_enqueue_web_push(h.id, m.user_id, '朝の残り', v_part, '/', 'morning-nudge', v_key, v_noon);
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
revoke all on function public.server_tx_dispatch_morning_nudges(timestamptz) from public, anon, authenticated;
grant execute on function public.server_tx_dispatch_morning_nudges(timestamptz) to service_role;
