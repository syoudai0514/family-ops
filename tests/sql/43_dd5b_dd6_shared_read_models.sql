-- WP-DD5B partial reader + WP-DD6 shared DailyBrief invariants.
\set ON_ERROR_STOP on

set role service_role;
do $$
declare
  v_owner uuid := gen_random_uuid();
  v_partner uuid := gen_random_uuid();
  v_hh jsonb;
  v_hh_id uuid;
  v_owner_actor uuid;
  v_item_id uuid;
  v_google_connection_id uuid;
  v_calendar_connection_id uuid;
  v_brief jsonb;
  v_shop jsonb;
  v_slots jsonb;
  v_resolved record;
begin
  insert into auth.users(id) values(v_owner),(v_partner);
  v_hh := public.server_tx_create_household(v_owner,gen_random_uuid(),'DD5B DD6 '||v_owner::text,'Owner');
  v_hh_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members(household_id,user_id,member_role)
  values(v_hh_id,v_partner,'adult');

  -- server_tx_create_household already creates the owner's canonical ActorRef.
  -- Do not re-run the legacy canonical backfill here: other SQL tests intentionally
  -- leave canonical RequestAttempts in the shared test DB, and a second backfill
  -- would try to synthesize legacy attempts for those already-canonical requests.
  select id into v_owner_actor from public.domain_actor_refs
  where household_id=v_hh_id and actor_kind='real_user' and real_user_id=v_owner;
  if v_owner_actor is null then
    raise exception 'FAIL DD5B/DD6: canonical owner ActorRef missing';
  end if;

  -- Official accepted schedule names only.
  insert into public.household_routine_schedules(
    household_id,schedule_kind,local_time,enabled,updated_by
  ) values
    (v_hh_id,'weekday_morning_brief',time '06:30',true,v_owner),
    (v_hh_id,'nonworkday_morning_brief',time '09:00',true,v_owner),
    (v_hh_id,'evening_brief',time '20:30',true,v_owner);

  select * into v_resolved
  from private.resolve_daily_brief_schedule(v_hh_id,date '2030-01-02','weekday_morning_brief');
  if v_resolved.local_time <> time '06:30' or v_resolved.source <> 'base_schedule' then
    raise exception 'FAIL DD6: weekday schedule resolution mismatch';
  end if;

  insert into public.household_routine_schedule_overrides(
    household_id,local_date,brief_kind,enabled,local_time,updated_by
  ) values
    (v_hh_id,date '2030-01-02','weekday_morning_brief',true,time '07:15',v_owner),
    (v_hh_id,date '2030-01-02','evening_brief',false,null,v_owner);

  select * into v_resolved
  from private.resolve_daily_brief_schedule(v_hh_id,date '2030-01-02','weekday_morning_brief');
  if v_resolved.local_time <> time '07:15' or v_resolved.source <> 'date_override' then
    raise exception 'FAIL DD6: one-day override not honored';
  end if;
  select * into v_resolved
  from private.resolve_daily_brief_schedule(v_hh_id,date '2030-01-02','evening_brief');
  if v_resolved.enabled or v_resolved.local_time is not null then
    raise exception 'FAIL DD6: disabled evening override still due';
  end if;

  -- A weekday after 07:15 JST has the overridden morning slot due, but the
  -- disabled evening slot is absent.
  v_slots := public.server_read_due_daily_brief_slots(timestamptz '2030-01-02 08:00:00+09');
  if not exists (
    select 1 from jsonb_array_elements(v_slots) e
    where e->>'household_id'=v_hh_id::text
      and e->>'recipient_user_id'=v_owner::text
      and e->>'schedule_kind'='weekday_morning_brief'
      and e->>'local_time'='07:15:00'
  ) then
    raise exception 'FAIL DD6: due weekday morning slot missing: %',v_slots;
  end if;
  if exists (
    select 1 from jsonb_array_elements(v_slots) e
    where e->>'household_id'=v_hh_id::text and e->>'schedule_kind'='evening_brief'
  ) then
    raise exception 'FAIL DD6: disabled evening slot emitted';
  end if;

  -- DD5B remains reader-first. Use the existing operational Shopping writer as
  -- fixture input, then attach canonical actual evidence already owned by #44.
  v_item_id := (public.server_tx_add_shopping_item(
    v_owner,gen_random_uuid(),'Milk','either',null,null,null
  )->>'shopping_item_id')::uuid;
  insert into public.shopping_actual_participants(
    household_id,shopping_item_id,actor_ref_id,recorded_by_actor_ref_id
  ) values(v_hh_id,v_item_id,v_owner_actor,v_owner_actor);

  v_shop := public.server_read_shopping_workspace(v_owner);
  if v_shop->>'writer_state' <> 'dependency_gap' then
    raise exception 'FAIL DD5B: partial writer dependency not explicit';
  end if;
  if not exists (
    select 1 from jsonb_array_elements(v_shop->'active') e
    where e->>'shopping_item_id'=v_item_id::text
      and (e->>'performer_count')::int=1
  ) then
    raise exception 'FAIL DD5B: Shopping actual evidence missing from reader: %',v_shop;
  end if;

  -- Actual Google all-day occurrence must remain date-only in DailyBrief.
  insert into private.google_connections(
    household_id,owner_user_id,google_subject,encrypted_refresh_token,
    encryption_version,scopes,status
  ) values(
    v_hh_id,v_owner,'dd6-'||v_owner::text,'ciphertext',1,array['calendar.readonly'],'active'
  ) returning id into v_google_connection_id;

  insert into public.calendar_connections(
    household_id,external_calendar_id,display_name,google_connection_id,active
  ) values(v_hh_id,'dd6-calendar-'||v_owner::text,'DD6',v_google_connection_id,true)
  returning id into v_calendar_connection_id;

  insert into public.calendar_event_occurrences(
    household_id,calendar_connection_id,occurrence_key,google_event_id,title,
    starts_at,ends_at,all_day_start,all_day_end_exclusive,status,transparency,
    projection_window_start,projection_window_end
  ) values(
    v_hh_id,v_calendar_connection_id,'all-day-'||v_owner::text,'event-'||v_owner::text,
    'School holiday',null,null,date '2030-01-02',date '2030-01-03','confirmed','opaque',
    date '2030-01-01',date '2030-01-10'
  );

  v_brief := public.server_read_daily_brief(v_owner,date '2030-01-02');
  if not exists (
    select 1 from jsonb_array_elements(v_brief->'schedule') e
    where e->>'title'='School holiday'
      and (e->>'is_all_day')::boolean
      and e->'starts_at'='null'::jsonb and e->'ends_at'='null'::jsonb
      and e->>'all_day_start'='2030-01-02'
  ) then
    raise exception 'FAIL DD6: all-day occurrence gained fake 00:00 timestamp: %',v_brief->'schedule';
  end if;

  if not exists (
    select 1 from jsonb_array_elements(v_brief->'shopping') e
    where e->>'shopping_item_id'=v_item_id::text
  ) then
    raise exception 'FAIL DD6: Shopping missing from shared DailyBrief';
  end if;
end;
$$;

reset role;
select 'dd5b_dd6_shared_read_models: PASS' as result;
