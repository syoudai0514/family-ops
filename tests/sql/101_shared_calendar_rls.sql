\set ON_ERROR_STOP on
insert into auth.users(id) values ('a2000000-0000-0000-0000-000000000001');
set role service_role;

do $$
declare
  u uuid := 'a2000000-0000-0000-0000-000000000001';
  h uuid; g uuid; a uuid; b uuid; d date := current_date;
begin
  h := (public.server_tx_create_household(u,gen_random_uuid(),'RLS calendar','Owner')->>'household_id')::uuid;
  insert into private.google_connections(
    household_id,owner_user_id,google_subject,encrypted_refresh_token,encryption_version,scopes,status
  ) values(h,u,'rls-calendar-test','cipher',1,array['calendar.events'],'active') returning id into g;

  insert into public.calendar_connections(
    household_id,external_calendar_id,google_connection_id,active,is_family_write_target
  ) values(h,'visible@example.invalid',g,true,true) returning id into a;
  insert into public.calendar_connections(
    household_id,external_calendar_id,google_connection_id,active,is_family_write_target
  ) values(h,'hidden@example.invalid',g,true,false) returning id into b;

  insert into public.calendar_event_occurrences(
    household_id,calendar_connection_id,occurrence_key,google_event_id,title,
    starts_at,ends_at,status,projection_window_start,projection_window_end
  ) values
    (h,a,'visible','visible','VISIBLE',now(),now()+interval '1 hour','confirmed',d-1,d+1),
    (h,b,'hidden','hidden','HIDDEN',now(),now()+interval '1 hour','confirmed',d-1,d+1);

  insert into public.calendar_events_cache(
    household_id,calendar_connection_id,google_event_id,title,status
  ) values
    (h,a,'visible','VISIBLE','confirmed'),
    (h,b,'hidden','HIDDEN','confirmed');
end;
$$;

reset role;
set role authenticated;
set request.jwt.claim.sub = 'a2000000-0000-0000-0000-000000000001';
set request.jwt.claim.role = 'authenticated';

do $$
declare n int;
begin
  select count(*) into n from public.calendar_event_occurrences;
  if n <> 1 or exists(select 1 from public.calendar_event_occurrences where title='HIDDEN') then
    raise exception 'FAIL occurrence visibility policy';
  end if;
  select count(*) into n from public.calendar_events_cache;
  if n <> 1 or exists(select 1 from public.calendar_events_cache where title='HIDDEN') then
    raise exception 'FAIL cache visibility policy';
  end if;
end;
$$;

reset role;
reset request.jwt.claim.sub;
reset request.jwt.claim.role;
select '101_shared_calendar_rls: PASS' as result;
