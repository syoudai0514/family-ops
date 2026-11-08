\set ON_ERROR_STOP on
begin;
insert into auth.users(id) values
  ('19300000-0000-4000-8000-000000000011'),
  ('19300000-0000-4000-8000-000000000012'),
  ('19300000-0000-4000-8000-000000000013');
set role service_role;
do $$
declare
  v_actor uuid:='19300000-0000-4000-8000-000000000011';
  v_partner uuid:='19300000-0000-4000-8000-000000000012';
  v_stranger uuid:='19300000-0000-4000-8000-000000000013';
  v_hh uuid;
  v_other_hh uuid;
  v_task uuid;
  v_pending uuid:=gen_random_uuid();
  v_old_pending uuid:=gen_random_uuid();
  v_op uuid:=gen_random_uuid();
  v_reopen_op uuid:=gen_random_uuid();
  v_revision bigint;
  v_result jsonb;
  v_due timestamptz:=((now() at time zone 'Asia/Tokyo')::date+1+time '09:30') at time zone 'Asia/Tokyo';
begin
  v_hh:=(public.server_tx_create_household(v_actor,gen_random_uuid(),'LINE correction','Owner')->>'household_id')::uuid;
  insert into public.household_members(household_id,user_id,member_role) values(v_hh,v_partner,'adult');
  v_other_hh:=(public.server_tx_create_household(v_stranger,gen_random_uuid(),'Other correction','Owner')->>'household_id')::uuid;
  v_task:=(public.server_tx_create_task_with_calendar(v_actor,gen_random_uuid(),
    'Saved task','chore',(now() at time zone 'Asia/Tokyo')::date,time '08:00',null,
    'hidden',v_actor,'whole','anytime',null)->>'task_id')::uuid;
  insert into private.pending_actions(id,household_id,actor_id,source,action_type,
    normalized_payload,operation_id,status,expires_at,result_type,result_id)
  values(v_pending,v_hh,v_actor,'line','task_create_once','{}',gen_random_uuid(),'succeeded',
    now()+interval '15 minutes','task',v_task);
  v_result:=public.server_read_line_saved_task_v1(v_actor,v_pending);
  if (v_result->>'task_id')::uuid<>v_task or not (v_result->>'can_reschedule')::boolean then
    raise exception 'FAIL saved correction: own exact target unreadable';
  end if;
  v_revision:=(v_result->>'revision')::bigint;
  begin
    perform public.server_read_line_saved_task_v1(v_partner,v_pending);
    raise exception 'FAIL saved correction: partner read another author provenance';
  exception when others then
    if sqlerrm<>'LINE_SAVED_TASK_NOT_CORRECTABLE' then raise; end if;
  end;
  begin
    perform public.server_read_line_saved_task_v1(v_stranger,v_pending);
    raise exception 'FAIL saved correction: cross household read';
  exception when others then
    if sqlerrm<>'LINE_SAVED_TASK_NOT_CORRECTABLE' then raise; end if;
  end;
  v_result:=public.server_tx_correct_line_saved_task_v1(v_actor,v_op,v_pending,v_revision,'reschedule',v_due);
  if (v_result->>'revision')::bigint<=v_revision or
    (select due_at from public.task_instances where id=v_task)<>v_due or
    (select title from public.task_instances where id=v_task)<>'Saved task' or
    (select planned_assignee_id from public.task_instances where id=v_task)<>v_actor then
    raise exception 'FAIL saved correction: explicit schedule did not preserve other task data';
  end if;
  if not exists(select 1 from public.task_events where household_id=v_hh and task_instance_id=v_task
    and source='line' and idempotency_key=(md5(v_op::text||':saved-task-command'))::uuid::text||':edited') then
    raise exception 'FAIL saved correction: LINE provenance missing';
  end if;
  -- Response lost: same displayed confirmation returns saved result despite CAS.
  if public.server_tx_correct_line_saved_task_v1(v_actor,v_op,v_pending,v_revision,'reschedule',v_due)<>v_result then
    raise exception 'FAIL saved correction: replay changed result';
  end if;
  begin
    perform public.server_tx_correct_line_saved_task_v1(v_actor,gen_random_uuid(),v_pending,v_revision,'reschedule',v_due);
    raise exception 'FAIL saved correction: stale revision accepted';
  exception when others then
    if sqlerrm<>'AGGREGATE_REVISION_CONFLICT' then raise; end if;
  end;
  begin
    perform public.server_tx_correct_line_saved_task_v1(v_actor,v_op,v_pending,v_revision,'reschedule',v_due+interval '1 hour');
    raise exception 'FAIL saved correction: mismatched retry accepted';
  exception when others then
    if sqlerrm<>'IDEMPOTENCY_CONFLICT' then raise; end if;
  end;
  -- Return to today, so reopen's recent-day boundary is exercised separately
  -- from the actual-performer restriction.
  v_result:=public.server_tx_correct_line_saved_task_v1(v_actor,gen_random_uuid(),v_pending,
    (v_result->>'revision')::bigint,'reschedule',v_due-interval '1 day');
  -- Completed partner work cannot be erased through the original creator's card.
  perform public.server_tx_complete_task(v_partner,gen_random_uuid(),v_task,'self',false);
  v_result:=public.server_read_line_saved_task_v1(v_actor,v_pending);
  if (v_result->>'can_reopen')::boolean then raise exception 'FAIL saved correction: partner completion exposed reopen'; end if;
  begin
    perform public.server_tx_correct_line_saved_task_v1(v_actor,v_reopen_op,v_pending,
      (v_result->>'revision')::bigint,'reopen',null);
    raise exception 'FAIL saved correction: partner completion reopened';
  exception when others then
    if sqlerrm<>'LINE_SAVED_TASK_NOT_CORRECTABLE' then raise; end if;
  end;
  perform public.server_tx_reopen_task(v_partner,gen_random_uuid(),v_task,(v_result->>'revision')::bigint,'line');
  perform public.server_tx_complete_task(v_actor,gen_random_uuid(),v_task,'self',false);
  v_result:=public.server_read_line_saved_task_v1(v_actor,v_pending);
  if not (v_result->>'can_reopen')::boolean then raise exception 'FAIL saved correction: own recent completion cannot reopen'; end if;
  v_result:=public.server_tx_correct_line_saved_task_v1(v_actor,v_reopen_op,v_pending,
    (v_result->>'revision')::bigint,'reopen',null);
  if (v_result->>'status')<>'todo' then raise exception 'FAIL saved correction: reopen failed'; end if;
  -- An old pending row cannot initiate new corrections. Its expiry must not be
  -- revived by opening the original conversation.
  insert into private.pending_actions(id,household_id,actor_id,source,action_type,
    normalized_payload,operation_id,status,expires_at,result_type,result_id,created_at,updated_at)
  values(v_old_pending,v_hh,v_actor,'line','task_create_once','{}',gen_random_uuid(),'succeeded',
    now()-interval '24 hours','task',v_task,now()-interval '25 hours',now()-interval '25 hours');
  begin
    perform public.server_read_line_saved_task_v1(v_actor,v_old_pending);
    raise exception 'FAIL saved correction: old provenance allowed new correction';
  exception when others then
    if sqlerrm<>'LINE_SAVED_TASK_NOT_CORRECTABLE' then raise; end if;
  end;
  if (select count(*) from public.task_instances where household_id=v_hh and created_by=v_actor)<>1 then
    raise exception 'FAIL saved correction: duplicate task created';
  end if;
end; $$;
reset role;
set role authenticated;
do $$ begin
  begin
    perform public.server_read_line_saved_task_v1(gen_random_uuid(),gen_random_uuid());
    raise exception 'FAIL saved correction: public RPC callable by browser';
  exception when insufficient_privilege then null; end;
  begin
    perform public.server_tx_correct_line_saved_task_v1(gen_random_uuid(),gen_random_uuid(),gen_random_uuid(),1,'reopen',null);
    raise exception 'FAIL saved correction: write RPC callable by browser';
  exception when insufficient_privilege then null; end;
end; $$;
reset role;
rollback;
