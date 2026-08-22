-- Google OAuth completion v2 registers every eligible candidate but never
-- picks the first one as the household's write target.
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('3b000000-0000-0000-0000-000000000001'),
  ('3b000000-0000-0000-0000-000000000002'),
  ('3b000000-0000-0000-0000-000000000003');

set role service_role;

do $$
declare
  v_owner uuid := '3b000000-0000-0000-0000-000000000001';
  v_partner uuid := '3b000000-0000-0000-0000-000000000002';
  v_other uuid := '3b000000-0000-0000-0000-000000000003';
  v_household uuid;
  v_other_household uuid;
  v_state text;
  v_primary uuid;
  v_shared uuid;
  v_result jsonb;
  v_candidates jsonb := jsonb_build_array(
    jsonb_build_object('id', 'primary-34@example.com', 'summary', 'Personal', 'accessRole', 'owner', 'timeZone', 'Asia/Tokyo'),
    jsonb_build_object('id', 'shared-34@group.calendar.google.com', 'summary', 'Household calendar', 'accessRole', 'writer', 'timeZone', 'Asia/Tokyo')
  );
begin
  v_result := public.server_tx_create_household(v_owner, gen_random_uuid(), 'OAuth target HH', 'Owner');
  v_household := (v_result ->> 'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role)
  values (v_household, v_partner, 'adult');
  v_result := public.server_tx_create_household(v_other, gen_random_uuid(), 'Other OAuth HH', 'Other');
  v_other_household := (v_result ->> 'household_id')::uuid;

  v_state := encode(sha256('oauth-v2-first'), 'hex');
  perform public.server_tx_start_google_oauth(v_owner, v_state, '/today');
  v_result := public.server_tx_complete_google_oauth_v2(
    v_state, 'opaque-google-subject', 'cipher-34', 1,
    array['https://www.googleapis.com/auth/calendar.events', 'https://www.googleapis.com/auth/calendar.calendarlist.readonly'],
    v_candidates
  );
  if (select count(*) from public.calendar_connections where household_id = v_household and active) <> 2 then
    raise exception 'FAIL oauth_shared_target: all eligible calendars must be registered';
  end if;
  if exists (select 1 from public.calendar_connections where household_id = v_household and is_family_write_target) then
    raise exception 'FAIL oauth_shared_target: initial OAuth must not select a write target';
  end if;
  if v_result ->> 'return_to' <> '/today' then
    raise exception 'FAIL oauth_shared_target: app-relative return_to must survive completion';
  end if;

  select id into v_primary from public.calendar_connections where household_id = v_household and external_calendar_id = 'primary-34@example.com';
  select id into v_shared from public.calendar_connections where household_id = v_household and external_calendar_id = 'shared-34@group.calendar.google.com';
  perform public.server_tx_set_family_calendar_target(v_owner, gen_random_uuid(), v_shared);
  if (select count(*) from public.calendar_connections where household_id = v_household and is_family_write_target) <> 1
     or not (select is_family_write_target from public.calendar_connections where id = v_shared) then
    raise exception 'FAIL oauth_shared_target: explicit selection must create exactly one target';
  end if;
  perform public.server_tx_set_family_calendar_target(v_owner, gen_random_uuid(), v_primary);
  if (select count(*) from public.calendar_connections where household_id = v_household and is_family_write_target) <> 1
     or not (select is_family_write_target from public.calendar_connections where id = v_primary) then
    raise exception 'FAIL oauth_shared_target: target switch must retain unique target';
  end if;

  v_state := encode(sha256('oauth-v2-reauth-preserve'), 'hex');
  perform public.server_tx_start_google_oauth(v_partner, v_state, '/settings');
  perform public.server_tx_complete_google_oauth_v2(v_state, 'opaque-google-subject-2', 'cipher-34b', 1, array['scope'], v_candidates);
  if not (select is_family_write_target from public.calendar_connections where id = v_primary) then
    raise exception 'FAIL oauth_shared_target: eligible explicit target must survive reauth';
  end if;

  insert into private.family_ops_calendar_mirrors(
    household_id, projection_key, kind, local_date, calendar_connection_id,
    provider_event_id, desired_action, sync_state
  ) values (
    v_household, 'special:oauth-target-lost-34', 'special', current_date,
    v_primary, 'provider-event-oauth-34', 'upsert', 'pending'
  );

  v_state := encode(sha256('oauth-v2-target-lost'), 'hex');
  perform public.server_tx_start_google_oauth(v_owner, v_state, '/settings');
  perform public.server_tx_complete_google_oauth_v2(
    v_state, 'opaque-google-subject-3', 'cipher-34c', 1, array['scope'],
    jsonb_build_array(jsonb_build_object('id', 'shared-34@group.calendar.google.com', 'summary', 'Household calendar', 'accessRole', 'writerWithoutPrivateAccess', 'timeZone', 'Asia/Tokyo'))
  );
  if (select active from public.calendar_connections where id = v_primary)
     or (select is_family_write_target from public.calendar_connections where id = v_primary)
     or exists (select 1 from public.calendar_connections where household_id = v_household and is_family_write_target) then
    raise exception 'FAIL oauth_shared_target: access-lost target must be inactive and unselected';
  end if;
  if (select reauth_required from public.calendar_connections where id = v_primary)
     or not exists (
       select 1 from private.family_ops_calendar_mirrors
       where household_id = v_household and projection_key = 'special:oauth-target-lost-34' and sync_state = 'blocked'
     )
     or not exists (
       select 1 from private.family_ops_calendar_orphaned_mirrors
       where calendar_connection_id = v_primary and provider_event_id = 'provider-event-oauth-34'
     ) then
    raise exception 'FAIL oauth_shared_target: missing candidate is not invalid_grant and must preserve blocked-mirror evidence';
  end if;
  perform public.server_tx_set_family_calendar_target(v_owner, gen_random_uuid(), v_shared);
  if exists (select 1 from private.family_ops_calendar_target_deletions where calendar_connection_id = v_primary) then
    raise exception 'FAIL oauth_shared_target: later target selection must not enqueue deletion after access loss';
  end if;

  begin
    perform public.server_tx_complete_google_oauth_v2(v_state, 'replay', 'cipher', 1, array['scope'], v_candidates);
    raise exception 'FAIL oauth_shared_target: OAuth state replay must be rejected';
  exception when others then
    if sqlerrm <> 'GOOGLE_OAUTH_STATE_INVALID' then raise; end if;
  end;

  begin
    perform public.server_tx_set_family_calendar_target(v_other, gen_random_uuid(), v_shared);
    raise exception 'FAIL oauth_shared_target: cross-household target binding must be rejected';
  exception when others then
    if sqlerrm <> 'INVALID_INPUT' then raise; end if;
  end;
end;
$$;

reset role;
select '34_google_oauth_shared_calendar_target: PASS' as result;
