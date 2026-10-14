-- Native LINE confirmation binds a server snapshot to one real occurrence.
\set ON_ERROR_STOP on
begin;
set local role service_role;
do $$
declare
  papa uuid:=gen_random_uuid(); mama uuid:=gen_random_uuid(); outsider uuid:=gen_random_uuid();
  hh uuid; other_hh uuid; papa_ref uuid; mama_ref uuid;
  dropoff_def uuid; prep_def uuid; dinner_def uuid; dropoff uuid; prep uuid; ordinary uuid;
  chosen_date date:=(now() at time zone 'Asia/Tokyo')::date+1;
  operation uuid:=gen_random_uuid(); preview uuid; newer uuid; expired uuid; test_context uuid;
  snapshot jsonb; result jsonb; cancelled jsonb; requests_before bigint; tasks_before bigint;
begin
  insert into auth.users(id) values(papa),(mama),(outsider);
  hh:=(public.server_tx_create_household(papa,gen_random_uuid(),'LINE transport fixture','Dad')->>'household_id')::uuid;
  insert into public.household_members(household_id,user_id,member_role) values(hh,mama,'adult');
  update public.household_members set family_role=case when user_id=papa then 'papa' else 'mama' end where household_id=hh;
  other_hh:=(public.server_tx_create_household(outsider,gen_random_uuid(),'Other household','Other')->>'household_id')::uuid;
  perform private.backfill_canonical_foundation_v1();
  select id into papa_ref from public.domain_actor_refs where household_id=hh and real_user_id=papa and actor_kind='real_user';
  select id into mama_ref from public.domain_actor_refs where household_id=hh and real_user_id=mama and actor_kind='real_user';
  select id into dropoff_def from public.task_definitions where household_id=hh and code='dropoff';
  select id into prep_def from public.task_definitions where household_id=hh and code='prep_tuesday_gym';
  select id into dinner_def from public.task_definitions where household_id=hh and code='dinner';
  while private.fn_is_nonworkday(chosen_date) loop chosen_date:=chosen_date+1; end loop;
  insert into public.task_instances(
    household_id,task_definition_id,origin,title,category,task_kind,routine_phase,scheduled_date,due_at,
    planned_assignee_id,planned_assignee_actor_ref_id,completion_mode,status,source,created_by,
    assignment_mode,assignment_source
  ) values(hh,dropoff_def,'recurring','送り','dropoff','transport','morning',chosen_date,
    (chosen_date::text||' 08:10')::timestamp at time zone 'Asia/Tokyo',
    mama,mama_ref,'whole','todo','test',papa,'person','legacy_snapshot') returning id into dropoff;
  perform public.server_tx_change_recurrence(papa,gen_random_uuid(),prep_def,
    extract(isodow from chosen_date)::int,'default','dropoff_assignee',null,'07:20',60,chosen_date);
  select id into prep from public.task_instances where household_id=hh and task_definition_id=prep_def
    and scheduled_date=chosen_date and status='todo' order by created_at limit 1;
  if prep is null or (select planned_assignee_id from public.task_instances where id=prep) is distinct from mama then
    raise exception 'FAIL LINE preview: dependent fixture not assigned to original dropoff adult'; end if;
  select count(*) into requests_before from public.requests where household_id=hh;
  select count(*) into tasks_before from public.task_instances where household_id=hh;
  snapshot:=public.server_tx_prepare_line_transport_assignment_v1(papa,operation,dropoff,papa,1);
  preview:=(snapshot->>'id')::uuid;
  if snapshot->>'status'<>'draft' or snapshot->>'code'<>'dropoff'
    or snapshot->>'title'<>'送り' or snapshot->>'current_label'<>'ママ' or snapshot->>'target_label'<>'パパ'
    or (snapshot->>'actor_id')::uuid<>papa or (snapshot->>'assignee_user_id')::uuid<>papa
    or (snapshot->>'current_assignee_user_id')::uuid<>mama
    or (snapshot->>'scheduled_date')::date<>chosen_date
    or (snapshot->>'expires_at')::timestamptz<clock_timestamp()+interval '14 minutes'
    or (snapshot->>'expires_at')::timestamptz>clock_timestamp()+interval '16 minutes' then
    raise exception 'FAIL LINE preview: server snapshot incomplete: %',snapshot; end if;
  if (select revision from public.task_instances where id=dropoff)<>1
    or (select planned_assignee_id from public.task_instances where id=dropoff)<>mama
    or exists(select 1 from public.task_events where task_instance_id=dropoff) then
    raise exception 'FAIL LINE preview: prepare changed a task before explicit confirm'; end if;
  if public.server_tx_prepare_line_transport_assignment_v1(papa,operation,dropoff,papa,1) is distinct from snapshot
    or public.server_read_line_transport_assignment_preview_v1(papa) is distinct from snapshot
    or public.server_read_line_transport_assignment_preview_v1(mama) is not null then
    raise exception 'FAIL LINE preview: actor-bound prepare/read idempotency'; end if;
  begin
    perform public.server_tx_prepare_line_transport_assignment_v1(papa,operation,dropoff,mama,1);
    raise exception 'FAIL LINE preview: changed operation payload accepted';
  exception when others then if sqlerrm<>'IDEMPOTENCY_CONFLICT' then raise; end if; end;
  begin
    perform public.server_tx_prepare_line_transport_assignment_v1(papa,gen_random_uuid(),dropoff,outsider,1);
    raise exception 'FAIL LINE preview: cross-household target accepted';
  exception when others then if sqlerrm<>'LINE_TRANSPORT_PREVIEW_TARGET_INVALID' then raise; end if; end;
  begin
    perform public.server_tx_prepare_line_transport_assignment_v1(outsider,gen_random_uuid(),dropoff,outsider,1);
    raise exception 'FAIL LINE preview: cross-household task accepted';
  exception when others then if sqlerrm<>'LINE_TRANSPORT_PREVIEW_TASK_NOT_FOUND' then raise; end if; end;
  begin
    perform public.server_tx_decide_line_transport_assignment_v1(mama,preview,'confirm_agreed');
    raise exception 'FAIL LINE preview: other adult confirmed sender card';
  exception when others then if sqlerrm<>'LINE_TRANSPORT_PREVIEW_NOT_FOUND' then raise; end if; end;
  begin
    perform public.server_tx_decide_line_transport_assignment_v1(outsider,preview,'confirm_agreed');
    raise exception 'FAIL LINE preview: outsider confirmed sender card';
  exception when others then if sqlerrm<>'LINE_TRANSPORT_PREVIEW_NOT_FOUND' then raise; end if; end;
  begin
    perform public.server_tx_decide_line_transport_assignment_v1(papa,preview,'confirm');
    raise exception 'FAIL LINE preview: ambiguous action accepted';
  exception when others then if sqlerrm<>'INVALID_INPUT' then raise; end if; end;

  -- New cards supersede old ones; old postback IDs never select a newer card.
  result:=public.server_tx_prepare_line_transport_assignment_v1(papa,gen_random_uuid(),dropoff,papa,1);
  newer:=(result->>'id')::uuid;
  if (select status from private.line_transport_assignment_previews where id=preview)<>'superseded'
    or (public.server_read_line_transport_assignment_preview_v1(papa)->>'id')::uuid<>newer then
    raise exception 'FAIL LINE preview: latest card did not supersede previous'; end if;
  begin
    perform public.server_tx_decide_line_transport_assignment_v1(papa,preview,'confirm_agreed');
    raise exception 'FAIL LINE preview: superseded card confirmed';
  exception when others then if sqlerrm<>'LINE_TRANSPORT_PREVIEW_NOT_ACTIONABLE' then raise; end if; end;
  cancelled:=public.server_tx_decide_line_transport_assignment_v1(papa,newer,'cancel');
  if cancelled->>'status'<>'cancelled'
    or public.server_tx_decide_line_transport_assignment_v1(papa,newer,'cancel') is distinct from cancelled
    or (select revision from public.task_instances where id=dropoff)<>1 then
    raise exception 'FAIL LINE preview: cancel mutated a task or failed replay'; end if;
  begin
    perform public.server_tx_decide_line_transport_assignment_v1(papa,newer,'confirm_agreed');
    raise exception 'FAIL LINE preview: cancelled card confirmed';
  exception when others then if sqlerrm<>'LINE_TRANSPORT_PREVIEW_NOT_ACTIONABLE' then raise; end if; end;
  expired:=(public.server_tx_prepare_line_transport_assignment_v1(papa,gen_random_uuid(),dropoff,papa,1)->>'id')::uuid;
  update private.line_transport_assignment_previews set expires_at=clock_timestamp()-interval '1 second' where id=expired;
  begin
    perform public.server_tx_decide_line_transport_assignment_v1(papa,expired,'confirm_agreed');
    raise exception 'FAIL LINE preview: expired card confirmed';
  exception when others then if sqlerrm<>'LINE_TRANSPORT_PREVIEW_EXPIRED' then raise; end if; end;

  -- Even non-assignment edits invalidate the exact reviewed revision.
  preview:=(public.server_tx_prepare_line_transport_assignment_v1(papa,gen_random_uuid(),dropoff,papa,1)->>'id')::uuid;
  update public.task_instances set revision=revision+1 where id=dropoff;
  begin
    perform public.server_tx_decide_line_transport_assignment_v1(papa,preview,'confirm_agreed');
    raise exception 'FAIL LINE preview: stale revision accepted';
  exception when others then if sqlerrm<>'AGGREGATE_REVISION_CONFLICT' then raise; end if; end;
  if exists(select 1 from public.task_events where task_instance_id=dropoff) then
    raise exception 'FAIL LINE preview: stale reject left task event'; end if;
  -- A malformed snapshot cannot be made actionable by keeping the revision.
  update public.task_instances set due_at=due_at+interval '5 minutes' where id=dropoff;
  begin
    perform public.server_tx_decide_line_transport_assignment_v1(papa,preview,'confirm_agreed');
    raise exception 'FAIL LINE preview: changed due time accepted';
  exception when others then if sqlerrm<>'LINE_TRANSPORT_PREVIEW_STALE' then raise; end if; end;
  preview:=(public.server_tx_prepare_line_transport_assignment_v1(papa,gen_random_uuid(),dropoff,papa,2)->>'id')::uuid;
  update public.task_instances set status='cancelled' where id=dropoff;
  begin
    perform public.server_tx_decide_line_transport_assignment_v1(papa,preview,'confirm_agreed');
    raise exception 'FAIL LINE preview: terminal task accepted';
  exception when others then if sqlerrm<>'TASK_NOT_OPEN' then raise; end if; end;
  update public.task_instances set status='todo' where id=dropoff;

  -- Confirm is canonical source=line; dependent routines follow the actual owner.
  result:=public.server_tx_decide_line_transport_assignment_v1(papa,preview,'confirm_agreed');
  if result->>'status'<>'succeeded' or (result#>>'{result,revision}')::bigint<>3
    or (select planned_assignee_id from public.task_instances where id=dropoff)<>papa
    or (select assignment_source from public.task_instances where id=dropoff)<>'agreement'
    or (select planned_assignee_actor_ref_id from public.task_instances where id=prep)<>papa_ref
    or (select count(*) from public.requests where household_id=hh)<>requests_before
    or (select count(*) from public.task_instances where household_id=hh)<>tasks_before then
    raise exception 'FAIL LINE preview: confirm did not apply canonical assignment/reconciliation'; end if;
  if (select count(*) from public.task_events where task_instance_id=dropoff
    and event_type='assignment_agreed' and source='line' and actor_id=papa and actor_ref_id=papa_ref)<>1 then
    raise exception 'FAIL LINE preview: LINE canonical event missing or duplicated'; end if;
  update private.line_transport_assignment_previews set expires_at=clock_timestamp()-interval '1 second' where id=preview;
  -- Only status/result are expected to remain the same if a test changes expiry.
  snapshot:=public.server_tx_decide_line_transport_assignment_v1(papa,preview,'confirm_agreed');
  if snapshot->'result' is distinct from result->'result' or snapshot->>'status'<>'succeeded'
    or (select revision from public.task_instances where id=dropoff)<>3
    or (select count(*) from public.task_events where task_instance_id=dropoff and event_type='assignment_agreed')<>1 then
    raise exception 'FAIL LINE preview: successful replay duplicated command'; end if;
  begin
    perform public.server_tx_decide_line_transport_assignment_v1(mama,preview,'confirm_agreed');
    raise exception 'FAIL LINE preview: another actor replayed successful card';
  exception when others then if sqlerrm<>'LINE_TRANSPORT_PREVIEW_NOT_FOUND' then raise; end if; end;

  -- A transport-looking title alone never turns an ordinary task into transport.
  insert into public.task_instances(household_id,origin,title,category,task_kind,routine_phase,
    scheduled_date,planned_assignee_id,planned_assignee_actor_ref_id,completion_mode,status,source,
    created_by,assignment_mode)
  values(hh,'manual','明日の送り担当をパパに変更','housework','event','morning',chosen_date,
    mama,mama_ref,'whole','todo','test',papa,'person') returning id into ordinary;
  begin
    perform public.server_tx_prepare_line_transport_assignment_v1(papa,gen_random_uuid(),ordinary,papa,1);
    raise exception 'FAIL LINE preview: ordinary task title accepted';
  exception when others then if sqlerrm<>'LINE_TRANSPORT_PREVIEW_TASK_INVALID' then raise; end if; end;
  insert into public.test_simulation_contexts(household_id,operator_user_id) values(hh,papa) returning id into test_context;
  insert into public.task_instances(household_id,origin,title,category,routine_phase,
    scheduled_date,planned_assignee_id,planned_assignee_actor_ref_id,completion_mode,status,source,
    created_by,assignment_mode,test_context_id)
  values(hh,'manual','Simulation','housework','morning',chosen_date,
    mama,mama_ref,'whole','todo','test',papa,'person',test_context) returning id into ordinary;
  begin
    perform public.server_tx_prepare_line_transport_assignment_v1(papa,gen_random_uuid(),ordinary,papa,1);
    raise exception 'FAIL LINE preview: production preview reached simulation task';
  exception when others then if sqlerrm<>'LINE_TRANSPORT_PREVIEW_TASK_NOT_FOUND' then raise; end if; end;
end;
$$;
reset role;
do $$
declare sig text;
begin
  foreach sig in array array[
    'public.server_tx_prepare_line_transport_assignment_v1(uuid,uuid,uuid,uuid,bigint)',
    'public.server_read_line_transport_assignment_preview_v1(uuid)',
    'public.server_tx_decide_line_transport_assignment_v1(uuid,uuid,text)'
  ] loop
    if has_function_privilege('anon',sig,'execute') or has_function_privilege('authenticated',sig,'execute')
      or not has_function_privilege('service_role',sig,'execute')
      or (select prosecdef from pg_proc where oid=sig::regprocedure) then
      raise exception 'FAIL LINE preview: RPC not service-only invoker: %',sig; end if;
  end loop;
  if has_table_privilege('anon','private.line_transport_assignment_previews','select')
    or has_table_privilege('authenticated','private.line_transport_assignment_previews','select')
    or not (select relrowsecurity from pg_class where oid='private.line_transport_assignment_previews'::regclass)
    or exists(select 1 from pg_policies where schemaname='private' and tablename='line_transport_assignment_previews') then
    raise exception 'FAIL LINE preview: private table not locked down'; end if;
end;
$$;
rollback;
select 'line_transport_assignment_previews: PASS' as result;
