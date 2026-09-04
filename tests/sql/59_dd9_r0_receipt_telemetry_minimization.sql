-- DD9 R0 receipt regression.
-- Submitted fact/candidate cardinalities may be returned to the current caller,
-- but they must not be copied into durable canonical operation receipts.  Exact
-- idempotent replay reconstructs those ephemeral counts from the same request.
\set ON_ERROR_STOP on
set role service_role;

do $$
declare
  v_owner uuid:='59000000-0000-0000-0000-000000000001';
  v_household uuid; v_actor uuid; v_child uuid; v_context uuid;
  v_intake jsonb; v_extraction uuid; v_review jsonb; v_replay jsonb;
  v_school jsonb; v_facts jsonb; v_ai jsonb;
  v_operation uuid:='59000000-0000-0000-0000-000000000102';
  v_receipt uuid; v_error text; v_payload jsonb;
begin
  insert into auth.users(id) values(v_owner) on conflict do nothing;
  insert into public.profiles(user_id,display_name)
  values(v_owner,'DD9 receipt owner') on conflict do nothing;
  v_household:=(public.server_tx_create_household(
    v_owner,'59000000-0000-0000-0000-000000000010','DD9 receipt household','Asia/Tokyo'
  )->>'household_id')::uuid;
  select id into v_actor from public.domain_actor_refs
  where household_id=v_household and actor_kind='real_user' and real_user_id=v_owner;
  insert into public.family_children(household_id,display_name)
  values(v_household,'Receipt child') returning id into v_child;
  insert into public.child_school_contexts(
    household_id,child_id,school_display_name,class_display_name,effective_from,recognition_aliases
  ) values(v_household,v_child,'Receipt school','R','2030-01-01',array['R'])
  returning id into v_context;

  v_intake:=private.fn_command_create_nursery_intake_v1(
    v_household,v_owner,v_actor,null,
    '59000000-0000-0000-0000-000000000101','codmon_notice','caller-key',
    '2179-01-01 01:02+09','receipt-test',jsonb_build_object('provider','test'),'pwa'
  );
  v_extraction:=(v_intake->>'extraction_id')::uuid;
  v_school:=jsonb_build_object('child_school_context_id',v_context);
  v_facts:=jsonb_build_array(jsonb_build_object(
    'child_school_context_id',v_context,'fact_kind','required_item',
    'normalized_value',jsonb_build_object('item','エプロン','quantity',20),
    'confidence_band','high'
  ));
  v_ai:=jsonb_build_array(jsonb_build_object(
    'child_school_context_id',v_context,'target_type','task',
    'proposed_patch',jsonb_build_object('title','YAMADA HANAKO','scheduled_date','2179-01-01'),
    'explanation','YAMADA 09077778888 third-party@example.test'
  ));

  v_review:=private.fn_command_record_nursery_extraction_v1(
    v_household,v_owner,v_actor,null,v_operation,v_extraction,1,
    v_school,v_facts,v_ai,'pwa'
  );
  if (v_review->>'source_fact_count')::integer<>1
     or (v_review->>'ai_candidate_count')::integer<>1
     or v_review->>'state'<>'review' then
    raise exception 'FAIL DD9 receipt: immediate compatibility telemetry wrong: %',v_review;
  end if;

  select r.id,r.result_payload into v_receipt,v_payload
  from private.canonical_operation_receipts r
  where r.actor_ref_id=v_actor and r.operation_id=v_operation
    and r.action_type='nursery.extraction.record';
  if v_receipt is null then raise exception 'FAIL DD9 receipt: completed receipt missing'; end if;
  if v_payload ? 'source_fact_count' or v_payload ? 'ai_candidate_count'
     or v_payload::text like '%YAMADA%'
     or v_payload::text like '%09077778888%'
     or v_payload::text like '%third-party%' then
    raise exception 'FAIL DD9 receipt: request-selected telemetry/content became durable: %',v_payload;
  end if;
  if v_payload->>'structured_persistence'<>'withheld_untrusted_r0'
     or (v_payload->>'durable_source_fact_slots')::integer<>64
     or (v_payload->>'durable_ai_candidate_slots')::integer<>32 then
    raise exception 'FAIL DD9 receipt: durable canonical result not fixed quarantine metadata: %',v_payload;
  end if;

  -- Same operation + exact request replays the same API response, including
  -- ephemeral counts reconstructed from this request rather than the receipt.
  v_replay:=private.fn_command_record_nursery_extraction_v1(
    v_household,v_owner,v_actor,null,v_operation,v_extraction,1,
    v_school,v_facts,v_ai,'pwa'
  );
  if v_replay is distinct from v_review then
    raise exception 'FAIL DD9 receipt: idempotent replay response changed: first=% replay=%',v_review,v_replay;
  end if;

  -- A completed nursery receipt is immutable even for direct service_role.
  begin
    update private.canonical_operation_receipts
    set result_payload=result_payload||jsonb_build_object(
      'source_fact_count',64,'ai_candidate_count',32,
      'secret','YAMADA|09077778888|third-party@example.test'
    ) where id=v_receipt;
    raise exception 'FAIL DD9 receipt: completed result payload reinjection accepted';
  exception when others then
    v_error:=sqlerrm;
    if v_error like 'FAIL DD9 receipt:%' then raise; end if;
    if v_error not like '%NURSERY_OPERATION_RECEIPT_IMMUTABLE%' then raise; end if;
  end;
  begin
    update private.canonical_operation_receipts
    set action_type='nursery.extraction.record.bypass',
        result_payload=jsonb_build_object('secret','YAMADA')
    where id=v_receipt;
    raise exception 'FAIL DD9 receipt: receipt relabel bypass accepted';
  exception when others then
    v_error:=sqlerrm;
    if v_error like 'FAIL DD9 receipt:%' then raise; end if;
    if v_error not like '%NURSERY_OPERATION_RECEIPT_PROVENANCE_IMMUTABLE%' then raise; end if;
  end;

  -- A direct privileged nursery receipt INSERT is no longer a supported claim
  -- path at all.  Even when it copies a valid server-derived request_hash, it
  -- must not be able to mint a second nursery receipt with hostile pre-completed
  -- result fields.  The canonical SECURITY DEFINER command/helper path is the
  -- only nursery receipt creator.
  begin
    insert into private.canonical_operation_receipts(
      household_id,operator_user_id,actor_ref_id,test_context_id,operation_id,
      action_type,request_hash,result_type,result_id,result_payload,completed_at
    ) select household_id,operator_user_id,actor_ref_id,test_context_id,
             '59000000-0000-0000-0000-000000000199'::uuid,
             action_type,request_hash,'document_extraction',v_extraction,
             jsonb_build_object('secret','YAMADA','source_fact_count',64),now()
      from private.canonical_operation_receipts where id=v_receipt;
    raise exception 'FAIL DD9 receipt: direct nursery receipt INSERT accepted';
  exception when others then
    v_error:=sqlerrm;
    if v_error like 'FAIL DD9 receipt:%' then raise; end if;
    if v_error not like '%NURSERY_OPERATION_RECEIPT_DIRECT_INSERT_FORBIDDEN%' then raise; end if;
  end;

  if exists(
    select 1 from private.canonical_operation_receipts
    where actor_ref_id=v_actor
      and operation_id='59000000-0000-0000-0000-000000000199'::uuid
  ) then
    raise exception 'FAIL DD9 receipt: rejected direct INSERT left durable receipt';
  end if;
end;
$$;
reset role;
select '59_dd9_r0_receipt_telemetry_minimization: PASS' as result;