-- Batch snapshots also preserve whole tasks; old whole-task undo remains compatible.
create or replace function public.server_tx_reopen_task_with_checklist_undo_v1(
  p_actor_id uuid,p_operation_id uuid,p_task_id uuid,p_expected_revision bigint,p_source text default 'pwa'
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  ctx jsonb; hh uuid; actor_ref uuid; mode text; t public.task_instances%rowtype; snap private.checklist_completion_snapshots%rowtype;
  req public.requests%rowtype; claim jsonb; receipt uuid; sub_id uuid; child_op uuid; current_revision bigint; sub_result jsonb;
  member jsonb; result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_task_id is null or p_expected_revision is null
    or p_expected_revision<1 or p_source is null or p_source not in ('pwa','line') then raise exception 'INVALID_INPUT'; end if;
  ctx:=private.fn_require_production_actor_context_v1(p_actor_id);
  hh:=(ctx->>'household_id')::uuid; actor_ref:=(ctx->>'actor_ref_id')::uuid;
  select completion_mode into mode from public.task_instances where household_id=hh and id=p_task_id and test_context_id is null;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  -- A batch may have captured a whole task as well; older whole-task
  -- completions without a snapshot keep the established reopen behavior.
  if mode<>'subtasks' and not exists(select 1 from private.checklist_completion_snapshots
    where household_id=hh and task_id=p_task_id and completed_revision=p_expected_revision) then
    return public.server_tx_reopen_task(p_actor_id,p_operation_id,p_task_id,p_expected_revision,p_source);
  end if;
  claim:=private.fn_claim_canonical_operation_v1(hh,p_actor_id,actor_ref,null,p_operation_id,'checklist.undo',
    private.fn_canonical_request_hash_v1(jsonb_build_object('task_id',p_task_id,'revision',p_expected_revision,'source',p_source)));
  if claim->>'disposition'='replay' then return claim->'result_payload'; end if;
  receipt:=(claim->>'receipt_id')::uuid;
  select * into t from public.task_instances where household_id=hh and id=p_task_id and test_context_id is null for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if t.completion_mode is distinct from mode then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  if t.revision<>p_expected_revision then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  if t.status<>'completed' then raise exception 'TASK_NOT_COMPLETED'; end if;
  select * into snap from private.checklist_completion_snapshots
    where household_id=hh and task_id=p_task_id and completed_revision=p_expected_revision;
  if not found then raise exception 'TASK_REOPEN_USE_SUBTASKS'; end if;
  -- A linked request could have been changed separately from the task. Refuse
  -- the entire undo rather than rolling back a newer request state.
  select * into req from public.requests where household_id=hh and linked_task_instance_id=p_task_id for update;
  if (req.id is null) is distinct from (snap.request_after is null)
    or (req.id is not null and (req.id::text is distinct from snap.request_after->>'id'
      or req.status is distinct from snap.request_after->>'status'
      or req.updated_at is distinct from (snap.request_after->>'updated_at')::timestamptz)) then
    raise exception 'AGGREGATE_REVISION_CONFLICT';
  end if;
  perform 1 from public.task_subtask_instances where household_id=hh and task_instance_id=p_task_id order by id for update;
  if (select count(*) from public.task_subtask_instances where household_id=hh and task_instance_id=p_task_id
      and id=any(snap.changed_subtasks) and required and is_completed)<>cardinality(snap.changed_subtasks) then
    raise exception 'AGGREGATE_REVISION_CONFLICT';
  end if;
  current_revision:=t.revision;
  foreach sub_id in array snap.changed_subtasks loop
    child_op:=pg_catalog.md5(p_operation_id::text||':checklist-undo:'||sub_id::text)::uuid;
    sub_result:=public.server_tx_set_subtask_completion(p_actor_id,child_op,sub_id,false,'self',current_revision);
    -- The legacy subtask helper records pwa unconditionally. Correct only
    -- this transaction's new event when the undo originated from LINE.
    if p_source='line' then
      update public.task_events set source='line' where household_id=hh and task_instance_id=p_task_id
        and actor_id=p_actor_id and idempotency_key=child_op::text||':subtask';
    end if;
    current_revision:=(sub_result->>'revision')::bigint;
  end loop;
  update public.task_actual_participants set removed_at=now(),removed_by_actor_ref_id=actor_ref,compatibility_primary=false
    where household_id=hh and task_instance_id=p_task_id and removed_at is null;
  update public.task_instances set status=snap.previous_state->>'status',
    completed_at=(snap.previous_state->>'completed_at')::timestamptz,
    actual_completed_by_id=(snap.previous_state->>'actual_completed_by_id')::uuid,
    attention_state=snap.previous_state->>'attention_state',waiting_note=snap.previous_state->>'waiting_note',
    next_check_at=(snap.previous_state->>'next_check_at')::timestamptz,
    active_claimant_actor_ref_id=(snap.previous_state->>'active_claimant_actor_ref_id')::uuid,
    claimed_at=(snap.previous_state->>'claimed_at')::timestamptz,outcome_reason=snap.previous_state->>'outcome_reason',
    revision=revision+1 where household_id=hh and id=p_task_id returning revision into current_revision;
  for member in select value from jsonb_array_elements(snap.previous_participants) loop
    update public.task_actual_participants set removed_at=null,removed_by_actor_ref_id=null,
      compatibility_primary=(member->>'compatibility_primary')::boolean
    where household_id=hh and task_instance_id=p_task_id and id=(member->>'id')::uuid;
    if not found then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  end loop;
  if snap.request_before->>'status'='accepted' and snap.request_after->>'status'='completed' then
    update public.requests set status='accepted',completed_at=null where household_id=hh and id=req.id;
  end if;
  insert into public.task_events(household_id,task_instance_id,actor_id,actor_ref_id,test_context_id,event_type,payload,source,idempotency_key)
  values(hh,p_task_id,p_actor_id,actor_ref,null,'completion_reverted',
    jsonb_build_object('reason','mistap_or_correction','previous_revision',p_expected_revision,'revision',current_revision),
    p_source,p_operation_id::text||':completion-reverted');
  result:=jsonb_build_object('ok',true,'task_id',p_task_id,'status',snap.previous_state->>'status','revision',current_revision);
  perform private.fn_complete_canonical_operation_v1(receipt,'task_instance',p_task_id,result);
  return result;
end $$;
revoke all on function public.server_tx_reopen_task_with_checklist_undo_v1(uuid,uuid,uuid,bigint,text) from public,anon,authenticated;
grant execute on function public.server_tx_reopen_task_with_checklist_undo_v1(uuid,uuid,uuid,bigint,text) to service_role;

-- A brief is the authority for what the sender saw, including each revision.
-- The opaque batch id is not a bearer credential: every command checks actor,
-- household, date, original notification, current assignment and revisions.
create table private.line_bulk_batches (
  id uuid primary key default gen_random_uuid(),
  household_id uuid not null,
  actor_id uuid not null,
  notification_id uuid not null unique references public.user_notifications(id) on delete cascade,
  local_date date not null,
  phase text not null check (phase in ('morning','evening')),
  items jsonb not null check (jsonb_typeof(items)='array'),
  completed_items jsonb,
  status text not null default 'ready' check (status in ('ready','completed','undone')),
  created_at timestamptz not null default now(),
  completed_at timestamptz,
  foreign key (household_id,actor_id) references public.household_members(household_id,user_id) on delete cascade
);
alter table private.line_bulk_batches enable row level security;
revoke all on private.line_bulk_batches from public,anon,authenticated;
grant select,insert,update on private.line_bulk_batches to service_role;

create function public.server_tx_prepare_line_bulk_v1(p_actor_id uuid,p_notification_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  ctx jsonb; hh uuid; n public.user_notifications%rowtype; phase text; local_day date;
  raw_date text; candidate jsonb; task_row public.task_instances%rowtype; actor_ref uuid;
  items jsonb:='[]'::jsonb; existing private.line_bulk_batches%rowtype; result_id uuid;
begin
  if p_actor_id is null or p_notification_id is null then raise exception 'INVALID_INPUT'; end if;
  ctx:=private.fn_require_production_actor_context_v1(p_actor_id);
  hh:=(ctx->>'household_id')::uuid; actor_ref:=(ctx->>'actor_ref_id')::uuid;
  select * into n from public.user_notifications where id=p_notification_id and household_id=hh
    and recipient_user_id=p_actor_id and type='daily_brief.v2' and test_context_id is null;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  phase:=case n.title when '朝のおうちノート' then 'morning' when '夜のおうちノート' then 'evening' else null end;
  raw_date:=n.payload#>>'{brief,local_date}';
  if phase is null or raw_date is null or raw_date !~ '^\d{4}-\d{2}-\d{2}$' then return null; end if;
  begin local_day:=raw_date::date; exception when invalid_datetime_format or datetime_field_overflow then return null; end;
  if local_day<>(now() at time zone 'Asia/Tokyo')::date then return null; end if;
  select * into existing from private.line_bulk_batches where notification_id=p_notification_id;
  if found then return jsonb_build_object('id',existing.id,'phase',existing.phase,'local_date',existing.local_date,'status',existing.status); end if;
  if jsonb_typeof(n.payload#>array['brief','own_task_groups',phase]) is distinct from 'array' then return null; end if;
  for candidate in select value from jsonb_array_elements(n.payload#>array['brief','own_task_groups',phase]) loop
    continue when candidate->>'expectation'='optional';
    continue when not (coalesce(candidate->>'planned_assignee_id','')=p_actor_id::text
      and coalesce(candidate->>'assignment_mode','person')<>'anyone')
      and not (candidate->>'assignment_mode'='anyone' and candidate->>'active_claimant_user_id'=p_actor_id::text);
    if coalesce(candidate->>'status','') not in ('todo','in_progress') then return null; end if;
    if coalesce(candidate->>'task_id','') !~* '^[0-9a-f]{8}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{4}-[0-9a-f]{12}$'
      or coalesce(candidate->>'revision','') !~ '^[1-9][0-9]{0,15}$' then return null; end if;
    select * into task_row from public.task_instances where household_id=hh and id=(candidate->>'task_id')::uuid and test_context_id is null;
    if not found or task_row.scheduled_date<>local_day or task_row.routine_phase<>phase
      or task_row.revision<>(candidate->>'revision')::bigint or task_row.status not in ('todo','in_progress')
      or coalesce(task_row.expectation,'normal')='optional'
      or not ((task_row.assignment_mode is distinct from 'anyone' and task_row.planned_assignee_id=p_actor_id)
        or (task_row.assignment_mode='anyone' and task_row.active_claimant_actor_ref_id=actor_ref)) then return null; end if;
    -- Saying "all done" does not assert that Codmon was actually submitted.
    continue when exists(select 1 from public.task_definitions d where d.household_id=hh
      and d.id=task_row.task_definition_id and d.code='codmon_submit');
    items:=items||jsonb_build_array(jsonb_build_object('id',task_row.id,'revision',task_row.revision));
  end loop;
  if jsonb_array_length(items)=0 or jsonb_array_length(items)>80 then return null; end if;
  -- Duplicate items would make the same task complete twice; fail closed.
  if (select count(distinct x->>'id') from jsonb_array_elements(items) x)<>jsonb_array_length(items) then return null; end if;
  insert into private.line_bulk_batches(household_id,actor_id,notification_id,local_date,phase,items)
  values(hh,p_actor_id,p_notification_id,local_day,phase,items)
  on conflict(notification_id) do nothing returning id into result_id;
  if result_id is null then select id into result_id from private.line_bulk_batches where notification_id=p_notification_id and actor_id=p_actor_id; end if;
  return jsonb_build_object('id',result_id,'phase',phase,'local_date',local_day,'status','ready');
end $$;
revoke all on function public.server_tx_prepare_line_bulk_v1(uuid,uuid) from public,anon,authenticated;
grant execute on function public.server_tx_prepare_line_bulk_v1(uuid,uuid) to service_role;

-- Save whole-task pre-state using the same protected snapshot format as the
-- checklist command. Internal only; the batch has already checked every item.
create function private.fn_line_bulk_complete_one_v1(p_actor uuid,p_operation uuid,p_task uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  ctx jsonb; hh uuid; t public.task_instances%rowtype; r public.requests%rowtype;
  participants jsonb; req_before jsonb; req_after jsonb; result jsonb;
begin
  ctx:=private.fn_require_production_actor_context_v1(p_actor); hh:=(ctx->>'household_id')::uuid;
  select * into t from public.task_instances where household_id=hh and id=p_task and test_context_id is null for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if t.completion_mode='subtasks' then
    return public.server_tx_complete_task_with_checklist_undo_v1(p_actor,p_operation,p_task,'self',true,'line');
  end if;
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'compatibility_primary',compatibility_primary) order by id),'[]'::jsonb)
    into participants from public.task_actual_participants where household_id=hh and task_instance_id=p_task and removed_at is null;
  select * into r from public.requests where household_id=hh and linked_task_instance_id=p_task for update;
  if found then req_before:=jsonb_build_object('id',r.id,'status',r.status,'updated_at',r.updated_at); end if;
  result:=public.server_tx_complete_task(p_actor,p_operation,p_task,'self',false,'line');
  select * into r from public.requests where household_id=hh and linked_task_instance_id=p_task;
  if found then req_after:=jsonb_build_object('id',r.id,'status',r.status,'updated_at',r.updated_at); end if;
  insert into private.checklist_completion_snapshots(household_id,task_id,completed_revision,operator_id,operation_id,
    changed_subtasks,previous_state,previous_participants,request_before,request_after)
  values(hh,p_task,(result->>'revision')::bigint,p_actor,p_operation,'{}'::uuid[],
    jsonb_build_object('status',t.status,'completed_at',t.completed_at,'actual_completed_by_id',t.actual_completed_by_id,
      'attention_state',t.attention_state,'waiting_note',t.waiting_note,'next_check_at',t.next_check_at,
      'active_claimant_actor_ref_id',t.active_claimant_actor_ref_id,'claimed_at',t.claimed_at,'outcome_reason',t.outcome_reason),
    participants,req_before,req_after);
  return result;
end $$;
revoke all on function private.fn_line_bulk_complete_one_v1(uuid,uuid,uuid) from public,anon,authenticated,service_role;

create function public.server_tx_complete_line_bulk_v1(p_actor_id uuid,p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  ctx jsonb; hh uuid; actor_ref uuid; b private.line_bulk_batches%rowtype;
  x jsonb; t public.task_instances%rowtype; result jsonb; completed jsonb:='[]'::jsonb;
begin
  if p_actor_id is null or p_batch_id is null then raise exception 'INVALID_INPUT'; end if;
  ctx:=private.fn_require_production_actor_context_v1(p_actor_id);
  hh:=(ctx->>'household_id')::uuid; actor_ref:=(ctx->>'actor_ref_id')::uuid;
  select * into b from private.line_bulk_batches where id=p_batch_id and household_id=hh and actor_id=p_actor_id for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if b.status='completed' then return jsonb_build_object('ok',true,'already_completed',true); end if;
  if b.status='undone' then return jsonb_build_object('ok',false,'already_undone',true); end if;
  if b.local_date<>(now() at time zone 'Asia/Tokyo')::date then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  -- Lock all items in a stable order before doing any work. A change in any
  -- one item rejects the whole action instead of silently recording new work.
  for x in select value from jsonb_array_elements(b.items) order by value->>'id' loop
    select * into t from public.task_instances where household_id=hh and id=(x->>'id')::uuid and test_context_id is null for update;
    if not found or t.revision<>(x->>'revision')::bigint or t.scheduled_date<>b.local_date
      or t.routine_phase<>b.phase or t.status not in ('todo','in_progress')
      or coalesce(t.expectation,'normal')='optional'
      or not ((t.assignment_mode is distinct from 'anyone' and t.planned_assignee_id=p_actor_id)
        or (t.assignment_mode='anyone' and t.active_claimant_actor_ref_id=actor_ref)) then
      raise exception 'AGGREGATE_REVISION_CONFLICT';
    end if;
  end loop;
  for x in select value from jsonb_array_elements(b.items) order by value->>'id' loop
    result:=private.fn_line_bulk_complete_one_v1(p_actor_id,
      pg_catalog.md5(b.id::text||':complete:'||(x->>'id'))::uuid,(x->>'id')::uuid);
    completed:=completed||jsonb_build_array(jsonb_build_object('id',x->>'id','revision',(result->>'revision')::bigint));
  end loop;
  update private.line_bulk_batches set status='completed',completed_items=completed,completed_at=now() where id=b.id;
  return jsonb_build_object('ok',true);
end $$;
revoke all on function public.server_tx_complete_line_bulk_v1(uuid,uuid) from public,anon,authenticated;
grant execute on function public.server_tx_complete_line_bulk_v1(uuid,uuid) to service_role;

create function public.server_tx_undo_line_bulk_v1(p_actor_id uuid,p_batch_id uuid)
returns jsonb language plpgsql security definer set search_path='' as $$
declare
  ctx jsonb; hh uuid; b private.line_bulk_batches%rowtype; x jsonb; t public.task_instances%rowtype;
begin
  if p_actor_id is null or p_batch_id is null then raise exception 'INVALID_INPUT'; end if;
  ctx:=private.fn_require_production_actor_context_v1(p_actor_id); hh:=(ctx->>'household_id')::uuid;
  select * into b from private.line_bulk_batches where id=p_batch_id and household_id=hh and actor_id=p_actor_id for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if b.status='undone' then return jsonb_build_object('ok',true,'already_undone',true); end if;
  if b.status<>'completed' or b.completed_at is null or b.completed_at<now()-interval '24 hours' then
    raise exception 'AGGREGATE_REVISION_CONFLICT';
  end if;
  for x in select value from jsonb_array_elements(b.completed_items) order by value->>'id' loop
    select * into t from public.task_instances where household_id=hh and id=(x->>'id')::uuid and test_context_id is null for update;
    if not found or t.revision<>(x->>'revision')::bigint or t.status<>'completed' then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  end loop;
  for x in select value from jsonb_array_elements(b.completed_items) order by value->>'id' loop
    perform public.server_tx_reopen_task_with_checklist_undo_v1(p_actor_id,
      pg_catalog.md5(b.id::text||':undo:'||(x->>'id'))::uuid,(x->>'id')::uuid,(x->>'revision')::bigint,'line');
  end loop;
  update private.line_bulk_batches set status='undone' where id=b.id;
  return jsonb_build_object('ok',true);
end $$;
revoke all on function public.server_tx_undo_line_bulk_v1(uuid,uuid) from public,anon,authenticated;
grant execute on function public.server_tx_undo_line_bulk_v1(uuid,uuid) to service_role;
