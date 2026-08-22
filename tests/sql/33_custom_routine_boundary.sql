-- Built-in evening chores are edited only by EveningRoutineEditor. Verify the
-- custom-subtask mutation rejects them before changing their weekday patterns.
\set ON_ERROR_STOP on
insert into auth.users(id) values ('33000000-0000-0000-0000-000000000001');
set role service_role;
do $$
declare
  owner_id uuid := '33000000-0000-0000-0000-000000000001';
  household jsonb; v_household_id uuid; dinner_id uuid; before_rules jsonb; after_rules jsonb;
  rejected boolean := false;
begin
  household := public.server_tx_create_household(owner_id, '33000000-0000-0000-0000-000000000011', 'Custom boundary', 'Owner');
  v_household_id := (household->>'household_id')::uuid;
  select id into dinner_id from public.task_definitions where household_id=v_household_id and code='dinner';
  insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,scheduled_local_time,effective_from,active,created_by)
  values
    (v_household_id,dinner_id,1,'builtin-monday','fixed','18:00','2026-09-01',true,owner_id),
    (v_household_id,dinner_id,5,'builtin-friday','pickup_assignee','20:30','2026-09-01',true,owner_id);
  select jsonb_agg(jsonb_build_object('weekday',weekday,'strategy',assignee_strategy,'time',scheduled_local_time) order by weekday)
  into before_rules from public.recurrence_rules where household_id=v_household_id and task_definition_id=dinner_id and active;
  begin
    perform public.server_tx_replace_routine_subtasks(owner_id, '33000000-0000-0000-0000-000000000012', dinner_id,
      jsonb_build_array(jsonb_build_object('title','壊してはいけない','required',true)));
  exception when others then rejected := sqlerrm = 'CUSTOM_ROUTINE_REQUIRED';
  end;
  if not rejected then raise exception 'FAIL custom-routine-boundary: built-in dinner accepted custom subtask mutation'; end if;
  select jsonb_agg(jsonb_build_object('weekday',weekday,'strategy',assignee_strategy,'time',scheduled_local_time) order by weekday)
  into after_rules from public.recurrence_rules where household_id=v_household_id and task_definition_id=dinner_id and active;
  if before_rules is distinct from after_rules then raise exception 'FAIL custom-routine-boundary: built-in weekday patterns were flattened'; end if;
  if (select count(*) from public.task_definitions where household_id=v_household_id and code in ('dinner','bath','laundry','dishes','cleaning','smile_zemi','media_30min')) <> 7 then
    raise exception 'FAIL custom-routine-boundary: canonical evening chore set changed';
  end if;
end;
$$;
reset role;
select '33_custom_routine_boundary: PASS' as result;
