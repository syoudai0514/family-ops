\set ON_ERROR_STOP on
begin;
set local role service_role;

do $$
declare
  actor uuid:=gen_random_uuid();
  household uuid;
  actor_ref uuid;
  google_connection uuid;
  family_calendar uuid;
  private_calendar uuid;
  app_event uuid;
  notification uuid;
  day date:=(now() at time zone 'Asia/Tokyo')::date;
  noon timestamptz:=(day+time '12:00') at time zone 'Asia/Tokyo';
  brief jsonb;
  rendered text;
  mode text;
  priority_position integer;
  task_position integer;
begin
  insert into auth.users(id) values(actor);
  household:=(public.server_tx_create_household(actor,gen_random_uuid(),'Schedule priority test','A')->>'household_id')::uuid;
  select id into actor_ref from public.domain_actor_refs where household_id=household and real_user_id=actor and actor_kind='real_user';

  insert into private.google_connections(household_id,owner_user_id,google_subject,encrypted_refresh_token,encryption_version,scopes,status)
    values(household,actor,'schedule-priority-'||actor,'fixture',1,array['calendar.events'],'active') returning id into google_connection;
  insert into public.calendar_connections(household_id,provider,external_calendar_id,google_connection_id,active,is_family_write_target)
    values(household,'google','family@example.invalid',google_connection,true,true) returning id into family_calendar;
  insert into public.calendar_connections(household_id,provider,external_calendar_id,google_connection_id,active,is_family_write_target)
    values(household,'google','personal@example.invalid',google_connection,true,false) returning id into private_calendar;
  insert into public.family_events(household_id,title,status,all_day,starts_at,ends_at,calendar_sync_preference,created_by_actor_ref_id)
    values(household,'家族の面談','active',false,noon+interval '2 hours',noon+interval '3 hours','external_follow',actor_ref) returning id into app_event;
  insert into public.family_event_external_links(household_id,family_event_id,calendar_connection_id,google_event_id,link_mode)
    values(household,app_event,family_calendar,'mirror','external_follow');
  insert into public.calendar_event_occurrences(household_id,calendar_connection_id,occurrence_key,google_event_id,title,starts_at,ends_at,
    all_day_start,all_day_end_exclusive,status,transparency,projection_window_start,projection_window_end)
    values
      (household,family_calendar,'timed','timed','園の持ち物',noon,noon+interval '90 minutes',null,null,'confirmed','opaque',day-1,day+1),
      (household,family_calendar,'allday','allday','終日イベント',day::timestamp at time zone 'Asia/Tokyo',(day+1)::timestamp at time zone 'Asia/Tokyo',day,day+1,'confirmed','opaque',day-1,day+1),
      (household,family_calendar,'mirror','mirror','家族の面談',noon+interval '2 hours',noon+interval '3 hours',null,null,'confirmed','opaque',day-1,day+1),
      (household,family_calendar,'cancelled','cancelled','取り消された予定',noon,noon+interval '1 hour',null,null,'cancelled','opaque',day-1,day+1),
      (household,private_calendar,'private','private','個人の予定',noon,noon+interval '1 hour',null,null,'confirmed','opaque',day-1,day+1);

  brief:=public.server_read_daily_brief(actor,day)||jsonb_build_object(
    'urgent_actions',jsonb_build_array(jsonb_build_object('kind','assignment_needed','title','担当を確認する作業')),
    'special_today',jsonb_build_array(jsonb_build_object('title','その日だけの作業')),
    'own_task_groups',jsonb_build_object('morning',jsonb_build_array(jsonb_build_object('title','朝の日課')),
      'evening',jsonb_build_array(jsonb_build_object('title','夜の日課'))));

  foreach mode in array array['morning_focus','morning','daytime','evening'] loop
    rendered:=private.fn_render_daily_brief_text_v4(brief,mode);
    priority_position:=position('⭐ 今日の予定' in rendered);
    task_position:=position(case when mode='evening' then '夜の日課' else '朝の日課' end in rendered);
    if position('まず確認' in rendered)=0 or position('まず確認' in rendered)>=priority_position
      or priority_position=0 or task_position<=priority_position
      or position('⭐ 今日だけの予定' in rendered)<=priority_position
      or rendered not like E'%⭐ 今日の予定\n・終日 終日イベント\n・12:00 園の持ち物\n・14:00 家族の面談%'
      or rendered like '%個人の予定%' or rendered like '%取り消された予定%'
      or (length(rendered)-length(replace(rendered,'家族の面談','')))<>length('家族の面談') then
      raise exception 'schedule priority or visibility failed in %: %',mode,rendered;
    end if;
  end loop;

  rendered:=public.server_read_line_today_daily_brief(actor);
  if rendered not like E'%⭐ 今日の予定\n・終日 終日イベント\n・12:00 園の持ち物%' then
    raise exception 'LINE 今日 reader dropped the schedule: %',rendered;
  end if;
  rendered:=private.fn_render_daily_brief_text_v4(brief-'schedule','morning_focus');
  if position('⭐ 今日の予定' in rendered)>0 or position('朝の日課' in rendered)=0 then
    raise exception 'empty schedule affected other sections: %',rendered;
  end if;

  insert into public.user_notifications(household_id,recipient_user_id,type,title,body,payload,dedup_key)
    values(household,actor,'daily_brief.v2','朝のおうちノート','以前の表示',jsonb_build_object('brief',brief),'schedule-priority-old-note')
    returning id into notification;
  reset role;
  rendered:=private.fn_consent_safe_daily_text_v1(household,actor,notification);
  if rendered is null or rendered not like '%⭐ 今日の予定%12:00 園の持ち物%朝の日課%' then
    raise exception 'queued note did not adopt calendar priority: %',rendered;
  end if;
end $$;

rollback;
select 'line_calendar_schedule_priority: PASS' as result;
