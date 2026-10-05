-- "できなかった" from Today and LINE, kept apart from 未記録 (owner 2026-10-05:
-- "今日詩乃の薬あげるの忘れちゃった。未記録と区別しておいた方がいい").
--
-- The outcome already exists (status 'skipped', outcome_reason 'could_not_do', shown
-- as できなかった in History and Check-in), but only the routine check-in session could
-- record it. This is the same outcome for one task, outside a session, with its undo:
-- a forgotten task is no longer an open todo (no more reminders, not 未記録), and a
-- mistaken tap goes back to todo. A completed or cancelled task is left alone.

create or replace function public.server_tx_mark_task_could_not_do_v1(
  p_actor_id uuid,
  p_operation_id uuid,
  p_task_id uuid,
  p_undo boolean default false,
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
  v_actor_ref uuid;
  v_task public.task_instances%rowtype;
  v_new_revision bigint;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_task_id is null or p_undo is null
     or p_source not in ('pwa','line') then
    raise exception 'INVALID_INPUT';
  end if;

  v_context:=private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id:=(v_context->>'household_id')::uuid;
  v_actor_ref:=(v_context->>'actor_ref_id')::uuid;

  v_request_hash:=encode(sha256(convert_to(
    'task-could-not-do|'||p_task_id::text||'|'||p_undo::text||'|'||p_source,'UTF8')),'hex');
  loop
    insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash,actor_ref_id)
      values(p_actor_id,p_operation_id,'task-could-not-do',v_request_hash,v_actor_ref)
      on conflict(actor_id,operation_id) do nothing;
    if found then exit; end if;
    select * into v_receipt from private.mutation_receipts
      where actor_id=p_actor_id and operation_id=p_operation_id for update;
    if found then
      if v_receipt.action_type<>'task-could-not-do' or v_receipt.request_hash<>v_request_hash then
        raise exception 'IDEMPOTENCY_CONFLICT';
      end if;
      if v_receipt.result_payload is null then raise exception 'IDEMPOTENCY_INCOMPLETE'; end if;
      return v_receipt.result_payload;
    end if;
  end loop;

  select * into v_task from public.task_instances
  where household_id=v_household_id and id=p_task_id and test_context_id is null
  for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;

  if not p_undo then
    if v_task.status not in ('todo','in_progress') then raise exception 'TASK_TERMINAL'; end if;
    update public.task_instances set
      status='skipped',outcome_reason='could_not_do',rescheduled_to=null,
      completed_at=null,actual_completed_by_id=null,
      attention_state='active',waiting_note=null,next_check_at=null,
      active_claimant_actor_ref_id=null,claimed_at=null,
      revision=revision+1
    where household_id=v_household_id and id=p_task_id
    returning revision into v_new_revision;
    insert into public.task_events(
      household_id,task_instance_id,actor_id,actor_ref_id,event_type,payload,source,idempotency_key
    ) values(
      v_household_id,p_task_id,p_actor_id,v_actor_ref,'skipped',
      jsonb_build_object('outcome_reason','could_not_do','previous_status',v_task.status),
      p_source,p_operation_id::text||':could-not-do'
    );
    v_result:=jsonb_build_object('ok',true,'task_id',p_task_id,'status','skipped',
      'outcome_reason','could_not_do','revision',v_new_revision,'title',v_task.title);
  else
    if v_task.status<>'skipped' or v_task.outcome_reason is distinct from 'could_not_do' then
      raise exception 'TASK_NOT_COULD_NOT_DO';
    end if;
    update public.task_instances set
      status='todo',outcome_reason=null,revision=revision+1
    where household_id=v_household_id and id=p_task_id
    returning revision into v_new_revision;
    insert into public.task_events(
      household_id,task_instance_id,actor_id,actor_ref_id,event_type,payload,source,idempotency_key
    ) values(
      v_household_id,p_task_id,p_actor_id,v_actor_ref,'could_not_do_reverted',
      jsonb_build_object('reason','mistap_or_correction'),
      p_source,p_operation_id::text||':could-not-do-reverted'
    );
    v_result:=jsonb_build_object('ok',true,'task_id',p_task_id,'status','todo',
      'revision',v_new_revision,'title',v_task.title);
  end if;

  update private.mutation_receipts set
    result_type='task_instance',result_id=p_task_id,result_payload=v_result
  where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end;
$$;

revoke all on function public.server_tx_mark_task_could_not_do_v1(uuid,uuid,uuid,boolean,text)
  from public,anon,authenticated;
grant execute on function public.server_tx_mark_task_could_not_do_v1(uuid,uuid,uuid,boolean,text)
  to service_role;
