-- WP2: update-routine-schedule.
\set ON_ERROR_STOP on

insert into auth.users (id) values ('80000000-0000-0000-0000-000000000001');

set role service_role;

do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_old_version int;
begin
  v_hh := public.server_tx_create_household('80000000-0000-0000-0000-000000000001', gen_random_uuid(), 'Routine Schedule HH', 'Owner');
  v_hh_id := (v_hh->>'household_id')::uuid;

  select schedule_version into v_old_version
  from public.household_routine_schedules
  where household_id = v_hh_id and schedule_kind = 'daily_assignment';
  if v_old_version <> 1 then
    raise exception 'FAIL routine-schedule: fresh household rows must start at schedule_version=1, got %', v_old_version;
  end if;

  perform public.server_tx_update_routine_schedule(
    '80000000-0000-0000-0000-000000000001', gen_random_uuid(), 'daily_assignment', false, '06:30'::time
  );

  if (select enabled from public.household_routine_schedules where household_id = v_hh_id and schedule_kind = 'daily_assignment') <> false then
    raise exception 'FAIL routine-schedule: update-routine-schedule did not set enabled=false';
  end if;
  if (select local_time from public.household_routine_schedules where household_id = v_hh_id and schedule_kind = 'daily_assignment') <> '06:30'::time then
    raise exception 'FAIL routine-schedule: update-routine-schedule did not set local_time';
  end if;
  if (select schedule_version from public.household_routine_schedules where household_id = v_hh_id and schedule_kind = 'daily_assignment') <> v_old_version + 1 then
    raise exception 'FAIL routine-schedule: schedule_version must be incremented on update';
  end if;

  -- invalid schedule_kind is rejected
  begin
    perform public.server_tx_update_routine_schedule(
      '80000000-0000-0000-0000-000000000001', gen_random_uuid(), 'weekly_digest', true, '12:00'::time
    );
    raise exception 'FAIL routine-schedule: the retired weekly_digest kind must be rejected';
  exception
    when others then
      if sqlerrm <> 'INVALID_INPUT' then
        raise exception 'FAIL routine-schedule: expected INVALID_INPUT, got %', sqlerrm;
      end if;
  end;
end;
$$;

reset role;
select 'routine_schedule_mutation: PASS' as result;
