-- WP2: initial dropoff/pickup times and weekly assignee setup.
-- supabase/migrations/20260819000018_dropoff_pickup_setup.sql;
-- docs/adr/0002-dropoff-pickup-setup-endpoint.md.
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('30000000-0000-0000-0000-000000000001'),
  ('30000000-0000-0000-0000-000000000002');

set role service_role;

do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_dropoff_def uuid;
  v_result jsonb;
  v_rule record;
  v_instance_count int;
begin
  v_hh := public.server_tx_create_household('30000000-0000-0000-0000-000000000001', gen_random_uuid(), 'Dropoff Pickup HH', 'Owner');
  v_hh_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role)
  values (v_hh_id, '30000000-0000-0000-0000-000000000002', 'adult');

  select id into v_dropoff_def from public.task_definitions where household_id = v_hh_id and code = 'dropoff';
  if (select dropoff_pickup_setup_completed_at from public.households where id = v_hh_id) is not null then
    raise exception 'FAIL dropoff-pickup: fresh household must not already be setup-complete';
  end if;

  -- happy path: dropoff Mon/Wed fixed to owner, pickup Tue fixed to partner
  v_result := public.server_tx_configure_dropoff_pickup(
    '30000000-0000-0000-0000-000000000001', gen_random_uuid(),
    jsonb_build_array(
      jsonb_build_object('task_code', 'dropoff', 'weekday', 1, 'enabled', true, 'fixed_assignee_id', '30000000-0000-0000-0000-000000000001', 'scheduled_local_time', '07:30'),
      jsonb_build_object('task_code', 'dropoff', 'weekday', 3, 'enabled', true, 'fixed_assignee_id', '30000000-0000-0000-0000-000000000001', 'scheduled_local_time', '07:30'),
      jsonb_build_object('task_code', 'pickup', 'weekday', 2, 'enabled', true, 'fixed_assignee_id', '30000000-0000-0000-0000-000000000002', 'scheduled_local_time', '16:30')
    )
  );

  if (v_result->>'dropoff_pickup_setup_completed_at') is null then
    raise exception 'FAIL dropoff-pickup: result must include dropoff_pickup_setup_completed_at';
  end if;
  if (select dropoff_pickup_setup_completed_at from public.households where id = v_hh_id) is null then
    raise exception 'FAIL dropoff-pickup: households.dropoff_pickup_setup_completed_at must be set';
  end if;

  select count(*) into v_instance_count
  from public.recurrence_rules
  where household_id = v_hh_id and task_definition_id = v_dropoff_def and active;
  if v_instance_count <> 2 then
    raise exception 'FAIL dropoff-pickup: expected 2 active dropoff recurrence rules (Mon/Wed), got %', v_instance_count;
  end if;

  select * into v_rule from public.recurrence_rules
  where household_id = v_hh_id and task_definition_id = v_dropoff_def and weekday = 1 and active;
  if v_rule.assignee_strategy <> 'fixed' or v_rule.planned_assignee_id <> '30000000-0000-0000-0000-000000000001'::uuid then
    raise exception 'FAIL dropoff-pickup: dropoff Monday rule must be fixed to the specified assignee';
  end if;

  if not exists (
    select 1 from public.task_instances
    where household_id = v_hh_id and task_definition_id = v_dropoff_def and status = 'todo'
  ) then
    raise exception 'FAIL dropoff-pickup: materialization must have created dropoff task_instances';
  end if;

  -- replay: same operation_id, no duplicate rules
  perform public.server_tx_configure_dropoff_pickup(
    '30000000-0000-0000-0000-000000000001', gen_random_uuid(),
    jsonb_build_array(jsonb_build_object('task_code', 'dropoff', 'weekday', 5, 'enabled', false))
  );
  select count(*) into v_instance_count
  from public.recurrence_rules
  where household_id = v_hh_id and task_definition_id = v_dropoff_def and active;
  if v_instance_count <> 2 then
    raise exception 'FAIL dropoff-pickup: disabling an unrelated weekday must not affect the other 2 active rules, got %', v_instance_count;
  end if;
end;
$$;

-- cross-household fixed_assignee_id is rejected
do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_outsider uuid := '30000000-0000-0000-0000-000000000099';
begin
  insert into auth.users (id) values (v_outsider), ('30000000-0000-0000-0000-000000000003');
  v_hh := public.server_tx_create_household('30000000-0000-0000-0000-000000000003', gen_random_uuid(), 'Dropoff Cross HH', 'Owner');
  v_hh_id := (v_hh->>'household_id')::uuid;

  begin
    perform public.server_tx_configure_dropoff_pickup(
      '30000000-0000-0000-0000-000000000003', gen_random_uuid(),
      jsonb_build_array(jsonb_build_object('task_code', 'pickup', 'weekday', 4, 'enabled', true, 'fixed_assignee_id', v_outsider::text))
    );
    raise exception 'FAIL dropoff-pickup: cross-household fixed_assignee_id must be rejected';
  exception
    when others then
      if sqlerrm <> 'CROSS_HOUSEHOLD_RESOURCE' then
        raise exception 'FAIL dropoff-pickup: expected CROSS_HOUSEHOLD_RESOURCE, got %', sqlerrm;
      end if;
  end;
end;
$$;

-- an enabled row with no fixed_assignee_id is INVALID_INPUT
do $$
declare
  v_hh_id uuid;
begin
  select id into v_hh_id from public.households where name = 'Dropoff Cross HH';
  begin
    perform public.server_tx_configure_dropoff_pickup(
      '30000000-0000-0000-0000-000000000003', gen_random_uuid(),
      jsonb_build_array(jsonb_build_object('task_code', 'dropoff', 'weekday', 1, 'enabled', true))
    );
    raise exception 'FAIL dropoff-pickup: an enabled row with no fixed_assignee_id must be rejected';
  exception
    when others then
      if sqlerrm <> 'INVALID_INPUT' then
        raise exception 'FAIL dropoff-pickup: expected INVALID_INPUT, got %', sqlerrm;
      end if;
  end;
end;
$$;

reset role;
select 'dropoff_pickup_setup: PASS' as result;
