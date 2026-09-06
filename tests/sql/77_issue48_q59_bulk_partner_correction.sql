-- Issue #48 independent re-review HIGH regression.
-- Q59 literal real-use path:
--   全部やった -> 例外を修正 -> 相手が対応
-- must correct every actual-truth projection, preserve old performer history,
-- be retry-idempotent, block cross-household access, and make the old bulk
-- undo stale instead of rewinding the later correction.
\set ON_ERROR_STOP on
set role service_role;

do $$
declare
  papa uuid:=gen_random_uuid();
  mama uuid:=gen_random_uuid();
  outsider uuid:=gen_random_uuid();
  hh uuid; other_hh uuid; token text;
  papa_ref uuid; mama_ref uuid; drop_def uuid;
  task_id uuid; session_id uuid;
  bulk_op uuid:=gen_random_uuid(); correction_op uuid:=gen_random_uuid();
  bulk_result jsonb; correction_result jsonb; replay_result jsonb;
  bulk_after_revision bigint; corrected_revision bigint;
  failed boolean:=false;
begin
  insert into auth.users(id) values(papa),(mama),(outsider);
  insert into public.profiles(user_id,display_name)
    values(papa,'Q59 bulk Papa'),(mama,'Q59 bulk Mama'),(outsider,'Q59 outsider');

  hh:=(public.server_tx_create_household(papa,gen_random_uuid(),'Q59 bulk partner H1','Papa')->>'household_id')::uuid;
  token:=public.server_tx_create_household_invite(papa,gen_random_uuid())->>'raw_token';
  perform public.server_tx_join_household(mama,gen_random_uuid(),token,'Mama');
  other_hh:=(public.server_tx_create_household(outsider,gen_random_uuid(),'Q59 bulk partner H2','Other')->>'household_id')::uuid;

  select id into papa_ref from public.domain_actor_refs
    where household_id=hh and actor_kind='real_user' and real_user_id=papa;
  select id into mama_ref from public.domain_actor_refs
    where household_id=hh and actor_kind='real_user' and real_user_id=mama;
  if papa_ref is null or mama_ref is null then raise exception 'FAIL Q59 fixture: actor refs missing'; end if;

  select id into drop_def from public.task_definitions where household_id=hh and code='dropoff';
  insert into public.task_instances(
    household_id,task_definition_id,origin,title,category,routine_phase,scheduled_date,
    planned_assignee_id,planned_assignee_actor_ref_id,assignment_mode,assignment_source,
    completion_mode,status,source,created_by,expectation
  ) values(
    hh,drop_def,'recurring','ゴミ出し Q59 bulk correction','dropoff','morning','2026-10-29',
    papa,papa_ref,'person','manual','whole','todo','recurring',papa,'required'
  ) returning id into task_id;

  perform public.server_tx_dispatch_routine_automation(
    ('2026-10-29 07:00:00'::timestamp at time zone 'Asia/Tokyo'),2000
  );
  select id into session_id from public.routine_checkin_sessions
    where household_id=hh and session_type='dropoff' and scheduled_date='2026-10-29' and assignee_id=papa;
  if session_id is null then raise exception 'FAIL Q59 fixture: routine session missing'; end if;

  -- 1. Papa says "全部やった": immediate bulk truth is self-completed.
  bulk_result:=public.server_tx_reconcile_routine_session_v2(papa,bulk_op,session_id,'all_done');
  if coalesce((bulk_result->>'undo_available')::boolean,false) is not true then
    raise exception 'FAIL Q59: bulk operation did not expose immediate undo';
  end if;
  if (select status from public.task_instances where id=task_id)<>'completed'
     or (select actual_completed_by_id from public.task_instances where id=task_id)<>papa then
    raise exception 'FAIL Q59: all_done did not establish self actual truth';
  end if;
  if not exists(
    select 1 from public.task_actual_participants
    where household_id=hh and task_instance_id=task_id and actor_ref_id=papa_ref and removed_at is null
  ) then raise exception 'FAIL Q59: all_done canonical self participant missing'; end if;

  select (after_state->>'revision')::bigint into bulk_after_revision
  from public.routine_reconciliation_snapshots
  where operation_id=bulk_op and task_instance_id=task_id;
  if bulk_after_revision is null then raise exception 'FAIL Q59: bulk snapshot missing'; end if;

  -- 2. Immediately correct the exception: this one was actually handled by Mama.
  correction_result:=public.server_tx_routine_session_item_action_v3(
    papa,correction_op,session_id,task_id,'partner_handled','pwa',null,bulk_op
  );
  if coalesce((correction_result->>'corrected_actual')::boolean,false) is not true
     or correction_result->>'reconciliation_outcome'<>'partner_handled' then
    raise exception 'FAIL Q59: bulk exception did not report canonical actual correction: %',correction_result;
  end if;

  select revision into corrected_revision from public.task_instances where id=task_id;
  if (select status from public.task_instances where id=task_id)<>'completed'
     or (select actual_completed_by_id from public.task_instances where id=task_id)<>mama
     or corrected_revision<=bulk_after_revision then
    raise exception 'FAIL Q59: compatibility actual performer/revision did not move from Papa to Mama';
  end if;

  -- Canonical history: old self evidence is retained as removed; only Mama is active.
  if not exists(
    select 1 from public.task_actual_participants
    where household_id=hh and task_instance_id=task_id and actor_ref_id=papa_ref and removed_at is not null
  ) then raise exception 'FAIL Q59: old Papa actual evidence was overwritten instead of history-preserved'; end if;
  if not exists(
    select 1 from public.task_actual_participants
    where household_id=hh and task_instance_id=task_id and actor_ref_id=mama_ref and removed_at is null
  ) then raise exception 'FAIL Q59: Mama is not the active canonical actual performer'; end if;
  if (select count(*) from public.task_actual_participants
      where household_id=hh and task_instance_id=task_id and removed_at is null)<>1 then
    raise exception 'FAIL Q59: correction left multiple active actual performers';
  end if;
  if not exists(
    select 1 from public.routine_item_reconciliation_outcomes
    where household_id=hh and session_id=session_id and task_instance_id=task_id
      and actor_user_id=papa and outcome='partner_handled' and source='pwa' and operation_id=correction_op
  ) then raise exception 'FAIL Q59: reconciliation outcome split from corrected actual truth'; end if;

  -- History read model uses active task_actual_participants first; these two
  -- assertions are its exact durable inputs and must both point to Mama.
  if (select actual_completed_by_id from public.task_instances where id=task_id)<>mama
     or (select real_user_id from public.domain_actor_refs where id=(
          select actor_ref_id from public.task_actual_participants
          where household_id=hh and task_instance_id=task_id and removed_at is null
          limit 1
        ))<>mama then
    raise exception 'FAIL Q59: history/read-model performer inputs disagree';
  end if;

  -- 3. Duplicate tap/webhook retry is exactly idempotent: no revision or participant drift.
  replay_result:=public.server_tx_routine_session_item_action_v3(
    papa,correction_op,session_id,task_id,'partner_handled','pwa',null,bulk_op
  );
  if replay_result is distinct from correction_result
     or (select revision from public.task_instances where id=task_id)<>corrected_revision
     or (select count(*) from public.task_actual_participants
         where household_id=hh and task_instance_id=task_id and removed_at is null and actor_ref_id=mama_ref)<>1 then
    raise exception 'FAIL Q59: correction replay was not idempotent';
  end if;

  -- 4. A different household cannot use the session/task/bulk receipt to mutate truth.
  failed:=false;
  begin
    perform public.server_tx_routine_session_item_action_v3(
      outsider,gen_random_uuid(),session_id,task_id,'partner_handled','pwa',null,bulk_op
    );
  exception when others then
    failed:=position('CROSS_HOUSEHOLD_RESOURCE' in sqlerrm)>0;
  end;
  if not failed then raise exception 'FAIL Q59: cross-household bulk correction was not rejected'; end if;
  if (select actual_completed_by_id from public.task_instances where id=task_id)<>mama
     or (select revision from public.task_instances where id=task_id)<>corrected_revision then
    raise exception 'FAIL Q59: rejected cross-household action partially mutated truth';
  end if;

  -- 5. The old bulk undo is now stale because a legitimate later correction exists.
  failed:=false;
  begin
    perform public.server_tx_undo_routine_reconciliation(papa,gen_random_uuid(),bulk_op);
  exception when others then
    failed:=position('RECONCILIATION_UNDO_STALE' in sqlerrm)>0;
  end;
  if not failed then raise exception 'FAIL Q59: old bulk undo rewound the later performer correction'; end if;
  if (select actual_completed_by_id from public.task_instances where id=task_id)<>mama
     or (select revision from public.task_instances where id=task_id)<>corrected_revision
     or (select status from public.routine_reconciliation_operations where id=bulk_op)<>'applied' then
    raise exception 'FAIL Q59: stale undo partially changed corrected truth';
  end if;

  if other_hh is null then raise exception 'FAIL Q59 fixture: outsider household missing'; end if;
end;
$$;

reset role;
select '77_issue48_q59_bulk_partner_correction: PASS' as result;
