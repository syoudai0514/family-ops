-- Direct actual recording for "anyone" tasks is intentionally a UI/product
-- policy: canonical completion RPCs already record the actual performer and do
-- not require an anyone-claim. This migration adds the missing safe inverse for
-- whole-task completion so accidental taps can be corrected without deleting
-- audit history.

create or replace function public.server_tx_reopen_task(
  p_actor_id uuid,
  p_operation_id uuid,
  p_task_id uuid,
  p_expected_revision bigint,
  p_source text default 'pwa'
)
returns jsonb
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_request_hash text;
  v_receipt private.mutation_receipts%rowtype;
  v_context jsonb;
  v_household_id uuid;
  v_operator_actor_ref uuid;
  v_task public.task_instances%rowtype;
  v_new_revision bigint;
  v_result jsonb;
begin
  if p_actor_id is null
     or p_operation_id is null
     or p_task_id is null
     or p_expected_revision is null
     or p_expected_revision < 1
     or p_source not in ('pwa','line') then
    raise exception 'INVALID_INPUT';
  end if;

  v_context:=private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id:=(v_context->>'household_id')::uuid;
  v_operator_actor_ref:=(v_context->>'actor_ref_id')::uuid;

  v_request_hash:=encode(sha256(convert_to(
    'reopen-task|'||p_task_id::text||'|'||p_expected_revision::text||'|'||p_source,
    'UTF8'
  )),'hex');

  loop
    insert into private.mutation_receipts(
      actor_id,operation_id,action_type,request_hash,actor_ref_id
    ) values(
      p_actor_id,p_operation_id,'reopen-task',v_request_hash,v_operator_actor_ref
    )
    on conflict(actor_id,operation_id) do nothing;
    if found then exit; end if;

    select * into v_receipt
    from private.mutation_receipts
    where actor_id=p_actor_id and operation_id=p_operation_id
    for update;

    if found then
      if v_receipt.action_type<>'reopen-task'
         or v_receipt.request_hash<>v_request_hash then
        raise exception 'IDEMPOTENCY_CONFLICT';
      end if;
      if v_receipt.result_payload is null then
        raise exception 'IDEMPOTENCY_INCOMPLETE';
      end if;
      return v_receipt.result_payload;
    end if;
  end loop;

  select * into v_task
  from public.task_instances
  where household_id=v_household_id
    and id=p_task_id
    and test_context_id is null
  for update;

  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if v_task.revision<>p_expected_revision then
    raise exception 'AGGREGATE_REVISION_CONFLICT';
  end if;
  if v_task.status<>'completed' then
    raise exception 'TASK_NOT_COMPLETED';
  end if;

  -- Checklist tasks already have a safer fine-grained inverse:
  -- uncheck the mistaken subtask. Do not erase all checklist progress.
  if v_task.completion_mode<>'whole' then
    raise exception 'TASK_REOPEN_USE_SUBTASKS';
  end if;

  update public.task_actual_participants
  set removed_at=now(),
      removed_by_actor_ref_id=v_operator_actor_ref
  where household_id=v_household_id
    and task_instance_id=p_task_id
    and removed_at is null;

  update public.task_instances
  set status='todo',
      completed_at=null,
      actual_completed_by_id=null,
      attention_state='active',
      waiting_note=null,
      next_check_at=null,
      outcome_reason=null,
      active_claimant_actor_ref_id=null,
      claimed_at=null,
      revision=revision+1
  where household_id=v_household_id and id=p_task_id
  returning revision into v_new_revision;

  -- Completing an accepted request completes its linked task/request together.
  -- A same-day accidental completion correction returns that request to the
  -- accepted state rather than silently leaving the lifecycle terminal.
  update public.requests
  set status='accepted',
      completed_at=null
  where household_id=v_household_id
    and linked_task_instance_id=p_task_id
    and status='completed';

  insert into public.task_events(
    household_id,task_instance_id,actor_id,actor_ref_id,test_context_id,
    event_type,payload,source,idempotency_key
  ) values(
    v_household_id,p_task_id,p_actor_id,v_operator_actor_ref,null,
    'completion_reverted',
    jsonb_build_object(
      'reason','mistap_or_correction',
      'previous_revision',v_task.revision,
      'revision',v_new_revision
    ),
    p_source,p_operation_id::text||':completion-reverted'
  );

  v_result:=jsonb_build_object(
    'ok',true,
    'task_id',p_task_id,
    'status','todo',
    'revision',v_new_revision
  );

  update private.mutation_receipts
  set result_type='task_instance',
      result_id=p_task_id,
      result_payload=v_result
  where actor_id=p_actor_id and operation_id=p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_reopen_task(uuid,uuid,uuid,bigint,text)
  from public,anon,authenticated;
grant execute on function public.server_tx_reopen_task(uuid,uuid,uuid,bigint,text)
  to service_role;
