\set ON_ERROR_STOP on
begin;
set role service_role;
do $$
declare
  v_actor uuid:=gen_random_uuid();
  v_partner uuid:=gen_random_uuid();
  v_stranger uuid:=gen_random_uuid();
  v_hh uuid;
  v_other_hh uuid;
  v_task uuid;
  v_stale_task uuid;
  v_future_task uuid;
  v_foreign_task uuid;
  v_submit uuid;
  v_failed uuid; v_old_failed uuid; v_other_failed uuid; v_undo_op uuid:=gen_random_uuid();
  v_today date:=(now() at time zone 'Asia/Tokyo')::date;
  v_op uuid:=gen_random_uuid();
  v_codmon_op uuid:=gen_random_uuid();
  v_revision bigint;
  v_count integer;
  v_result jsonb;
begin
  insert into auth.users(id) values(v_actor),(v_partner),(v_stranger);
  v_hh:=(public.server_tx_create_household(v_actor,gen_random_uuid(),'Daily revision','Owner')->>'household_id')::uuid;
  insert into public.household_members(household_id,user_id,member_role) values(v_hh,v_partner,'adult');
  v_other_hh:=(public.server_tx_create_household(v_stranger,gen_random_uuid(),'Other daily revision','Owner')->>'household_id')::uuid;
  v_task:=(public.server_tx_create_task_with_calendar(v_actor,gen_random_uuid(),
    'Daily task','chore',v_today,time '08:00',null,'hidden',v_actor,'whole','anytime',null)->>'task_id')::uuid;
  v_stale_task:=(public.server_tx_create_task_with_calendar(v_actor,gen_random_uuid(),
    'Stale daily task','chore',v_today-1,time '08:00',null,'hidden',v_actor,'whole','anytime',null)->>'task_id')::uuid;
  v_future_task:=(public.server_tx_create_task_with_calendar(v_actor,gen_random_uuid(),
    'Future task','chore',v_today+1,time '08:00',null,'hidden',v_actor,'whole','anytime',null)->>'task_id')::uuid;
  v_foreign_task:=(public.server_tx_create_task_with_calendar(v_stranger,gen_random_uuid(),
    'Foreign task','chore',v_today,time '08:00',null,'hidden',v_stranger,'whole','anytime',null)->>'task_id')::uuid;
  select revision into v_revision from public.task_instances where id=v_task;
  v_result:=public.server_tx_complete_line_daily_task_v1(v_actor,v_op,v_task,v_revision,v_today);
  if (v_result->>'revision')::bigint<>v_revision+1 or v_result->>'status'<>'completed'
    or (v_result->>'codmon_sent')::boolean is distinct from false
    or (select actual_completed_by_id from public.task_instances where id=v_task)<>v_actor then
    raise exception 'FAIL daily completion: canonical self completion missing';
  end if;
  select count(*) into v_count from public.task_events where task_instance_id=v_task and event_type='completed';
  if public.server_tx_complete_line_daily_task_v1(v_actor,v_op,v_task,v_revision,v_today)<>v_result
    or (select count(*) from public.task_events where task_instance_id=v_task and event_type='completed')<>v_count then
    raise exception 'FAIL daily completion: same-button replay did not return saved result';
  end if;
  if not exists(select 1 from public.task_events where task_instance_id=v_task and event_type='completed' and source='line') then
    raise exception 'FAIL daily completion: LINE source missing';
  end if;
  begin
    perform public.server_tx_complete_line_daily_task_v1(v_actor,v_op,v_task,v_revision+1,v_today);
    raise exception 'FAIL daily completion: changed payload reused receipt';
  exception when others then if sqlerrm<>'IDEMPOTENCY_CONFLICT' then raise; end if; end;
  begin
    perform public.server_tx_complete_line_daily_task_v1(v_actor,gen_random_uuid(),v_task,v_revision,v_today);
    raise exception 'FAIL daily completion: stale card accepted';
  exception when others then if sqlerrm<>'AGGREGATE_REVISION_CONFLICT' then raise; end if; end;
  select revision into v_revision from public.task_instances where id=v_stale_task;
  -- Competing canonical completion changes the aggregate while this card is open.
  perform public.server_tx_complete_task(v_partner,gen_random_uuid(),v_stale_task,'self',true,'pwa');
  begin
    perform public.server_tx_complete_line_daily_task_v1(v_actor,gen_random_uuid(),v_stale_task,v_revision,v_today-1);
    raise exception 'FAIL daily completion: partner update ignored revision';
  exception when others then if sqlerrm<>'AGGREGATE_REVISION_CONFLICT' then raise; end if; end;
  begin
    perform public.server_tx_complete_line_daily_task_v1(v_actor,gen_random_uuid(),v_future_task,1,v_today+1);
    raise exception 'FAIL daily completion: future card accepted';
  exception when others then if sqlerrm<>'LINE_DAILY_TASK_DAY_STALE' then raise; end if; end;
  begin
    perform public.server_tx_complete_line_daily_task_v1(v_actor,gen_random_uuid(),v_foreign_task,1,v_today);
    raise exception 'FAIL daily completion: foreign household accepted';
  exception when others then if sqlerrm<>'CROSS_HOUSEHOLD_RESOURCE' then raise; end if; end;
  begin
    perform public.server_tx_complete_line_daily_task_v1(v_actor,gen_random_uuid(),v_future_task,1,v_today);
    raise exception 'FAIL daily completion: wrong day accepted';
  exception when others then if sqlerrm<>'AGGREGATE_REVISION_CONFLICT' then raise; end if; end;
  v_failed:=(public.server_tx_create_task_with_calendar(v_actor,gen_random_uuid(),
    'Failed yesterday','chore',v_today-1,time '08:00',null,'hidden',v_actor,'whole','anytime',null)->>'task_id')::uuid;
  v_old_failed:=(public.server_tx_create_task_with_calendar(v_actor,gen_random_uuid(),
    'Old failed','chore',v_today-5,time '08:00',null,'hidden',v_actor,'whole','anytime',null)->>'task_id')::uuid;
  v_other_failed:=(public.server_tx_create_task_with_calendar(v_actor,gen_random_uuid(),
    'Partner failed','chore',v_today,time '08:00',null,'hidden',v_partner,'whole','anytime',null)->>'task_id')::uuid;
  perform public.server_tx_mark_task_could_not_do_v1(v_actor,gen_random_uuid(),v_failed,false,'pwa');
  perform public.server_tx_mark_task_could_not_do_v1(v_actor,gen_random_uuid(),v_old_failed,false,'pwa');
  perform public.server_tx_mark_task_could_not_do_v1(v_partner,gen_random_uuid(),v_other_failed,false,'pwa');
  select revision into v_revision from public.task_instances where id=v_failed;
  v_result:=public.server_tx_undo_line_daily_failure_v1(v_actor,v_undo_op,v_failed,v_revision,v_today-1);
  if (select status from public.task_instances where id=v_failed)<>'todo'
    or public.server_tx_undo_line_daily_failure_v1(v_actor,v_undo_op,v_failed,v_revision,v_today-1)<>v_result then
    raise exception 'FAIL daily failure: undo or replay'; end if;
  begin
    perform public.server_tx_undo_line_daily_failure_v1(v_actor,gen_random_uuid(),v_failed,v_revision,v_today-1);
    raise exception 'FAIL daily failure: stale revision';
  exception when others then if sqlerrm<>'AGGREGATE_REVISION_CONFLICT' then raise; end if; end;
  select revision into v_revision from public.task_instances where id=v_old_failed;
  begin
    perform public.server_tx_undo_line_daily_failure_v1(v_actor,gen_random_uuid(),v_old_failed,v_revision,v_today);
    raise exception 'FAIL daily failure: forged today label';
  exception when others then if sqlerrm<>'AGGREGATE_REVISION_CONFLICT' then raise; end if; end;
  select revision into v_revision from public.task_instances where id=v_other_failed;
  begin
    perform public.server_tx_undo_line_daily_failure_v1(v_actor,gen_random_uuid(),v_other_failed,v_revision,v_today);
    raise exception 'FAIL daily failure: unrelated partner row';
  exception when others then if sqlerrm<>'ACTOR_SCOPE_CONFLICT' then raise; end if; end;
  -- The completion adapter uses the same actor relation as the recent list.
  perform public.server_tx_mark_task_could_not_do_v1(v_partner,gen_random_uuid(),v_other_failed,true,'pwa');
  select revision into v_revision from public.task_instances where id=v_other_failed;
  begin
    perform public.server_tx_complete_line_daily_task_v1(v_actor,gen_random_uuid(),v_other_failed,v_revision,v_today);
    raise exception 'FAIL daily completion: unrelated partner row';
  exception when others then if sqlerrm<>'ACTOR_SCOPE_CONFLICT' then raise; end if; end;
  -- Reuse already materialized current-day rows on weekdays; on weekends
  -- explicitly insert the missing nursery-day fixture without duplicates.
  perform private.fn_seed_codmon_daily_for_household_v1(v_hh,v_today);
  insert into public.task_instances(household_id,task_definition_id,origin,title,category,routine_phase,
    scheduled_date,due_at,planned_assignee_id,assignment_mode,assignment_source,completion_mode,status,source,created_by)
  select v_hh,td.id,'manual',td.title,td.category,td.routine_phase,v_today,
    (v_today+time '09:00') at time zone 'Asia/Tokyo',
    case when td.code in ('codmon_shino_previous_input','codmon_shino_breakfast_input') then v_partner else v_actor end,
    'person','legacy_snapshot','whole','todo','test',v_actor
  from public.task_definitions td where td.household_id=v_hh and td.code in ('codmon_submit',
    'codmon_masaki_pickup_input','codmon_shino_previous_input','codmon_shino_breakfast_input','codmon_shino_pickup_input')
    and not exists(select 1 from public.task_instances ti where ti.household_id=v_hh
      and ti.task_definition_id=td.id and ti.scheduled_date=v_today and ti.test_context_id is null);
  update public.task_instances ti set planned_assignee_id=case
    when td.code in ('codmon_shino_previous_input','codmon_shino_breakfast_input') then v_partner else v_actor end,
    planned_assignee_actor_ref_id=null, assignment_mode='person'
  from public.task_definitions td where ti.household_id=v_hh and td.household_id=v_hh
    and ti.task_definition_id=td.id and ti.scheduled_date=v_today and td.code like 'codmon_%';
  select ti.id,ti.revision into v_submit,v_revision from public.task_instances ti join public.task_definitions td
    on td.household_id=ti.household_id and td.id=ti.task_definition_id
    where ti.household_id=v_hh and ti.scheduled_date=v_today and td.code='codmon_submit';
  if v_submit is null then raise exception 'FAIL daily completion: missing Codmon fixture'; end if;
  begin
    perform public.server_tx_complete_line_daily_task_v1(v_actor,gen_random_uuid(),v_submit,v_revision,v_today);
    raise exception 'FAIL daily completion: generic button acknowledged Codmon send';
  exception when others then if sqlerrm<>'CODMON_SEND_CONFIRMATION_REQUIRED' then raise; end if; end;
  v_result:=public.server_tx_complete_line_daily_task_v1(v_actor,v_codmon_op,v_submit,v_revision,v_today,true);
  if (v_result->>'inputs_closed')::integer<>4 or (v_result->>'inputs_closed_by_partner')::integer<>2
    or (v_result->>'codmon_sent')::boolean is distinct from true
    or (private.fn_codmon_readiness_v1(v_hh,v_today,null)->>'state')<>'acknowledged' then
    raise exception 'FAIL daily completion: Codmon did not delegate acknowledgement %',v_result;
  end if;
  if exists(select 1 from public.task_instances ti join public.task_definitions td
    on td.household_id=ti.household_id and td.id=ti.task_definition_id
    where ti.household_id=v_hh and ti.scheduled_date=v_today and td.code in ('codmon_shino_previous_input','codmon_shino_breakfast_input')
      and ti.actual_completed_by_id is distinct from v_partner) then
    raise exception 'FAIL daily completion: planned partner input attribution lost';
  end if;
  select count(*) into v_count from public.task_events where household_id=v_hh and event_type='completed';
  if public.server_tx_complete_line_daily_task_v1(v_actor,v_codmon_op,v_submit,v_revision,v_today,true)<>v_result
    or (select count(*) from public.task_events where household_id=v_hh and event_type='completed')<>v_count then
    raise exception 'FAIL daily completion: Codmon replay changed receipt or duplicated events';
  end if;
end; $$;
reset role;
set role authenticated;
do $$ begin
  begin
    perform public.server_tx_complete_line_daily_task_v1(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),1,current_date);
    raise exception 'FAIL daily completion: browser can call service RPC';
  exception when insufficient_privilege then null; end;
end; $$;
reset role;
rollback;
