-- Issue #48 independent review remediation — direct literal regressions.
-- Q59: bulk completion is immediate, receipt-scoped, and exactly undoable with CAS.
-- Q64: seven distinct individual reconciliation truths survive PWA/LINE parity.
\set ON_ERROR_STOP on
set role service_role;

do $$
declare
  u1 uuid:=gen_random_uuid(); u2 uuid:=gen_random_uuid(); u3 uuid:=gen_random_uuid();
  hh uuid; hh_other uuid; token text; actor1 uuid; drop_def uuid;
  s_ok uuid; s_stale uuid; s64 uuid;
  ok1 uuid; ok2 uuid; stale1 uuid; stale2 uuid;
  t_complete uuid; t_partner uuid; t_failed uuid; t_skip uuid; t_cancel uuid; t_resched uuid; t_unknown uuid;
  bulk_ok uuid:=gen_random_uuid(); bulk_stale uuid:=gen_random_uuid(); undo_op uuid:=gen_random_uuid(); undo_replay jsonb;
  r jsonb; r2 jsonb; failed boolean:=false; unknown_policy text;
begin
  insert into auth.users(id) values(u1),(u2),(u3);
  insert into public.profiles(user_id,display_name) values(u1,'Q59/64 Papa'),(u2,'Q59/64 Mama'),(u3,'Q59/64 Other');
  hh:=(public.server_tx_create_household(u1,gen_random_uuid(),'Q59 Q64 H1','Papa')->>'household_id')::uuid;
  token:=public.server_tx_create_household_invite(u1,gen_random_uuid())->>'raw_token';
  perform public.server_tx_join_household(u2,gen_random_uuid(),token,'Mama');
  hh_other:=(public.server_tx_create_household(u3,gen_random_uuid(),'Q59 Q64 H2','Other')->>'household_id')::uuid;
  select id into actor1 from public.domain_actor_refs where household_id=hh and actor_kind='real_user' and real_user_id=u1;
  select id into drop_def from public.task_definitions where household_id=hh and code='dropoff';

  -- -------------------------------------------------------------------------
  -- Q59 success path: immediate all_done -> exact receipt -> exact undo.
  -- -------------------------------------------------------------------------
  insert into public.task_instances(household_id,task_definition_id,origin,title,category,routine_phase,scheduled_date,
    planned_assignee_id,planned_assignee_actor_ref_id,assignment_mode,assignment_source,completion_mode,status,source,created_by,expectation)
  values(hh,drop_def,'recurring','送り Q59 undo','dropoff','morning','2026-10-26',u1,actor1,'person','manual','whole','todo','recurring',u1,'required') returning id into ok1;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,
    planned_assignee_id,planned_assignee_actor_ref_id,assignment_mode,assignment_source,completion_mode,status,source,created_by,expectation)
  values(hh,'manual','水筒 Q59 undo','prep','morning','2026-10-26',u1,actor1,'person','manual','whole','todo','manual',u1,'required') returning id into ok2;
  perform public.server_tx_dispatch_routine_automation(('2026-10-26 07:00:00'::timestamp at time zone 'Asia/Tokyo'),2000);
  select id into s_ok from public.routine_checkin_sessions where household_id=hh and session_type='dropoff' and scheduled_date='2026-10-26' and assignee_id=u1;
  if s_ok is null then raise exception 'FAIL Q59: routine session fixture missing'; end if;

  r:=public.server_tx_reconcile_routine_session_v2(u1,bulk_ok,s_ok,'all_done');
  if (r->>'reconciliation_operation_id')::uuid<>bulk_ok or coalesce((r->>'undo_available')::boolean,false) is not true then
    raise exception 'FAIL Q59: bulk operation did not return immediate undo receipt: %',r;
  end if;
  if (select count(*) from public.task_instances where id in(ok1,ok2) and status='completed')<>2 then
    raise exception 'FAIL Q59: all_done did not commit immediately';
  end if;
  if (select count(*) from public.routine_reconciliation_snapshots where operation_id=bulk_ok)<>2 then
    raise exception 'FAIL Q59: receipt scope is not exactly the two rows changed by this bulk operation';
  end if;

  r2:=public.server_tx_undo_routine_reconciliation(u1,undo_op,bulk_ok);
  if r2->>'status'<>'undone' or (select count(*) from public.task_instances where id in(ok1,ok2) and status='todo')<>2 then
    raise exception 'FAIL Q59: exact bulk undo did not restore prior task state: %',r2;
  end if;
  undo_replay:=public.server_tx_undo_routine_reconciliation(u1,undo_op,bulk_ok);
  if undo_replay is distinct from r2 then raise exception 'FAIL Q59: undo idempotent replay changed result'; end if;

  -- -------------------------------------------------------------------------
  -- Q59 stale path: a later task update blocks the ENTIRE old bulk undo.
  -- -------------------------------------------------------------------------
  insert into public.task_instances(household_id,task_definition_id,origin,title,category,routine_phase,scheduled_date,
    planned_assignee_id,planned_assignee_actor_ref_id,assignment_mode,assignment_source,completion_mode,status,source,created_by,expectation)
  values(hh,drop_def,'recurring','送り Q59 stale','dropoff','morning','2026-10-27',u1,actor1,'person','manual','whole','todo','recurring',u1,'required') returning id into stale1;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,
    planned_assignee_id,planned_assignee_actor_ref_id,assignment_mode,assignment_source,completion_mode,status,source,created_by,expectation)
  values(hh,'manual','帽子 Q59 stale','prep','morning','2026-10-27',u1,actor1,'person','manual','whole','todo','manual',u1,'required') returning id into stale2;
  perform public.server_tx_dispatch_routine_automation(('2026-10-27 07:00:00'::timestamp at time zone 'Asia/Tokyo'),2000);
  select id into s_stale from public.routine_checkin_sessions where household_id=hh and session_type='dropoff' and scheduled_date='2026-10-27' and assignee_id=u1;
  r:=public.server_tx_reconcile_routine_session_v2(u1,bulk_stale,s_stale,'all_done');
  if (select count(*) from public.task_instances where id in(stale1,stale2) and status='completed')<>2 then
    raise exception 'FAIL Q59: stale fixture bulk complete failed';
  end if;
  -- Simulate a legitimate later edit after bulk completion. The old receipt must never rewind it.
  update public.task_instances set title=title||'（後更新）',revision=revision+1 where id=stale1;
  failed:=false;
  begin
    perform public.server_tx_undo_routine_reconciliation(u1,gen_random_uuid(),bulk_stale);
  exception when others then failed:=position('RECONCILIATION_UNDO_STALE' in sqlerrm)>0; end;
  if not failed then raise exception 'FAIL Q59: stale bulk undo overwrote later update'; end if;
  if (select count(*) from public.task_instances where id in(stale1,stale2) and status='completed')<>2
     or (select title from public.task_instances where id=stale1) not like '%（後更新）' then
    raise exception 'FAIL Q59: failed stale undo partially rewound tasks';
  end if;
  if (select status from public.routine_reconciliation_operations where id=bulk_stale)<>'applied' then
    raise exception 'FAIL Q59: stale undo incorrectly marked operation undone';
  end if;

  -- -------------------------------------------------------------------------
  -- Q64: seven distinct answers, mixed LINE/PWA, one canonical truth model.
  -- -------------------------------------------------------------------------
  insert into public.task_instances(household_id,task_definition_id,origin,title,category,routine_phase,scheduled_date,
    planned_assignee_id,planned_assignee_actor_ref_id,assignment_mode,assignment_source,completion_mode,status,source,created_by,expectation)
  values(hh,drop_def,'recurring','Q64 完了','dropoff','morning','2026-10-28',u1,actor1,'person','manual','whole','todo','recurring',u1,'required') returning id into t_complete;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,planned_assignee_id,planned_assignee_actor_ref_id,assignment_mode,assignment_source,completion_mode,status,source,created_by,expectation)
  values(hh,'manual','Q64 相手が対応','prep','morning','2026-10-28',u1,actor1,'person','manual','whole','todo','manual',u1,'required') returning id into t_partner;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,planned_assignee_id,planned_assignee_actor_ref_id,assignment_mode,assignment_source,completion_mode,status,source,created_by,expectation)
  values(hh,'manual','Q64 できなかった','prep','morning','2026-10-28',u1,actor1,'person','manual','whole','todo','manual',u1,'required') returning id into t_failed;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,planned_assignee_id,planned_assignee_actor_ref_id,assignment_mode,assignment_source,completion_mode,status,source,created_by,expectation)
  values(hh,'manual','Q64 今回不要','prep','morning','2026-10-28',u1,actor1,'person','manual','whole','todo','manual',u1,'required') returning id into t_skip;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,planned_assignee_id,planned_assignee_actor_ref_id,assignment_mode,assignment_source,completion_mode,status,source,created_by,expectation)
  values(hh,'manual','Q64 中止','prep','morning','2026-10-28',u1,actor1,'person','manual','whole','todo','manual',u1,'required') returning id into t_cancel;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,planned_assignee_id,planned_assignee_actor_ref_id,assignment_mode,assignment_source,completion_mode,status,source,created_by,expectation)
  values(hh,'manual','Q64 再予定','prep','morning','2026-10-28',u1,actor1,'person','manual','whole','todo','manual',u1,'required') returning id into t_resched;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,scheduled_date,planned_assignee_id,planned_assignee_actor_ref_id,assignment_mode,assignment_source,completion_mode,status,source,created_by,expectation)
  values(hh,'manual','Q64 不明','prep','morning','2026-10-28',u1,actor1,'person','manual','whole','todo','manual',u1,'required') returning id into t_unknown;

  select carryover_policy into unknown_policy from public.task_instances where id=t_unknown;
  perform public.server_tx_dispatch_routine_automation(('2026-10-28 07:00:00'::timestamp at time zone 'Asia/Tokyo'),2000);
  select id into s64 from public.routine_checkin_sessions where household_id=hh and session_type='dropoff' and scheduled_date='2026-10-28' and assignee_id=u1;
  if s64 is null or (select count(*) from public.routine_checkin_session_items where session_id=s64)<>7 then
    raise exception 'FAIL Q64: seven-item individual reconciliation fixture missing';
  end if;

  -- Cross-household actor is rejected before any truth mutation.
  failed:=false;
  begin
    perform public.server_tx_routine_session_item_action_v3(u3,gen_random_uuid(),s64,t_complete,'complete','pwa');
  exception when others then failed:=position('CROSS_HOUSEHOLD_RESOURCE' in sqlerrm)>0; end;
  if not failed then raise exception 'FAIL Q64: cross-household item action succeeded'; end if;

  perform public.server_tx_routine_session_item_action_v3(u1,gen_random_uuid(),s64,t_complete,'complete','pwa');
  perform public.server_tx_routine_session_item_action_v3(u1,gen_random_uuid(),s64,t_partner,'partner_handled','line');
  perform public.server_tx_routine_session_item_action_v3(u1,gen_random_uuid(),s64,t_failed,'failed','pwa');
  perform public.server_tx_routine_session_item_action_v3(u1,gen_random_uuid(),s64,t_skip,'skip','line');
  perform public.server_tx_routine_session_item_action_v3(u1,gen_random_uuid(),s64,t_cancel,'cancelled','pwa');
  perform public.server_tx_routine_session_item_action_v3(u1,gen_random_uuid(),s64,t_resched,'rescheduled','line','2026-10-29');
  perform public.server_tx_routine_session_item_action_v3(u1,gen_random_uuid(),s64,t_unknown,'unknown','pwa');

  if (select count(distinct outcome) from public.routine_item_reconciliation_outcomes where session_id=s64)<>7
     or not exists(select 1 from public.routine_item_reconciliation_outcomes where session_id=s64 and task_instance_id=t_complete and outcome='completed')
     or not exists(select 1 from public.routine_item_reconciliation_outcomes where session_id=s64 and task_instance_id=t_partner and outcome='partner_handled')
     or not exists(select 1 from public.routine_item_reconciliation_outcomes where session_id=s64 and task_instance_id=t_failed and outcome='could_not_do')
     or not exists(select 1 from public.routine_item_reconciliation_outcomes where session_id=s64 and task_instance_id=t_skip and outcome='not_needed')
     or not exists(select 1 from public.routine_item_reconciliation_outcomes where session_id=s64 and task_instance_id=t_cancel and outcome='cancelled')
     or not exists(select 1 from public.routine_item_reconciliation_outcomes where session_id=s64 and task_instance_id=t_resched and outcome='rescheduled' and rescheduled_to='2026-10-29')
     or not exists(select 1 from public.routine_item_reconciliation_outcomes where session_id=s64 and task_instance_id=t_unknown and outcome='unknown') then
    raise exception 'FAIL Q64: one or more individual truths collapsed into another state';
  end if;
  if (select count(*) from public.routine_item_reconciliation_outcomes where session_id=s64 and source='line')<>3
     or (select count(*) from public.routine_item_reconciliation_outcomes where session_id=s64 and source='pwa')<>4 then
    raise exception 'FAIL Q64: LINE/PWA parity evidence missing';
  end if;
  if (select status from public.task_instances where id=t_complete)<>'completed'
     or (select status from public.task_instances where id=t_partner)<>'completed'
     or (select outcome_reason from public.task_instances where id=t_failed)<>'could_not_do'
     or (select outcome_reason from public.task_instances where id=t_skip)<>'not_needed_this_occurrence'
     or (select status from public.task_instances where id=t_cancel)<>'cancelled'
     or (select outcome_reason from public.task_instances where id=t_resched)<>'rescheduled'
     or (select rescheduled_to from public.task_instances where id=t_resched)<>date '2026-10-29'
     or (select outcome_reason from public.task_instances where id=t_unknown)<>'unknown' then
    raise exception 'FAIL Q64: canonical task truth does not match seven answers';
  end if;
  if coalesce(unknown_policy,'occurrence_ends')='occurrence_ends' then
    if (select status from public.task_instances where id=t_unknown)<>'skipped' then raise exception 'FAIL Q64: occurrence-ending unknown did not close occurrence'; end if;
  else
    if (select status from public.task_instances where id=t_unknown) not in('todo','in_progress') then raise exception 'FAIL Q64: carryover unknown was incorrectly terminalized'; end if;
  end if;
  if (select status from public.routine_checkin_sessions where id=s64)<>'submitted' then
    raise exception 'FAIL Q64: seven explicit answers did not submit reconciliation';
  end if;
  if hh_other is null then raise exception 'FAIL Q64 fixture'; end if;
end;
$$;
reset role;
select '76_issue48_q59_q64_literal_regression: PASS' as result;
