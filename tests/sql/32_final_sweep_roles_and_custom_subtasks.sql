-- Final sweep regression: atomic P/M swaps and the canonical custom-routine
-- subtask definition path. Historical instance snapshots must not mutate.
\set ON_ERROR_STOP on

insert into auth.users(id) values
  ('32000000-0000-0000-0000-000000000001'),
  ('32000000-0000-0000-0000-000000000002'),
  ('32000000-0000-0000-0000-000000000003');
set role service_role;

do $$
declare
  a uuid := '32000000-0000-0000-0000-000000000001';
  b uuid := '32000000-0000-0000-0000-000000000002';
  outsider uuid := '32000000-0000-0000-0000-000000000003';
  hh jsonb; h uuid; foreign_hh jsonb; definition_id uuid; rule_id uuid;
  historical_task uuid; future_task uuid; result_a jsonb; result_b jsonb;
  rejected boolean := false;
begin
  hh := public.server_tx_create_household(a, '32000000-0000-0000-0000-000000000011', 'Final sweep roles', 'Owner');
  h := (hh->>'household_id')::uuid;
  insert into public.household_members(household_id,user_id,member_role) values(h,b,'adult');
  if (select count(*) from public.household_members where household_id=h and family_role='papa') <> 1
     or (select count(*) from public.household_members where household_id=h and family_role='mama') <> 1 then
    raise exception 'FAIL final sweep role: initial household lacks P/M';
  end if;

  result_a := public.server_tx_set_family_role(a, '32000000-0000-0000-0000-000000000012', a, 'mama');
  if (select family_role from public.household_members where household_id=h and user_id=a) <> 'mama'
     or (select family_role from public.household_members where household_id=h and user_id=b) <> 'papa' then
    raise exception 'FAIL final sweep role: P to M did not atomically swap';
  end if;
  result_b := public.server_tx_set_family_role(a, '32000000-0000-0000-0000-000000000012', a, 'mama');
  if result_a <> result_b or (select count(*) from public.household_members where household_id=h and family_role='papa') <> 1
     or (select count(*) from public.household_members where household_id=h and family_role='mama') <> 1 then
    raise exception 'FAIL final sweep role: retry broke idempotent P/M invariant';
  end if;
  perform public.server_tx_set_family_role(a, '32000000-0000-0000-0000-000000000013', b, 'mama');
  if (select family_role from public.household_members where household_id=h and user_id=a) <> 'papa'
     or (select family_role from public.household_members where household_id=h and user_id=b) <> 'mama' then
    raise exception 'FAIL final sweep role: M to P reverse swap did not preserve both roles';
  end if;
  foreign_hh := public.server_tx_create_household(outsider, '32000000-0000-0000-0000-000000000014', 'Final sweep foreign', 'Outsider');
  begin
    perform public.server_tx_set_family_role(a, '32000000-0000-0000-0000-000000000015', outsider, 'mama');
  exception when others then rejected := sqlerrm = 'CROSS_HOUSEHOLD_RESOURCE';
  end;
  if not rejected then raise exception 'FAIL final sweep role: cross-household role change accepted'; end if;

  result_a := public.server_tx_create_task_definition(a, '32000000-0000-0000-0000-000000000016', 'morning_custom_final', '朝の支度', 'household', 'morning', 'subtasks', 0,
    jsonb_build_array(jsonb_build_object('title','水筒','required',true,'sort_order',0), jsonb_build_object('title','連絡帳','required',true,'sort_order',1)));
  definition_id := (result_a->>'task_definition_id')::uuid;
  insert into public.recurrence_rules(household_id,task_definition_id,weekday,slot_key,assignee_strategy,planned_assignee_id,scheduled_local_time,effective_from,active,created_by)
  values(h,definition_id,1,'final-sweep','fixed',a,'07:00','2026-09-01',true,a) returning id into rule_id;
  perform private.materialize_recurrence_rule(h,rule_id,'2026-09-07','2026-09-07');
  select id into historical_task from public.task_instances where household_id=h and logical_occurrence_key='rec:'||definition_id::text||':2026-09-07:final-sweep';
  update public.task_instances set status='completed',completed_at=now() where id=historical_task;
  perform public.server_tx_replace_routine_subtasks(a, '32000000-0000-0000-0000-000000000017', definition_id,
    jsonb_build_array(jsonb_build_object('title','新しい水筒','required',false), jsonb_build_object('title','ハンカチ','required',true)));
  if (select title from public.task_subtask_instances where task_instance_id=historical_task order by sort_order limit 1) <> '水筒'
     or (select count(*) from public.task_subtask_instances where task_instance_id=historical_task) <> 2 then
    raise exception 'FAIL final sweep subtasks: completed history changed';
  end if;
  perform private.materialize_recurrence_rule(h,rule_id,'2026-09-14','2026-09-14');
  select id into future_task from public.task_instances where household_id=h and logical_occurrence_key='rec:'||definition_id::text||':2026-09-14:final-sweep';
  if (select array_agg(title order by sort_order) from public.task_subtask_instances where task_instance_id=future_task) <> array['新しい水筒','ハンカチ']
     or (select required from public.task_subtask_instances where task_instance_id=future_task order by sort_order limit 1) then
    raise exception 'FAIL final sweep subtasks: future materialization did not use edited canonical definition';
  end if;
  perform public.server_tx_set_routine_definition_options(a, '32000000-0000-0000-0000-000000000018', definition_id, false, true);
  perform public.server_tx_set_routine_definition_options(a, '32000000-0000-0000-0000-000000000019', definition_id, true, true);
  if (select count(*) from public.task_subtask_definitions where household_id=h and task_definition_id=definition_id and is_active) <> 2
     or (select count(*) from public.task_subtask_instances where task_instance_id=historical_task) <> 2 then
    raise exception 'FAIL final sweep subtasks: disable/re-enable corrupted definitions or history';
  end if;
end;
$$;

reset role;
select '32_final_sweep_roles_and_custom_subtasks: PASS' as result;
