-- Issue #54 final-v11 Check-in literal regression.
-- Proves the pre-mutation scope shown by the PWA is the same canonical scope
-- used by all_done: required/normal are eligible, optional (余力) is excluded.
-- Also proves mostly_done never silently completes either parent task.
\set ON_ERROR_STOP on
set role service_role;

do $$
declare
  papa uuid := gen_random_uuid();
  mama uuid := gen_random_uuid();
  hh uuid;
  token text;
  papa_ref uuid;
  drop_def uuid;
  required_task uuid;
  optional_task uuid;
  session_all uuid;
  read_result jsonb;
  bulk_result jsonb;
  required_count int;
  optional_count int;
  bulk_operation uuid;
begin
  insert into auth.users(id) values(papa),(mama);
  insert into public.profiles(user_id,display_name)
    values(papa,'Issue54 checkin Papa'),(mama,'Issue54 checkin Mama');

  hh := (public.server_tx_create_household(papa,gen_random_uuid(),'Issue54 Checkin','Papa')->>'household_id')::uuid;
  token := public.server_tx_create_household_invite(papa,gen_random_uuid())->>'raw_token';
  perform public.server_tx_join_household(mama,gen_random_uuid(),token,'Mama');

  select id into papa_ref
  from public.domain_actor_refs
  where household_id=hh and actor_kind='real_user' and real_user_id=papa;
  select id into drop_def
  from public.task_definitions
  where household_id=hh and code='dropoff';

  insert into public.task_instances(
    household_id,task_definition_id,origin,title,category,routine_phase,scheduled_date,
    planned_assignee_id,planned_assignee_actor_ref_id,assignment_mode,assignment_source,
    completion_mode,status,source,created_by,expectation
  ) values(
    hh,drop_def,'recurring','送り（必須）','dropoff','morning','2026-11-02',
    papa,papa_ref,'person','manual','whole','todo','recurring',papa,'required'
  ) returning id into required_task;

  insert into public.task_instances(
    household_id,origin,title,category,routine_phase,scheduled_date,
    planned_assignee_id,planned_assignee_actor_ref_id,assignment_mode,assignment_source,
    completion_mode,status,source,created_by,expectation
  ) values(
    hh,'manual','玄関を軽く掃く（余力）','cleaning','morning','2026-11-02',
    papa,papa_ref,'person','manual','whole','todo','manual',papa,'optional'
  ) returning id into optional_task;

  perform public.server_tx_dispatch_routine_automation(
    ('2026-11-02 07:00:00'::timestamp at time zone 'Asia/Tokyo'),2000
  );
  select id into session_all
  from public.routine_checkin_sessions
  where household_id=hh and session_type='dropoff'
    and scheduled_date='2026-11-02' and assignee_id=papa;
  if session_all is null then raise exception 'FAIL Issue54 checkin: all_done session missing'; end if;

  read_result := public.server_tx_get_routine_session(papa,session_all);
  select count(*) filter(where item->>'expectation' in ('required','normal')),
         count(*) filter(where item->>'expectation'='optional')
    into required_count,optional_count
  from jsonb_array_elements(read_result->'items') item;
  if required_count<>1 or optional_count<>1 then
    raise exception 'FAIL Issue54 checkin: read scope mismatch required/normal=% optional=% payload=%',required_count,optional_count,read_result;
  end if;

  bulk_result := public.server_tx_reconcile_routine_session_v2(
    papa,gen_random_uuid(),session_all,'all_done'
  );
  bulk_operation := (bulk_result->>'reconciliation_operation_id')::uuid;
  if coalesce((bulk_result->>'completed_count')::int,-1)<>1 then
    raise exception 'FAIL Issue54 checkin: all_done completed_count was not exact: %',bulk_result;
  end if;
  if (select status from public.task_instances where id=required_task)<>'completed' then
    raise exception 'FAIL Issue54 checkin: required task was not completed';
  end if;
  if (select status from public.task_instances where id=optional_task)<>'todo' then
    raise exception 'FAIL Issue54 checkin: optional task was silently completed';
  end if;
  if (select count(*) from public.routine_reconciliation_snapshots
      where operation_id=bulk_operation)<>1 then
    raise exception 'FAIL Issue54 checkin: undo scope includes unchanged optional task';
  end if;

  -- Reuse the same materialized session after an exact undo. This avoids a
  -- second-day dispatcher fixture while exercising the same public v2 command.
  perform public.server_tx_undo_routine_reconciliation(papa,gen_random_uuid(),bulk_operation);
  if (select count(*) from public.task_instances
      where id in(required_task,optional_task) and status='todo')<>2 then
    raise exception 'FAIL Issue54 checkin: all_done undo did not restore fixture';
  end if;

  bulk_result := public.server_tx_reconcile_routine_session_v2(
    papa,gen_random_uuid(),session_all,'mostly_done'
  );
  if coalesce((bulk_result->>'completed_count')::int,-1)<>0 then
    raise exception 'FAIL Issue54 checkin: mostly_done completed tasks: %',bulk_result;
  end if;
  if (select count(*) from public.task_instances
      where id in(required_task,optional_task) and status='todo')<>2 then
    raise exception 'FAIL Issue54 checkin: mostly_done mutated canonical task truth';
  end if;
  if (select count(*) from public.routine_reconciliation_snapshots
      where operation_id=(bulk_result->>'reconciliation_operation_id')::uuid)<>0 then
    raise exception 'FAIL Issue54 checkin: mostly_done retained unchanged undo rows';
  end if;
end;
$$;
reset role;
select '80_issue54_checkin_bulk_scope: PASS' as result;
