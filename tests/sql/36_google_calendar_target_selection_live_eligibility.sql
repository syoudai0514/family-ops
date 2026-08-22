-- The Edge Function performs calendarList I/O; this SQL contract verifies
-- that its preflight and failed-candidate state changes cannot clear an
-- existing household target before the final target mutation runs.
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('36000000-0000-0000-0000-000000000001'),
  ('36000000-0000-0000-0000-000000000002');

set role service_role;

do $$
declare
  v_owner uuid := '36000000-0000-0000-0000-000000000001';
  v_other uuid := '36000000-0000-0000-0000-000000000002';
  v_household uuid;
  v_other_household uuid;
  v_state text;
  v_old uuid;
  v_writer uuid;
  v_reader uuid;
  v_freebusy uuid;
  v_missing uuid;
  v_non_tokyo uuid;
  v_candidate jsonb;
  v_candidates jsonb := jsonb_build_array(
    jsonb_build_object('id', 'old-36@example.com', 'summary', 'Old target', 'accessRole', 'owner', 'timeZone', 'Asia/Tokyo'),
    jsonb_build_object('id', 'writer-36@example.com', 'summary', 'Writer', 'accessRole', 'writer', 'timeZone', 'Asia/Tokyo'),
    jsonb_build_object('id', 'reader-36@example.com', 'summary', 'Reader', 'accessRole', 'writer', 'timeZone', 'Asia/Tokyo'),
    jsonb_build_object('id', 'freebusy-36@example.com', 'summary', 'Free busy', 'accessRole', 'writer', 'timeZone', 'Asia/Tokyo'),
    jsonb_build_object('id', 'missing-36@example.com', 'summary', 'Missing', 'accessRole', 'writer', 'timeZone', 'Asia/Tokyo'),
    jsonb_build_object('id', 'non-tokyo-36@example.com', 'summary', 'Other time zone', 'accessRole', 'writer', 'timeZone', 'Asia/Tokyo')
  );
begin
  v_candidate := public.server_tx_create_household(v_owner, gen_random_uuid(), 'Target eligibility HH', 'Owner');
  v_household := (v_candidate ->> 'household_id')::uuid;
  v_candidate := public.server_tx_create_household(v_other, gen_random_uuid(), 'Other target eligibility HH', 'Other');
  v_other_household := (v_candidate ->> 'household_id')::uuid;

  v_state := encode(sha256('oauth-36-initial'), 'hex');
  perform public.server_tx_start_google_oauth(v_owner, v_state, '/settings');
  perform public.server_tx_complete_google_oauth_v2(v_state, 'subject-36', 'cipher-36', 1, array['scope'], v_candidates);
  select id into v_old from public.calendar_connections where household_id = v_household and external_calendar_id = 'old-36@example.com';
  select id into v_writer from public.calendar_connections where household_id = v_household and external_calendar_id = 'writer-36@example.com';
  select id into v_reader from public.calendar_connections where household_id = v_household and external_calendar_id = 'reader-36@example.com';
  select id into v_freebusy from public.calendar_connections where household_id = v_household and external_calendar_id = 'freebusy-36@example.com';
  select id into v_missing from public.calendar_connections where household_id = v_household and external_calendar_id = 'missing-36@example.com';
  select id into v_non_tokyo from public.calendar_connections where household_id = v_household and external_calendar_id = 'non-tokyo-36@example.com';
  perform public.server_tx_set_family_calendar_target(v_owner, gen_random_uuid(), v_old);

  -- A live writer/Tokyo result reaches the existing atomic target mutation.
  v_candidate := public.server_tx_get_google_calendar_target_candidate(v_owner, v_writer);
  if v_candidate ->> 'external_calendar_id' <> 'writer-36@example.com' then
    raise exception 'FAIL target_eligibility: active writer candidate preflight must return its stable external id';
  end if;
  perform public.server_tx_set_family_calendar_target(v_owner, gen_random_uuid(), v_writer);
  if not (select is_family_write_target from public.calendar_connections where id = v_writer) then
    raise exception 'FAIL target_eligibility: live writer candidate must select successfully';
  end if;
  perform public.server_tx_set_family_calendar_target(v_owner, gen_random_uuid(), v_old);

  -- These four false outcomes correspond to live calendarList reader,
  -- freeBusyReader, missing, and non-Asia/Tokyo results. Each only disables
  -- the requested candidate; the old target remains selected throughout.
  perform public.server_tx_revalidate_google_calendar_eligibility(v_reader, false, 'reader result from target selection');
  perform public.server_tx_revalidate_google_calendar_eligibility(v_freebusy, false, 'freeBusyReader result from target selection');
  perform public.server_tx_revalidate_google_calendar_eligibility(v_missing, false, 'calendar missing from target selection');
  perform public.server_tx_revalidate_google_calendar_eligibility(v_non_tokyo, false, 'non Asia/Tokyo result from target selection');
  if not (select active and is_family_write_target and not reauth_required from public.calendar_connections where id = v_old)
     or exists (select 1 from public.calendar_connections where id in (v_reader, v_freebusy, v_missing, v_non_tokyo) and (active or is_family_write_target or reauth_required)) then
    raise exception 'FAIL target_eligibility: failed candidate rechecks must preserve old target and disable only each candidate';
  end if;

  -- A temporary calendarList error is represented by no eligibility RPC at
  -- all; preflight is read-only, so the old target remains unchanged.
  perform public.server_tx_get_google_calendar_target_candidate(v_owner, v_old);
  if not (select is_family_write_target from public.calendar_connections where id = v_old) then
    raise exception 'FAIL target_eligibility: temporary live-check failure must not alter target';
  end if;

  -- invalid_grant is credential recovery, not a target switch.
  perform public.server_tx_mark_google_reauth_required(v_old, 'invalid_grant during target selection');
  if not (select active and reauth_required and is_family_write_target from public.calendar_connections where id = v_old) then
    raise exception 'FAIL target_eligibility: invalid_grant must preserve target while requiring reauth';
  end if;

  begin
    perform public.server_tx_get_google_calendar_target_candidate(v_other, v_writer);
    raise exception 'FAIL target_eligibility: cross-household candidate preflight must be rejected';
  exception when others then
    if sqlerrm <> 'INVALID_INPUT' then raise; end if;
  end;
end;
$$;

reset role;
select '36_google_calendar_target_selection_live_eligibility: PASS' as result;
