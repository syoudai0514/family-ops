-- Preserve the exact pre-completion state while the task row is locked. A
-- checklist's whole-task completion changes only its previously-unchecked
-- required items; undo must not touch earlier work by either parent.
create table private.checklist_completion_snapshots (
  household_id uuid not null,
  task_id uuid not null,
  completed_revision bigint not null,
  operator_id uuid not null,
  operation_id uuid not null,
  changed_subtasks uuid[] not null,
  previous_state jsonb not null,
  previous_participants jsonb not null,
  request_before jsonb,
  request_after jsonb,
  created_at timestamptz not null default now(),
  primary key (household_id,task_id,completed_revision),
  unique (operator_id,operation_id),
  foreign key (household_id,task_id) references public.task_instances(household_id,id) on delete cascade,
  foreign key (household_id,operator_id) references public.household_members(household_id,user_id) on delete cascade
);
alter table private.checklist_completion_snapshots enable row level security;
revoke all on private.checklist_completion_snapshots from public,anon,authenticated;
grant select,insert on private.checklist_completion_snapshots to service_role;

create function public.server_tx_complete_task_with_checklist_undo_v1(
  p_actor_id uuid,p_operation_id uuid,p_task_id uuid,p_completion_actor text,
  p_complete_remaining_subtasks boolean,p_source text default 'pwa'
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  ctx jsonb; hh uuid; actor_ref uuid; t public.task_instances%rowtype; r public.requests%rowtype;
  mode text; claim jsonb; receipt uuid;
  changed uuid[]; participants jsonb; req_before jsonb; req_after jsonb; result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_task_id is null or p_completion_actor is null
    or p_completion_actor not in ('self','partner') or p_source is null or p_source not in ('pwa','line') then
    raise exception 'INVALID_INPUT';
  end if;
  ctx:=private.fn_require_production_actor_context_v1(p_actor_id);
  hh:=(ctx->>'household_id')::uuid; actor_ref:=(ctx->>'actor_ref_id')::uuid;
  select completion_mode into mode from public.task_instances where household_id=hh and id=p_task_id and test_context_id is null;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if mode<>'subtasks' then
    return public.server_tx_complete_task(p_actor_id,p_operation_id,p_task_id,p_completion_actor,p_complete_remaining_subtasks,p_source);
  end if;
  claim:=private.fn_claim_canonical_operation_v1(hh,p_actor_id,actor_ref,null,p_operation_id,'checklist.complete',
    private.fn_canonical_request_hash_v1(jsonb_build_object('task_id',p_task_id,'completion_actor',p_completion_actor,
      'complete_remaining_subtasks',p_complete_remaining_subtasks,'source',p_source)));
  if claim->>'disposition'='replay' then return claim->'result_payload'; end if;
  receipt:=(claim->>'receipt_id')::uuid;
  select * into t from public.task_instances where household_id=hh and id=p_task_id and test_context_id is null for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if t.completion_mode<>'subtasks' then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  perform 1 from public.task_subtask_instances where household_id=hh and task_instance_id=p_task_id order by id for update;
  select coalesce(array_agg(id order by id),'{}'::uuid[]) into changed from public.task_subtask_instances
    where household_id=hh and task_instance_id=p_task_id and required and not is_completed;
  select coalesce(jsonb_agg(jsonb_build_object('id',id,'compatibility_primary',compatibility_primary) order by id),'[]'::jsonb)
    into participants from public.task_actual_participants where household_id=hh and task_instance_id=p_task_id and removed_at is null;
  select * into r from public.requests where household_id=hh and linked_task_instance_id=p_task_id for update;
  if found then req_before:=jsonb_build_object('id',r.id,'status',r.status,'updated_at',r.updated_at); end if;
  result:=public.server_tx_complete_task(p_actor_id,pg_catalog.md5(p_operation_id::text||':checklist-complete')::uuid,
    p_task_id,p_completion_actor,p_complete_remaining_subtasks,p_source);
  result:=result||jsonb_build_object('checklist_undo_available',true);
  select * into r from public.requests where household_id=hh and linked_task_instance_id=p_task_id;
  if found then req_after:=jsonb_build_object('id',r.id,'status',r.status,'updated_at',r.updated_at); end if;
  insert into private.checklist_completion_snapshots(household_id,task_id,completed_revision,operator_id,operation_id,
    changed_subtasks,previous_state,previous_participants,request_before,request_after)
  values(hh,p_task_id,(result->>'revision')::bigint,p_actor_id,p_operation_id,changed,
    jsonb_build_object('status',t.status,'completed_at',t.completed_at,'actual_completed_by_id',t.actual_completed_by_id,
      'attention_state',t.attention_state,'waiting_note',t.waiting_note,'next_check_at',t.next_check_at,
      'active_claimant_actor_ref_id',t.active_claimant_actor_ref_id,'claimed_at',t.claimed_at,'outcome_reason',t.outcome_reason),
    participants,req_before,req_after);
  perform private.fn_complete_canonical_operation_v1(receipt,'task_instance',p_task_id,result);
  return result;
end $$;
revoke all on function public.server_tx_complete_task_with_checklist_undo_v1(uuid,uuid,uuid,text,boolean,text) from public,anon,authenticated;
grant execute on function public.server_tx_complete_task_with_checklist_undo_v1(uuid,uuid,uuid,text,boolean,text) to service_role;

create function public.server_tx_reopen_task_with_checklist_undo_v1(
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
  if mode<>'subtasks' then
    return public.server_tx_reopen_task(p_actor_id,p_operation_id,p_task_id,p_expected_revision,p_source);
  end if;
  claim:=private.fn_claim_canonical_operation_v1(hh,p_actor_id,actor_ref,null,p_operation_id,'checklist.undo',
    private.fn_canonical_request_hash_v1(jsonb_build_object('task_id',p_task_id,'revision',p_expected_revision,'source',p_source)));
  if claim->>'disposition'='replay' then return claim->'result_payload'; end if;
  receipt:=(claim->>'receipt_id')::uuid;
  select * into t from public.task_instances where household_id=hh and id=p_task_id and test_context_id is null for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if t.completion_mode<>'subtasks' then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
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
