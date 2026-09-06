-- Issue #48 / Q59 independent re-review remediation.
--
-- After an immediate `all_done` reconciliation, the task is already terminal.
-- A later "例外を修正 -> 相手が対応" must therefore correct the canonical
-- actual performer instead of only changing the reconciliation outcome label.
-- Keep the ordinary Q64 individual path unchanged; this forward migration
-- intercepts only the exact bulk-correction intersection that was found by
-- independent review.

create or replace function public.server_tx_routine_session_item_action_v3(
  p_actor_id uuid,p_operation_id uuid,p_session_id uuid,p_task_instance_id uuid,p_action text,p_source text,
  p_rescheduled_to date default null,p_reconciliation_operation_id uuid default null
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_context jsonb; v_household_id uuid; v_actor_ref uuid; v_session public.routine_checkin_sessions%rowtype;
  v_task public.task_instances%rowtype; v_result jsonb; v_outcome text; v_unanswered int; v_hash text;
  v_receipt private.mutation_receipts%rowtype; v_correction boolean:=false; v_before_status text;
  v_bulk_snapshot public.routine_reconciliation_snapshots%rowtype;
  v_partner_user_id uuid; v_partner_actor_ref uuid; v_sub_op uuid; v_expected_after_revision bigint;
begin
  if p_action not in ('complete','partner_handled','skip','failed','cancelled','rescheduled','unknown')
     or p_source not in ('pwa','line') then raise exception 'INVALID_INPUT'; end if;
  if p_action='rescheduled' and p_rescheduled_to is null then raise exception 'RESCHEDULE_DATE_REQUIRED'; end if;
  if p_action<>'rescheduled' and p_rescheduled_to is not null then raise exception 'INVALID_INPUT'; end if;

  v_context:=private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id:=(v_context->>'household_id')::uuid;
  v_actor_ref:=(v_context->>'actor_ref_id')::uuid;

  -- Q59: exact intersection of bulk all_done and a later exception correction.
  -- Only `partner_handled` needs a terminal actual-performer rewrite: `complete`
  -- already agrees with the self performer written by all_done.
  if p_action='partner_handled' and p_reconciliation_operation_id is not null then
    select s.* into v_bulk_snapshot
    from public.routine_reconciliation_operations o
    join public.routine_reconciliation_snapshots s on s.operation_id=o.id
    where o.id=p_reconciliation_operation_id
      and o.household_id=v_household_id
      and o.actor_user_id=p_actor_id
      and o.session_id=p_session_id
      and o.status='applied'
      and o.response_kind='all_done'
      and s.task_instance_id=p_task_instance_id;

    if found then
      -- Own the user-visible correction operation before touching canonical
      -- actual truth. A replay returns the same result; a reused operation ID
      -- with a different payload fails closed.
      v_hash:=encode(sha256(convert_to(
        'routine-bulk-actual-correction-v4|'||p_session_id::text||'|'||p_task_instance_id::text||'|'||
        p_action||'|'||p_source||'|'||p_reconciliation_operation_id::text,'UTF8')),'hex');
      loop
        insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash)
          values(p_actor_id,p_operation_id,'routine-bulk-actual-correction-v4',v_hash)
          on conflict(actor_id,operation_id) do nothing;
        if found then exit; end if;
        select * into v_receipt from private.mutation_receipts
          where actor_id=p_actor_id and operation_id=p_operation_id for update;
        if v_receipt.request_hash<>v_hash
           or v_receipt.action_type<>'routine-bulk-actual-correction-v4' then
          raise exception 'IDEMPOTENCY_CONFLICT';
        end if;
        if v_receipt.result_payload is null then raise exception 'IDEMPOTENCY_INCOMPLETE'; end if;
        return v_receipt.result_payload;
      end loop;

      select * into v_session from public.routine_checkin_sessions
        where household_id=v_household_id and id=p_session_id for update;
      if not found or v_session.assignee_id<>p_actor_id then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
      if not exists(
        select 1 from public.routine_checkin_session_items
        where household_id=v_household_id and session_id=p_session_id
          and task_instance_id=p_task_instance_id
      ) then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;

      select * into v_task from public.task_instances
        where household_id=v_household_id and id=p_task_instance_id for update;
      if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;

      v_expected_after_revision:=nullif(v_bulk_snapshot.after_state->>'revision','')::bigint;
      if v_task.status<>coalesce(v_bulk_snapshot.after_state->>'status','')
         or v_task.revision<>coalesce(v_expected_after_revision,-1) then
        raise exception 'RECONCILIATION_CORRECTION_STALE';
      end if;
      if v_task.status<>'completed' then raise exception 'RECONCILIATION_CORRECTION_STALE'; end if;

      -- Resolve "partner" exactly like the canonical complete-task adapter.
      select user_id into v_partner_user_id
      from public.household_members
      where household_id=v_household_id and user_id<>p_actor_id
      order by joined_at,user_id
      limit 1;
      if v_partner_user_id is null then raise exception 'INVALID_INPUT'; end if;

      select id into v_partner_actor_ref
      from public.domain_actor_refs
      where household_id=v_household_id and actor_kind='real_user'
        and real_user_id=v_partner_user_id;
      if v_partner_actor_ref is null then raise exception 'TASK_PERFORMER_ACTOR_REF_NOT_FOUND'; end if;

      -- Reuse the canonical actual-correction command so the former self
      -- participant is retained as removed history, the partner becomes the
      -- sole active performer, compatibility projection stays aligned, and
      -- the task revision/audit trail advance atomically.
      v_sub_op:=(md5(p_operation_id::text||':actual-correction'))::uuid;
      perform private.fn_command_correct_task_actual_v1(
        v_household_id,p_actor_id,v_actor_ref,null,p_task_instance_id,
        array[v_partner_actor_ref]::uuid[],v_task.revision,v_sub_op,p_source
      );

      insert into public.routine_item_reconciliation_outcomes(
        household_id,session_id,task_instance_id,actor_user_id,outcome,rescheduled_to,source,operation_id
      ) values(
        v_household_id,p_session_id,p_task_instance_id,p_actor_id,'partner_handled',null,p_source,p_operation_id
      ) on conflict(session_id,task_instance_id) do update set
        outcome=excluded.outcome,rescheduled_to=null,source=excluded.source,
        operation_id=excluded.operation_id,answered_at=now();

      select * into v_task from public.task_instances
        where household_id=v_household_id and id=p_task_instance_id;
      v_result:=jsonb_build_object(
        'ok',true,'task_id',p_task_instance_id,'status',v_task.status,
        'action','partner_handled','reconciliation_outcome','partner_handled',
        'corrected_actual',true,'actual_completed_by_id',v_task.actual_completed_by_id,
        'revision',v_task.revision
      );
      update private.mutation_receipts set
        actor_ref_id=v_actor_ref,result_type='task_instance',result_id=p_task_instance_id,result_payload=v_result
      where actor_id=p_actor_id and operation_id=p_operation_id;
      return v_result;
    end if;
  end if;

  -- Existing Q64 behavior is intentionally preserved below.
  if p_action<>'unknown' then
    v_result:=public.server_tx_routine_session_item_action_v2(
      p_actor_id,p_operation_id,p_session_id,p_task_instance_id,p_action,p_source,
      p_rescheduled_to,p_reconciliation_operation_id
    );
  else
    v_hash:=encode(sha256(convert_to(
      'routine-item-v3-unknown|'||p_session_id::text||'|'||p_task_instance_id::text||'|'||p_source||'|'||
      coalesce(p_reconciliation_operation_id::text,''),'UTF8')),'hex');
    loop
      insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash)
        values(p_actor_id,p_operation_id,'routine-session-item-unknown-v3',v_hash)
        on conflict(actor_id,operation_id) do nothing;
      if found then exit; end if;
      select * into v_receipt from private.mutation_receipts
        where actor_id=p_actor_id and operation_id=p_operation_id for update;
      if v_receipt.request_hash<>v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
      if v_receipt.result_payload is null then raise exception 'IDEMPOTENCY_INCOMPLETE'; end if;
      return v_receipt.result_payload;
    end loop;
    select * into v_session from public.routine_checkin_sessions
      where household_id=v_household_id and id=p_session_id for update;
    if not found or v_session.assignee_id<>p_actor_id then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
    if not exists(
      select 1 from public.routine_checkin_session_items
      where household_id=v_household_id and session_id=p_session_id
        and task_instance_id=p_task_instance_id
    ) then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
    if p_reconciliation_operation_id is not null then
      select (s.before_state->>'status'),true into v_before_status,v_correction
      from public.routine_reconciliation_operations o
      join public.routine_reconciliation_snapshots s on s.operation_id=o.id
      where o.id=p_reconciliation_operation_id and o.household_id=v_household_id
        and o.actor_user_id=p_actor_id and o.session_id=p_session_id and o.status='applied'
        and s.task_instance_id=p_task_instance_id;
    end if;
    if v_session.status<>'open' and not v_correction then raise exception 'TASK_TERMINAL'; end if;
    select * into v_task from public.task_instances
      where household_id=v_household_id and id=p_task_instance_id for update;
    if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
    if v_correction then
      update public.task_actual_participants set
        removed_at=now(),removed_by_actor_ref_id=v_actor_ref
      where household_id=v_household_id and task_instance_id=p_task_instance_id and removed_at is null;
    end if;
    update public.task_instances set
      status=case when coalesce(carryover_policy,'occurrence_ends')='occurrence_ends' then 'skipped'
                  else case when v_correction then coalesce(v_before_status,'todo') else status end end,
      actual_completed_by_id=null,completed_at=null,outcome_reason='unknown',rescheduled_to=null,
      revision=revision+1
    where household_id=v_household_id and id=p_task_instance_id;
    insert into public.task_events(
      household_id,task_instance_id,actor_id,event_type,payload,source,idempotency_key
    ) values(
      v_household_id,p_task_instance_id,p_actor_id,'reconciled_unknown',
      jsonb_build_object('carryover_policy',v_task.carryover_policy),p_source,p_operation_id::text||':unknown'
    );
    v_result:=jsonb_build_object('ok',true,'task_id',p_task_instance_id,'action','unknown');
    update private.mutation_receipts set
      result_type='task_instance',result_id=p_task_instance_id,result_payload=v_result
    where actor_id=p_actor_id and operation_id=p_operation_id;
  end if;

  v_outcome:=case p_action
    when 'complete' then 'completed'
    when 'partner_handled' then 'partner_handled'
    when 'failed' then 'could_not_do'
    when 'skip' then 'not_needed'
    when 'cancelled' then 'cancelled'
    when 'rescheduled' then 'rescheduled'
    else 'unknown' end;
  insert into public.routine_item_reconciliation_outcomes(
    household_id,session_id,task_instance_id,actor_user_id,outcome,rescheduled_to,source,operation_id
  ) values(
    v_household_id,p_session_id,p_task_instance_id,p_actor_id,v_outcome,
    case when p_action='rescheduled' then p_rescheduled_to else null end,p_source,p_operation_id
  ) on conflict(session_id,task_instance_id) do update set
    outcome=excluded.outcome,rescheduled_to=excluded.rescheduled_to,source=excluded.source,
    operation_id=excluded.operation_id,answered_at=now();

  if not v_correction then
    select count(*) into v_unanswered
    from public.routine_checkin_session_items si
    join public.task_instances ti on ti.household_id=si.household_id and ti.id=si.task_instance_id
    where si.household_id=v_household_id and si.session_id=p_session_id
      and ti.status in ('todo','in_progress')
      and not exists(
        select 1 from public.routine_item_reconciliation_outcomes o
        where o.session_id=p_session_id and o.task_instance_id=si.task_instance_id
      );
    if v_unanswered=0 then
      update public.routine_checkin_sessions set status='submitted',submitted_at=coalesce(submitted_at,now())
      where household_id=v_household_id and id=p_session_id and status='open';
    end if;
  end if;
  return coalesce(v_result,'{}'::jsonb)||jsonb_build_object('reconciliation_outcome',v_outcome);
end; $$;

revoke all on function public.server_tx_routine_session_item_action_v3(uuid,uuid,uuid,uuid,text,text,date,uuid)
  from public,anon,authenticated;
grant execute on function public.server_tx_routine_session_item_action_v3(uuid,uuid,uuid,uuid,text,text,date,uuid)
  to service_role;
