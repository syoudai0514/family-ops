-- UX v2 P1 recurrence regressions: morning prep follows dropoff, explicit
-- weekday removal preserves history, and送迎「なし」stops future generation.
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('91000000-0000-0000-0000-000000000001'),
  ('91000000-0000-0000-0000-000000000002');

set role service_role;

do $$
declare
  v_owner uuid := '91000000-0000-0000-0000-000000000001';
  v_partner uuid := '91000000-0000-0000-0000-000000000002';
  v_hh jsonb;
  v_hh_id uuid;
  v_dropoff_def uuid;
  v_pickup_def uuid;
  v_prep_def uuid;
  v_prep_result jsonb;
  v_prep_rule uuid;
  v_completed_instance uuid;
  v_disable_op uuid := gen_random_uuid();
begin
  v_hh := public.server_tx_create_household(v_owner, gen_random_uuid(), 'UX v2 recurrence HH', 'Owner');
  v_hh_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members(household_id, user_id, member_role)
  values (v_hh_id, v_partner, 'adult');

  select id into v_dropoff_def from public.task_definitions where household_id = v_hh_id and code = 'dropoff';
  select id into v_pickup_def from public.task_definitions where household_id = v_hh_id and code = 'pickup';
  select id into v_prep_def from public.task_definitions where household_id = v_hh_id and code = 'prep_tuesday_gym';

  perform public.server_tx_configure_dropoff_pickup(
    v_owner,
    gen_random_uuid(),
    jsonb_build_array(
      jsonb_build_object('task_code', 'dropoff', 'weekday', 2, 'enabled', true, 'fixed_assignee_id', v_partner, 'scheduled_local_time', '07:30'),
      jsonb_build_object('task_code', 'pickup', 'weekday', 2, 'enabled', true, 'fixed_assignee_id', v_owner, 'scheduled_local_time', '17:30')
    )
  );

  v_prep_result := public.server_tx_change_recurrence(
    v_owner, gen_random_uuid(), v_prep_def, 2, 'default',
    'dropoff_assignee', null, '07:00', 60, null
  );
  v_prep_rule := (v_prep_result->>'rule_id')::uuid;

  if exists (
    select 1 from public.task_instances
    where recurrence_rule_id = v_prep_rule and status = 'todo'
      and planned_assignee_id is distinct from v_partner
  ) then
    raise exception 'FAIL ux-v2 recurrence: morning preparation must follow Tuesday dropoff parent';
  end if;

  select id into v_completed_instance
  from public.task_instances where recurrence_rule_id = v_prep_rule and status = 'todo'
  order by scheduled_date limit 1;
  update public.task_instances
  set status = 'completed', actual_completed_by_id = v_partner, completed_at = now()
  where id = v_completed_instance;

  perform public.server_tx_deactivate_recurrence(v_owner, v_disable_op, v_prep_def, 2, 'default');
  -- Same operation replay must be harmless and return the stored result.
  perform public.server_tx_deactivate_recurrence(v_owner, v_disable_op, v_prep_def, 2, 'default');

  if exists (select 1 from public.recurrence_rules where id = v_prep_rule and active) then
    raise exception 'FAIL ux-v2 recurrence: removed weekday rule remained active';
  end if;
  if exists (select 1 from public.task_instances where recurrence_rule_id = v_prep_rule and status = 'todo') then
    raise exception 'FAIL ux-v2 recurrence: removed weekday retained future todo instances';
  end if;
  if not exists (select 1 from public.task_instances where id = v_completed_instance and status = 'completed') then
    raise exception 'FAIL ux-v2 recurrence: completed history was deleted';
  end if;

  perform public.server_tx_configure_dropoff_pickup(
    v_owner, gen_random_uuid(),
    jsonb_build_array(jsonb_build_object('task_code', 'pickup', 'weekday', 2, 'enabled', false))
  );
  if exists (
    select 1 from public.recurrence_rules
    where household_id = v_hh_id and task_definition_id = v_pickup_def and weekday = 2 and active
  ) then
    raise exception 'FAIL ux-v2 recurrence: pickup none must not create an active unassigned rule';
  end if;
  if exists (
    select 1 from public.task_instances
    where household_id = v_hh_id and task_definition_id = v_pickup_def and scheduled_date >= (now() at time zone 'Asia/Tokyo')::date and status = 'todo'
  ) then
    raise exception 'FAIL ux-v2 recurrence: pickup none retained future todo instances';
  end if;
end;
$$;

reset role;
select 'ux_v2_recurrence_regression: PASS' as result;
