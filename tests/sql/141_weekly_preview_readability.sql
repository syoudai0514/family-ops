\set ON_ERROR_STOP on
begin;
insert into auth.users(id) values ('14100000-0000-0000-0000-000000000001');
set role service_role;

do $$
declare
  result text;
  hh uuid;
  google_id uuid;
  family_calendar uuid;
  private_calendar uuid;
  owner_id uuid := '14100000-0000-0000-0000-000000000001';
begin
  result := private.fn_weekly_preview_lines_v1(
    E'・送P迎M\n・14:00 プール [未]\n・16:00 歯科\n・17:00 歯科\n・家族旅行',
    E'・プール\n・運動会',
    E'・牛乳 (期限11/21 18:00)',
    true
  );
  if result <> E'・14:00 プール\n・16:00 歯科\n・17:00 歯科\n・家族旅行\n・運動会\n・牛乳 (期限11/21 18:00)' then
    raise exception 'weekly lines unexpected: %', result;
  end if;
  result := private.fn_weekly_preview_lines_v1(E'・送P迎M\n・プール', E'・プール', null, false);
  if result <> E'・送P迎M\n・プール' then
    raise exception 'transport memo or untimed event incorrectly filtered: %', result;
  end if;
  hh := (public.server_tx_create_household(owner_id, gen_random_uuid(), 'Weekly', 'パパ（仮）')->>'household_id')::uuid;
  insert into private.google_connections(household_id, owner_user_id, google_subject, encrypted_refresh_token, encryption_version, scopes, status)
  values (hh, owner_id, 'weekly-preview-test', 'ciphertext', 1, array['calendar.readonly'], 'active') returning id into google_id;
  insert into public.calendar_connections(household_id, provider, external_calendar_id, google_connection_id, active, reauth_required, is_family_write_target)
  values (hh, 'google', 'family@example.invalid', google_id, true, false, true) returning id into family_calendar;
  insert into public.calendar_connections(household_id, provider, external_calendar_id, google_connection_id, active, reauth_required, is_family_write_target)
  values (hh, 'google', 'private@example.invalid', google_id, true, false, false) returning id into private_calendar;
  insert into public.calendar_event_occurrences(household_id, calendar_connection_id, occurrence_key, google_event_id, title, starts_at, ends_at, status, projection_window_start, projection_window_end)
  values
    (hh, family_calendar, 'pool', 'pool', 'プール [未]', '2026-11-21 14:00+09', '2026-11-21 15:00+09', 'confirmed', '2026-11-16', '2026-11-23'),
    (hh, private_calendar, 'private', 'private', '非公開予定', '2026-11-21 09:00+09', '2026-11-21 10:00+09', 'confirmed', '2026-11-16', '2026-11-23');
  insert into public.task_instances(household_id, origin, title, category, routine_phase, scheduled_date, due_at, calendar_visibility, status, source, created_by, completion_mode, assignment_mode)
  values (hh, 'manual', 'プール', 'other', 'anytime', '2026-11-21', '2026-11-21 14:00+09', 'special', 'todo', 'test', owner_id, 'whole', 'unassigned');
  result := private.fn_render_weekly_preview_v1(hh, '2026-11-16');
  if result is null or result not like '%・14:00 プール%' or result like '%[未]%' or result like '%非公開予定%'
    or (length(result) - length(replace(result, 'プール', ''))) / length('プール') <> 1 then
    raise exception 'weekly preview integration failed: %', result;
  end if;

  if private.fn_weekly_preview_lines_v1(null, null, null, false) is not null then
    raise exception 'empty days must remain empty';
  end if;
end $$;
rollback;
select 'weekly_preview_readability: PASS' as result;
