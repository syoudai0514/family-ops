-- WP-DD8: explicit special-Task mirror adoption keeps the exact provider
-- identity/ETag, disables both old mutation paths, and never activates a
-- Family Event Google writer as part of source readiness.

\set ON_ERROR_STOP on
set role service_role;

do $$
declare
  v_owner uuid := '10000000-0000-0000-0000-000000000046';
  v_household uuid;
  v_owner_ref uuid;
  v_google_connection uuid;
  v_calendar_connection uuid;
  v_task uuid;
  v_event uuid;
  v_result jsonb;
begin
  insert into auth.users (id) values (v_owner) on conflict do nothing;
  insert into public.profiles (user_id,display_name) values (v_owner,'DD8 owner') on conflict do nothing;
  v_household := (public.server_tx_create_household(
    v_owner,'20000000-0000-0000-0000-000000000046','DD8 household','Asia/Tokyo'
  )->>'household_id')::uuid;
  select id into v_owner_ref from public.domain_actor_refs
  where household_id=v_household and actor_kind='real_user' and real_user_id=v_owner;

  insert into private.google_connections(
    household_id,owner_user_id,google_subject,encrypted_refresh_token,encryption_version,scopes,status
  ) values (
    v_household,v_owner,'dd8-google-subject','cipher',1,
    array['https://www.googleapis.com/auth/calendar.events'],'active'
  ) returning id into v_google_connection;
  insert into public.calendar_connections(
    household_id,provider,external_calendar_id,google_connection_id,active,reauth_required
  ) values (
    v_household,'google','dd8@example.test',v_google_connection,true,false
  ) returning id into v_calendar_connection;

  insert into public.task_instances(
    household_id,origin,title,category,routine_phase,scheduled_date,
    planned_assignee_id,completion_mode,status,source,created_by,calendar_visibility
  ) values (
    v_household,'manual','保護者会','school','anytime','2030-02-01',
    v_owner,'whole','todo','test',v_owner,'special'
  ) returning id into v_task;
  insert into private.family_ops_calendar_mirrors(
    household_id,projection_key,kind,local_date,task_instance_id,calendar_connection_id,
    provider_event_id,provider_etag,desired_action,sync_state,ownership_transfer_state
  ) values (
    v_household,'special:'||v_task::text,'special','2030-02-01',v_task,v_calendar_connection,
    'dd8-provider-event','etag-dd8','upsert','synced','task_owned'
  );
  insert into private.family_ops_calendar_target_deletions(
    household_id,calendar_connection_id,projection_key,provider_event_id,sync_state,ownership_transfer_state
  ) values (
    v_household,v_calendar_connection,'special:'||v_task::text,'dd8-provider-event','pending','delete_owned'
  );
  insert into public.family_events(
    household_id,title,all_day,starts_at,ends_at,calendar_sync_preference,created_by_actor_ref_id
  ) values (
    v_household,'保護者会',false,'2030-02-01 09:00+09','2030-02-01 10:00+09',
    'family_ops_owned',v_owner_ref
  ) returning id into v_event;

  v_result := private.fn_transfer_task_mirror_to_family_event_v1(
    v_household,v_owner,v_owner_ref,'20000000-0000-0000-0000-000000000146',
    v_event,v_calendar_connection,'special:'||v_task::text,'dd8-provider-event','etag-dd8',
    jsonb_build_object('title','保護者会','start','2030-02-01T09:00:00+09:00'),now(),'family_ops_owned'
  );
  if v_result->>'writer_enabled' <> 'false' then
    raise exception 'FAIL DD8: transfer activated a provider writer';
  end if;
  if not exists (
    select 1 from public.family_event_external_links
    where family_event_id=v_event and calendar_connection_id=v_calendar_connection
      and google_event_id='dd8-provider-event' and last_external_etag='etag-dd8'
      and writer_enabled=false and ownership_transfer_state='validated'
  ) then raise exception 'FAIL DD8: exact provider identity/ETag not preserved'; end if;
  if not exists (
    select 1 from private.family_ops_calendar_mirrors
    where household_id=v_household and projection_key='special:'||v_task::text
      and ownership_transfer_state='transferred' and sync_state='blocked'
  ) then raise exception 'FAIL DD8: Task mirror remains mutable after transfer'; end if;
  if not exists (
    select 1 from private.family_ops_calendar_target_deletions
    where household_id=v_household and projection_key='special:'||v_task::text
      and ownership_transfer_state='superseded' and sync_state='blocked'
  ) then raise exception 'FAIL DD8: target DELETE was not superseded'; end if;

  -- Existing Task-trigger enqueue must not reclaim a transferred mirror.
  update public.task_instances
  set due_at='2030-02-01 10:30:00+09'
  where id=v_task;
  if not exists (
    select 1 from private.family_ops_calendar_mirrors
    where household_id=v_household and projection_key='special:'||v_task::text
      and ownership_transfer_state='transferred' and sync_state='blocked'
  ) then raise exception 'FAIL DD8: transferred Task mirror was re-enqueued'; end if;
  if exists (
    select 1 from private.family_ops_calendar_target_deletions
    where household_id=v_household and projection_key='special:'||v_task::text
      and ownership_transfer_state='delete_owned'
      and sync_state in ('pending','failed','processing')
  ) then raise exception 'FAIL DD8: superseded target DELETE remained claimable'; end if;
  if exists (
    select 1 from private.canonical_google_provider_owner_audit_v1()
    where household_id=v_household and calendar_connection_id=v_calendar_connection
      and provider_event_id='dd8-provider-event' and active_owner_count>1
  ) then raise exception 'FAIL DD8: provider mutation owner overlap'; end if;
end;
$$;

reset role;
select '46_dd8_google_provider_ownership_transfer: PASS' as result;
