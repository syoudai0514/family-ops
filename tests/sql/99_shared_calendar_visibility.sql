\set ON_ERROR_STOP on
insert into auth.users(id) values ('a3000000-0000-0000-0000-000000000001');
set role service_role;
do $$
declare
  u uuid := 'a3000000-0000-0000-0000-000000000001';
  h uuid; g uuid; shared_id uuid; other_id uuid;
  d date := (now() at time zone 'Asia/Tokyo')::date;
  r jsonb; b jsonb;
begin
  h := (public.server_tx_create_household(u,gen_random_uuid(),'Visibility regression','Owner')->>'household_id')::uuid;
  insert into public.domain_actor_refs(household_id,actor_kind,real_user_id)
  values(h,'real_user',u)
  on conflict (household_id,real_user_id) where actor_kind='real_user' do nothing;

  insert into private.google_connections(
    household_id,owner_user_id,google_subject,encrypted_refresh_token,encryption_version,scopes,status
  ) values(h,u,'visibility-regression-99','cipher',1,array['calendar.events'],'active')
  returning id into g;

  insert into public.calendar_connections(
    household_id,external_calendar_id,google_connection_id,active,last_incremental_sync_at,reauth_required,is_family_write_target
  ) values(h,'shared99@example.invalid',g,true,now(),false,true) returning id into shared_id;

  insert into public.calendar_connections(
    household_id,external_calendar_id,google_connection_id,active,last_incremental_sync_at,reauth_required,is_family_write_target
  ) values(h,'other99@example.invalid',g,true,now(),false,false) returning id into other_id;

  insert into public.calendar_event_occurrences(
    household_id,calendar_connection_id,occurrence_key,google_event_id,title,
    starts_at,ends_at,status,transparency,projection_window_start,projection_window_end
  ) values
  (h,shared_id,'shared99','shared99','SHARED99',
   (d::text||' 15:00')::timestamp at time zone 'Asia/Tokyo',
   (d::text||' 16:00')::timestamp at time zone 'Asia/Tokyo','confirmed','opaque',d-1,d+7),
  (h,other_id,'other99','other99','OTHER99',
   (d::text||' 08:00')::timestamp at time zone 'Asia/Tokyo',
   (d::text||' 09:00')::timestamp at time zone 'Asia/Tokyo','confirmed','opaque',d-1,d+7);

  insert into public.calendar_occurrence_busy_members(
    household_id,calendar_connection_id,occurrence_key,user_id,source
  ) values(h,other_id,'other99',u,'manual');

  r := public.server_tx_get_today_schedule(u);
  if not exists(select 1 from jsonb_array_elements(r->'occurrences') x where x->>'title'='SHARED99')
     or exists(select 1 from jsonb_array_elements(r->'occurrences') x where x->>'title'='OTHER99') then
    raise exception 'FAIL calendar visibility Today';
  end if;

  r := public.server_tx_get_week_schedule(u,d,d+6);
  if exists(select 1 from jsonb_array_elements(r->'occurrences') x where x->>'title'='OTHER99') then
    raise exception 'FAIL calendar visibility Week';
  end if;

  b := public.server_read_daily_brief(u,d);
  if exists(select 1 from jsonb_array_elements(b->'schedule') x where x->>'title'='OTHER99') then
    raise exception 'FAIL calendar visibility DailyBrief';
  end if;

  if position('OTHER99' in coalesce(private.fn_calendar_day_lines(h,d),''))>0 then
    raise exception 'FAIL calendar visibility legacy';
  end if;

  if not private.fn_calendar_conflict_exists(
    h,u,(d::text||' 08:30')::timestamp at time zone 'Asia/Tokyo',60
  ) then
    raise exception 'FAIL calendar visibility busy';
  end if;
end;
$$;
reset role;
select '99_shared_calendar_visibility: PASS' as result;
