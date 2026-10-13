-- A new acknowledgement is valid only while the note is current and for
-- somebody other than its author. A successful canonical receipt still
-- replays after expiry; that replay records no new acknowledgement.
create or replace function private.fn_command_ack_info_v1(
  p_household_id uuid,p_operator_user_id uuid,p_actor_ref_id uuid,
  p_test_context_id uuid,p_handover_id uuid,p_operation_id uuid
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_claim jsonb;
  v_receipt_id uuid;
  v_info public.handovers%rowtype;
  v_actor_user_id uuid;
  v_now timestamptz;
  v_result jsonb;
begin
  v_claim:=private.fn_claim_canonical_operation_v1(
    p_household_id,p_operator_user_id,p_actor_ref_id,p_test_context_id,
    p_operation_id,'info.ack',
    private.fn_canonical_request_hash_v1(jsonb_build_object('handover_id',p_handover_id))
  );
  if v_claim->>'disposition'='replay' then return v_claim->'result_payload'; end if;
  v_receipt_id:=(v_claim->>'receipt_id')::uuid;
  select * into v_info from public.handovers
  where household_id=p_household_id and id=p_handover_id for share;
  if not found then raise exception 'INFO_NOT_FOUND'; end if;
  if v_info.test_context_id is distinct from p_test_context_id then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
  v_now:=clock_timestamp();
  v_actor_user_id:=private.fn_legacy_user_for_actor_ref_v1(p_household_id,p_actor_ref_id,p_test_context_id);
  if v_info.status<>'active' or v_info.visibility<>'household'
     or v_info.ack_policy<>'required' or v_info.valid_from>v_now
     or (v_info.valid_until is not null and v_info.valid_until<=v_now)
     or v_info.author_actor_ref_id=p_actor_ref_id
     or (v_actor_user_id is not null and v_info.author_id=v_actor_user_id) then
    raise exception 'INFO_ACK_NOT_ACTIONABLE';
  end if;
  insert into public.info_acknowledgements(household_id,handover_id,actor_ref_id,test_context_id)
  values(p_household_id,p_handover_id,p_actor_ref_id,p_test_context_id) on conflict do nothing;
  v_result:=jsonb_build_object('handover_id',p_handover_id,'acknowledged',true);
  perform private.fn_complete_canonical_operation_v1(v_receipt_id,'info',p_handover_id,v_result);
  return v_result;
end;
$$;
revoke all on function private.fn_command_ack_info_v1(uuid,uuid,uuid,uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function private.fn_command_ack_info_v1(uuid,uuid,uuid,uuid,uuid,uuid) to service_role;

-- The canonical command owns readiness after claiming its receipt. Checking
-- readiness here first would reject legitimate retries after the deadline.
create or replace function public.server_tx_ack_info_v1(
  p_actor_id uuid,p_operation_id uuid,p_handover_id uuid
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_context jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_handover_id is null then raise exception 'INVALID_INPUT'; end if;
  v_context:=private.fn_require_production_actor_context_v1(p_actor_id);
  return private.fn_command_ack_info_v1(
    (v_context->>'household_id')::uuid,p_actor_id,(v_context->>'actor_ref_id')::uuid,
    null,p_handover_id,p_operation_id
  );
end;
$$;
revoke all on function public.server_tx_ack_info_v1(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.server_tx_ack_info_v1(uuid,uuid,uuid) to service_role;

-- PWA's established read adapter also projects info_acknowledgements. Keep
-- ordinary share/history reads and its original receipt/result shape. Only
-- an action-required acknowledgement uses the current-recipient boundary.
create or replace function public.server_tx_mark_handover_read(
  p_actor_id uuid,p_operation_id uuid,p_handover_id uuid
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare
  v_context jsonb;
  v_household_id uuid;
  v_actor_ref_id uuid;
  v_request_hash text;
  v_receipt private.mutation_receipts%rowtype;
  v_info public.handovers%rowtype;
  v_now timestamptz;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_handover_id is null then raise exception 'INVALID_INPUT'; end if;
  v_context:=private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id:=(v_context->>'household_id')::uuid;
  v_actor_ref_id:=(v_context->>'actor_ref_id')::uuid;
  v_request_hash:=encode(sha256(convert_to('mark-handover-read|'||p_handover_id::text,'UTF8')),'hex');
  loop
    insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash,actor_ref_id)
    values(p_actor_id,p_operation_id,'mark-handover-read',v_request_hash,v_actor_ref_id)
    on conflict(actor_id,operation_id) do nothing;
    if found then exit; end if;
    select * into v_receipt from private.mutation_receipts
    where actor_id=p_actor_id and operation_id=p_operation_id for update;
    if found then
      if v_receipt.action_type<>'mark-handover-read' or v_receipt.request_hash<>v_request_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
      if v_receipt.test_context_id is not null then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
      if v_receipt.actor_ref_id is not null then
        if v_receipt.actor_ref_id<>v_actor_ref_id then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
      elsif not exists(select 1 from public.handovers
        where household_id=v_household_id and id=v_receipt.result_id and test_context_id is null) then
        raise exception 'CROSS_HOUSEHOLD_RESOURCE';
      end if;
      if v_receipt.result_payload is null then raise exception 'IDEMPOTENCY_INCOMPLETE'; end if;
      return v_receipt.result_payload;
    end if;
  end loop;
  select * into v_info from public.handovers
  where household_id=v_household_id and id=p_handover_id and test_context_id is null for share;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  v_now:=clock_timestamp();
  if v_info.visibility='self' and v_info.author_actor_ref_id is distinct from v_actor_ref_id
     and v_info.author_id is distinct from p_actor_id then
    raise exception 'INFO_ACK_NOT_ACTIONABLE'; end if;
  if v_info.ack_policy='required' and (v_info.status<>'active' or v_info.visibility<>'household'
     or v_info.valid_from>v_now or (v_info.valid_until is not null and v_info.valid_until<=v_now)
     or v_info.author_actor_ref_id=v_actor_ref_id or v_info.author_id=p_actor_id) then
    raise exception 'INFO_ACK_NOT_ACTIONABLE'; end if;
  insert into public.handover_reads(household_id,handover_id,user_id,read_at)
  values(v_household_id,p_handover_id,p_actor_id,now()) on conflict(handover_id,user_id) do nothing;
  insert into public.info_acknowledgements(household_id,handover_id,actor_ref_id,acknowledged_at,test_context_id)
  values(v_household_id,p_handover_id,v_actor_ref_id,now(),null) on conflict(handover_id,actor_ref_id) do nothing;
  v_result:=jsonb_build_object('ok',true);
  update private.mutation_receipts set result_type='handover',result_id=p_handover_id,result_payload=v_result
  where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end;
$$;
revoke all on function public.server_tx_mark_handover_read(uuid,uuid,uuid) from public,anon,authenticated;
grant execute on function public.server_tx_mark_handover_read(uuid,uuid,uuid) to service_role;
