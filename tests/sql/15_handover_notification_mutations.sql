-- WP2: create-handover, mark-handover-read, mark-notification-read,
-- update-notification-preferences.
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('90000000-0000-0000-0000-000000000001'),
  ('90000000-0000-0000-0000-000000000002');

set role service_role;

do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_handover_id uuid;
  v_notification_id uuid;
  v_result jsonb;
  v_read_at_1 timestamptz;
  v_read_at_2 timestamptz;
begin
  v_hh := public.server_tx_create_household('90000000-0000-0000-0000-000000000001', gen_random_uuid(), 'Handover Notif HH', 'Owner');
  v_hh_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role)
  values (v_hh_id, '90000000-0000-0000-0000-000000000002', 'adult');

  -- create-handover happy path, notifies the other member
  v_result := public.server_tx_create_handover(
    '90000000-0000-0000-0000-000000000001', gen_random_uuid(),
    'Kids fed, homework done', 'evening', array['kids', 'homework'], current_date
  );
  v_handover_id := (v_result->>'handover_id')::uuid;
  if v_handover_id is null then
    raise exception 'FAIL handover-notif: create-handover must return a handover_id';
  end if;
  if not exists (
    select 1 from public.user_notifications
    where household_id = v_hh_id and recipient_user_id = '90000000-0000-0000-0000-000000000002' and type = 'handover_created'
  ) then
    raise exception 'FAIL handover-notif: create-handover must notify the other household member';
  end if;

  -- mark-handover-read: replay-safe, preserves the first read_at
  perform public.server_tx_mark_handover_read('90000000-0000-0000-0000-000000000002', gen_random_uuid(), v_handover_id);
  select read_at into v_read_at_1 from public.handover_reads where handover_id = v_handover_id and user_id = '90000000-0000-0000-0000-000000000002';

  perform pg_sleep(0.05);
  perform public.server_tx_mark_handover_read('90000000-0000-0000-0000-000000000002', gen_random_uuid(), v_handover_id);
  select read_at into v_read_at_2 from public.handover_reads where handover_id = v_handover_id and user_id = '90000000-0000-0000-0000-000000000002';

  if v_read_at_1 <> v_read_at_2 then
    raise exception 'FAIL handover-notif: mark-handover-read replay must preserve the first read_at, got % then %', v_read_at_1, v_read_at_2;
  end if;

  -- mark-notification-read: wrong recipient is rejected
  select id into v_notification_id from public.user_notifications
  where household_id = v_hh_id and recipient_user_id = '90000000-0000-0000-0000-000000000002' and type = 'handover_created';

  begin
    perform public.server_tx_mark_notification_read('90000000-0000-0000-0000-000000000001', gen_random_uuid(), v_notification_id);
    raise exception 'FAIL handover-notif: marking someone else''s notification read must be rejected';
  exception
    when others then
      if sqlerrm <> 'CROSS_HOUSEHOLD_RESOURCE' then
        raise exception 'FAIL handover-notif: expected CROSS_HOUSEHOLD_RESOURCE, got %', sqlerrm;
      end if;
  end;

  -- mark-notification-read: happy path + replay preserves first read_at
  perform public.server_tx_mark_notification_read('90000000-0000-0000-0000-000000000002', gen_random_uuid(), v_notification_id);
  select read_at into v_read_at_1 from public.user_notifications where id = v_notification_id;
  if v_read_at_1 is null then
    raise exception 'FAIL handover-notif: mark-notification-read must set read_at';
  end if;

  perform pg_sleep(0.05);
  perform public.server_tx_mark_notification_read('90000000-0000-0000-0000-000000000002', gen_random_uuid(), v_notification_id);
  select read_at into v_read_at_2 from public.user_notifications where id = v_notification_id;
  if v_read_at_1 <> v_read_at_2 then
    raise exception 'FAIL handover-notif: mark-notification-read replay must preserve the first read_at';
  end if;

  -- update-notification-preferences: partial update only touches given fields
  if (select in_app from public.notification_preferences where household_id = v_hh_id and user_id = '90000000-0000-0000-0000-000000000001') is distinct from true then
    raise exception 'FAIL handover-notif: in_app must default true';
  end if;

  perform public.server_tx_update_notification_preferences(
    '90000000-0000-0000-0000-000000000001', gen_random_uuid(), jsonb_build_object('shopping_minor_line', true)
  );
  if (select shopping_minor_line from public.notification_preferences where household_id = v_hh_id and user_id = '90000000-0000-0000-0000-000000000001') <> true then
    raise exception 'FAIL handover-notif: update-notification-preferences must set the given field';
  end if;
  if (select in_app from public.notification_preferences where household_id = v_hh_id and user_id = '90000000-0000-0000-0000-000000000001') <> true then
    raise exception 'FAIL handover-notif: update-notification-preferences must leave untouched fields alone';
  end if;

  -- unknown field is rejected
  begin
    perform public.server_tx_update_notification_preferences(
      '90000000-0000-0000-0000-000000000001', gen_random_uuid(), jsonb_build_object('not_a_real_field', true)
    );
    raise exception 'FAIL handover-notif: an unknown preference field must be rejected';
  exception
    when others then
      if sqlerrm <> 'INVALID_INPUT' then
        raise exception 'FAIL handover-notif: expected INVALID_INPUT, got %', sqlerrm;
      end if;
  end;
end;
$$;

reset role;
select 'handover_notification_mutations: PASS' as result;
