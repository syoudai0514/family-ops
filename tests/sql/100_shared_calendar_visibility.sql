-- Only the selected family Google calendar may expose event details.
\set ON_ERROR_STOP on

insert into auth.users(id) values ('a1000000-0000-0000-0000-000000000001');
set role service_role;

do $$
declare
  u uuid := 'a1000000-0000-0000-0000-000000000001';
  h uuid; g uuid; shared_id uuid; other_id uuid;
  d date := (now() at time zone 'Asia/Tokyo')::date;
  r jsonb; b jsonb; lines text;
begin
  h := (public.server_tx_create_household(u,gen_random_uuid(),'Visibility HH','Owner')->>'household_id')::uuid;
  insert into public.domain_actor_refs(household_id,actor_kind,real_user_id)
  values(h,'real_user',u)
  on conflict (household_id,real_user_id) where actor_kind='real_user' do nothing;

  insert into private.google_connections(
    household_id,owner_user_id,google_subject,encrypted_refresh_token,encryption_version,scopes,status
  ) values(h,u,'visibility-test','cipher',1,array['calendar.events'],'active')
  returning id into g;

  insert into public.calendar_connections(
    household_id,external_calendar_id,display_name,google_connection_id,active,
    last_incremental_sync_at,reauth_required,is_family_write_target
  ) values(h,'shared@example.invalid','Shared',g,true,now(),false,true)
  returning id into shared_id;

  insert into public.calendar_connections(
    household_id,external_calendar_id,display_name,google_connection_id,active,
    last_incremental_sync_at,reauth_required,is_family_write_target
  ) values(h,'other@example.invalid','Other',g,true,now(),false,false)
  returning id into other_id;

  insert into public.calendar_event_occurrences(
    household_id,calendar_connection_id,occurrence_key,google_event_id,title,
    starts_at,ends_at,status,transparency,projection_window_start,projection_window_end
  ) values
  (h,shared_id,'shared-occ','shared-event','共有予定',
   (d::text||' 15:00')::timestamp at time zone 'Asia/Tokyo',
   (d::text||' 16:00')::timestamp at time zone 'Asia/Tokyo',
   'confirmed','opaque',d-1,d+7),
  (h,other_id,'other-occ','other-event','非共有予定',
   (d::text||' 08:00')::timestamp at time zone 'Asia/Tokyo',
   (d::text||' 09:00')::timestamp at time zone 'Asia/Tokyo',
   'confirmed','opaque',d-1,d+7);

  insert into public.calendar_occurrence_busy_members(
    household_id,calendar_connection_id,occurrence_key,user_id,source
  ) values(h,other_id,'other-occ',u,'manual');

  r := public.server_tx_get_today_schedule(u);
  if not exists(select 1 from jsonb_array_elements(r->'occurrences') x where x->>'title'='共有予定')
     or exists(select 1 from jsonb_array_elements(r->'occurrences') x where x->>'title'='非共有予定') then
    raise exception 'FAIL shared visibility: Today';
  end if;

  r := public.server_tx_get_week_schedule(u,d,d+6);
  if not exists(select 1 from jsonb_array_elements(r->'occurrences') x where x->>'title'='共有予定')
     or exists(select 1 from jsonb_array_elements(r->'occurrences') x where x->>'title'='非共有予定') then
    raise exception 'FAIL shared visibility: Week';
  end if;

  b := public.server_read_daily_brief(u,d);
  if not exists(select 1 from jsonb_array_elements(b->'schedule') x where x->>'title'='共有予定')
     or exists(select 1 from jsonb_array_elements(b->'schedule') x where x->>'title'='非共有予定') then
    raise exception 'FAIL shared visibility: DailyBrief';
  end if;

  lines := private.fn_calendar_day_lines(h,d);
  if position('共有予定' in coalesce(lines,''))=0
     or position('非共有予定' in coalesce(lines,''))>0 then
    raise exception 'FAIL shared visibility: legacy lines';
  end if;

  if not private.fn_calendar_conflict_exists(
    h,u,(d::text||' 08:30')::timestamp at time zone 'Asia/Tokyo',60
  ) then
    raise exception 'FAIL shared visibility: busy detection';
  end if;
end;
$$;

reset role;
select '100_shared_calendar_visibility: PASS' as result;
