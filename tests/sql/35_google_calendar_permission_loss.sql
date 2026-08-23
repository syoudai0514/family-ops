-- A Google Calendar 403 is not refresh-token loss.  Workers must re-check
-- calendarList eligibility before disabling a target, and a disappeared
-- target must leave stable-id evidence instead of creating unbounded stale
-- outbox retries.
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('35000000-0000-0000-0000-000000000001');

set role service_role;

do $$
declare
  v_owner uuid := '35000000-0000-0000-0000-000000000001';
  v_household uuid;
  v_state text;
  v_primary uuid;
  v_shared uuid;
  v_replacement uuid;
  v_result jsonb;
  v_candidates jsonb := jsonb_build_array(
    jsonb_build_object('id', 'primary-35@example.com', 'summary', 'Personal', 'accessRole', 'owner', 'timeZone', 'Asia/Tokyo'),
    jsonb_build_object('id', 'shared-35@group.calendar.google.com', 'summary', 'Family', 'accessRole', 'writer', 'timeZone', 'Asia/Tokyo'),
    jsonb_build_object('id', 'replacement-35@group.calendar.google.com', 'summary', 'Replacement', 'accessRole', 'writerWithoutPrivateAccess', 'timeZone', 'Asia/Tokyo')
  );
begin
  v_result := public.server_tx_create_household(v_owner, gen_random_uuid(), 'Calendar permission HH', 'Owner');
  v_household := (v_result ->> 'household_id')::uuid;
  v_state := encode(sha256('oauth-35-initial'), 'hex');
  perform public.server_tx_start_google_oauth(v_owner, v_state, '/settings');
  perform public.server_tx_complete_google_oauth_v2(
    v_state, 'subject-35', 'cipher-35', 1,
    array['https://www.googleapis.com/auth/calendar.events', 'https://www.googleapis.com/auth/calendar.calendarlist.readonly'],
    v_candidates
  );

  select id into v_primary from public.calendar_connections where household_id = v_household and external_calendar_id = 'primary-35@example.com';
  select id into v_shared from public.calendar_connections where household_id = v_household and external_calendar_id = 'shared-35@group.calendar.google.com';
  select id into v_replacement from public.calendar_connections where household_id = v_household and external_calendar_id = 'replacement-35@group.calendar.google.com';
  perform public.server_tx_set_family_calendar_target(v_owner, gen_random_uuid(), v_primary);

  -- 403 followed by a calendarList result that still says writer/owner and
  -- Asia/Tokyo is a transient provider error: retain the selected target.
  perform public.server_tx_revalidate_google_calendar_eligibility(v_primary, true, '403 recheck: owner remains eligible');
  if not (select active and is_family_write_target and not reauth_required from public.calendar_connections where id = v_primary) then
    raise exception 'FAIL calendar_permission: eligible 403 recheck must keep target';
  end if;

  insert into private.family_ops_calendar_mirrors(
    household_id, projection_key, kind, local_date, calendar_connection_id,
    provider_event_id, desired_action, sync_state
  ) values (
    v_household, 'special:permission-35', 'special', current_date, v_primary,
    'provider-event-35', 'upsert', 'pending'
  );

  -- reader/freeBusyReader is filtered by the Edge candidate helper and is
  -- represented here by a false revalidation result.  It is not invalid_grant.
  perform public.server_tx_revalidate_google_calendar_eligibility(v_primary, false, '403 recheck: downgraded to reader');
  if exists (
    select 1 from public.calendar_connections
    where id = v_primary and (active or is_family_write_target or reauth_required)
  ) then
    raise exception 'FAIL calendar_permission: reader downgrade must deactivate and clear only target, not request reauth';
  end if;
  if not exists (
    select 1 from private.family_ops_calendar_mirrors
    where household_id = v_household and projection_key = 'special:permission-35' and sync_state = 'blocked'
  ) or not exists (
    select 1 from private.family_ops_calendar_orphaned_mirrors
    where calendar_connection_id = v_primary and provider_event_id = 'provider-event-35'
  ) then
    raise exception 'FAIL calendar_permission: lost target must block outbox and keep stable-id orphan evidence';
  end if;

  -- The old target is already inactive, so selecting a new target must not
  -- enqueue an impossible delete against the lost calendar.  The orphan
  -- record above is the explicit, non-destructive cleanup outcome.
  v_result := public.server_tx_set_family_calendar_target(v_owner, gen_random_uuid(), v_shared);
  if (v_result ->> 'previous_calendar_connection_id') is not null
     or not (select is_family_write_target from public.calendar_connections where id = v_shared)
     or exists (select 1 from private.family_ops_calendar_target_deletions where calendar_connection_id = v_primary) then
    raise exception 'FAIL calendar_permission: target loss must not create an unauthorized stale-delete job';
  end if;

  -- A calendar that disappears from calendarList has the same calendar-level
  -- stop semantics; it must not masquerade as a credential reauth request.
  perform public.server_tx_revalidate_google_calendar_eligibility(v_shared, false, '403 recheck: calendar missing');
  if exists (
    select 1 from public.calendar_connections
    where id = v_shared and (active or is_family_write_target or reauth_required)
  ) then
    raise exception 'FAIL calendar_permission: missing calendar must be inactive and unselected without reauth';
  end if;

  perform public.server_tx_set_family_calendar_target(v_owner, gen_random_uuid(), v_replacement);
  -- invalid_grant remains a credential-wide recovery path and is deliberately
  -- distinct from the two calendar-list failures above.
  perform public.server_tx_mark_google_reauth_required(v_replacement, 'invalid_grant');
  if not (select active and reauth_required and is_family_write_target from public.calendar_connections where id = v_replacement) then
    raise exception 'FAIL calendar_permission: invalid_grant must require reauth without conflating calendar loss';
  end if;

  -- A successful reauth that still lists the selected replacement clears only
  -- the credential recovery marker and preserves the explicit target.
  v_state := encode(sha256('oauth-35-reauth-preserve'), 'hex');
  perform public.server_tx_start_google_oauth(v_owner, v_state, '/settings');
  perform public.server_tx_complete_google_oauth_v2(
    v_state, 'subject-35-reauth', 'cipher-35b', 1, array['scope'],
    jsonb_build_array(jsonb_build_object('id', 'replacement-35@group.calendar.google.com', 'summary', 'Replacement', 'accessRole', 'writer', 'timeZone', 'Asia/Tokyo'))
  );
  if not (select active and not reauth_required and is_family_write_target from public.calendar_connections where id = v_replacement) then
    raise exception 'FAIL calendar_permission: successful reauth must retain an eligible explicit target';
  end if;
end;
$$;

reset role;
select '35_google_calendar_permission_loss: PASS' as result;
