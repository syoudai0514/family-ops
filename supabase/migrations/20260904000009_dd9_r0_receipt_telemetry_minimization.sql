-- DD9 R0 privacy boundary follow-up.
--
-- Quarantining document_facts/change_candidates is insufficient if the same
-- model-selected collection cardinalities are copied into the durable canonical
-- operation receipt.  For nursery.extraction.record, persist only server-derived
-- lifecycle/result metadata.  Submitted array counts are reconstructed from the
-- exact request on each response (including idempotent replay) and are therefore
-- not durable state.

create or replace function private.fn_guard_nursery_extraction_receipt_r0_v1()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  v_revision bigint;
  v_household uuid;
  v_test_context uuid;
begin
  if tg_op='INSERT' then
    if new.action_type='nursery.extraction.record' then
      -- Claim rows are always incomplete.  A future direct service-role caller
      -- cannot smuggle structured result data during the claim INSERT.
      new.result_type:=null;
      new.result_id:=null;
      new.result_payload:='{}'::jsonb;
      new.completed_at:=null;
    end if;
    return new;
  end if;

  if old.action_type<>'nursery.extraction.record' then
    return new;
  end if;

  if new.action_type is distinct from old.action_type
     or new.id is distinct from old.id
     or new.household_id is distinct from old.household_id
     or new.operator_user_id is distinct from old.operator_user_id
     or new.actor_ref_id is distinct from old.actor_ref_id
     or new.test_context_id is distinct from old.test_context_id
     or new.operation_id is distinct from old.operation_id
     or new.request_hash is distinct from old.request_hash then
    raise exception 'NURSERY_OPERATION_RECEIPT_PROVENANCE_IMMUTABLE';
  end if;

  if old.completed_at is not null then
    if new.result_type is distinct from old.result_type
       or new.result_id is distinct from old.result_id
       or new.result_payload is distinct from old.result_payload
       or new.completed_at is distinct from old.completed_at then
      raise exception 'NURSERY_OPERATION_RECEIPT_IMMUTABLE';
    end if;
    return new;
  end if;

  if new.completed_at is null then
    new.result_type:=null;
    new.result_id:=null;
    new.result_payload:='{}'::jsonb;
    return new;
  end if;

  if new.result_type is distinct from 'document_extraction'
     or new.result_id is null then
    raise exception 'NURSERY_OPERATION_RECEIPT_RESULT_INVALID';
  end if;

  select e.household_id,e.test_context_id,e.revision
    into v_household,v_test_context,v_revision
  from private.document_extractions e
  where e.id=new.result_id;
  if not found
     or v_household is distinct from new.household_id
     or v_test_context is distinct from new.test_context_id then
    raise exception 'NURSERY_OPERATION_RECEIPT_RESULT_SCOPE_MISMATCH';
  end if;

  -- Canonicalize the durable result.  No submitted fact/candidate count or
  -- model-selected tuple/value is retained here.
  new.result_payload:=jsonb_build_object(
    'extraction_id',new.result_id,
    'state','review',
    'revision',v_revision,
    'durable_source_fact_slots',64,
    'durable_ai_candidate_slots',32,
    'structured_persistence','withheld_untrusted_r0',
    'side_effects','none'
  );
  return new;
end;
$$;
revoke all on function private.fn_guard_nursery_extraction_receipt_r0_v1()
  from public,anon,authenticated,service_role;

drop trigger if exists canonical_operation_receipts_nursery_r0_v1
  on private.canonical_operation_receipts;
create trigger canonical_operation_receipts_nursery_r0_v1
before insert or update on private.canonical_operation_receipts
for each row execute function private.fn_guard_nursery_extraction_receipt_r0_v1();

create or replace function private.fn_command_record_nursery_extraction_v1(
  p_household_id uuid,p_operator_user_id uuid,p_actor_ref_id uuid,p_test_context_id uuid,
  p_operation_id uuid,p_extraction_id uuid,p_expected_revision bigint,
  p_school_context_candidate jsonb,p_source_facts jsonb,p_ai_candidates jsonb,p_source text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_claim jsonb;
  v_receipt_id uuid;
  v_extraction private.document_extractions%rowtype;
  v_fact jsonb;
  v_candidate jsonb;
  v_context_id uuid;
  v_fact_count integer:=0;
  v_candidate_count integer:=0;
  v_revision bigint;
  v_receipt_result jsonb;
  v_response jsonb;
  v_top_level_key_count integer;
begin
  if p_source not in ('line','pwa') then raise exception 'COMMAND_SOURCE_INVALID'; end if;
  if jsonb_typeof(coalesce(p_source_facts,'[]'::jsonb))<>'array'
     or jsonb_typeof(coalesce(p_ai_candidates,'[]'::jsonb))<>'array'
     or jsonb_array_length(coalesce(p_source_facts,'[]'::jsonb))>64
     or jsonb_array_length(coalesce(p_ai_candidates,'[]'::jsonb))>32
     or octet_length(coalesce(p_source_facts,'[]'::jsonb)::text)>32768
     or octet_length(coalesce(p_ai_candidates,'[]'::jsonb)::text)>32768 then
    raise exception 'NURSERY_EXTRACTION_PAYLOAD_INVALID';
  end if;

  v_claim:=private.fn_claim_canonical_operation_v1(
    p_household_id,p_operator_user_id,p_actor_ref_id,p_test_context_id,p_operation_id,
    'nursery.extraction.record',private.fn_canonical_request_hash_v1(jsonb_build_object(
      'extraction_id',p_extraction_id,'expected_revision',p_expected_revision,
      'school_context_candidate',p_school_context_candidate,'source_facts',p_source_facts,
      'ai_candidates',p_ai_candidates,'source',p_source
    ))
  );
  if v_claim->>'disposition'='replay' then
    return coalesce(v_claim->'result_payload','{}'::jsonb)||jsonb_build_object(
      'source_fact_count',jsonb_array_length(coalesce(p_source_facts,'[]'::jsonb)),
      'ai_candidate_count',jsonb_array_length(coalesce(p_ai_candidates,'[]'::jsonb))
    );
  end if;
  v_receipt_id:=(v_claim->>'receipt_id')::uuid;

  perform private.fn_validate_nursery_school_context_candidate_v2(p_school_context_candidate);
  if nullif(btrim(coalesce(p_school_context_candidate->>'child_school_context_id','')),'') is not null then
    begin
      v_context_id:=(p_school_context_candidate->>'child_school_context_id')::uuid;
    exception when others then
      raise exception 'NURSERY_CHILD_SCHOOL_SCOPE_REQUIRED';
    end;
    if not exists (
      select 1 from public.child_school_contexts s
      where s.household_id=p_household_id and s.id=v_context_id and s.active
    ) then raise exception 'NURSERY_CHILD_SCHOOL_SCOPE_REQUIRED'; end if;
  end if;

  select * into v_extraction
  from private.document_extractions
  where household_id=p_household_id and id=p_extraction_id
  for update;
  if not found then raise exception 'NURSERY_EXTRACTION_NOT_FOUND'; end if;
  if v_extraction.test_context_id is distinct from p_test_context_id then
    raise exception 'ACTOR_SCOPE_CONFLICT';
  end if;
  if v_extraction.revision<>p_expected_revision then
    raise exception 'AGGREGATE_REVISION_CONFLICT';
  end if;
  if v_extraction.state not in ('processing','review') then
    raise exception 'NURSERY_EXTRACTION_NOT_RECORDABLE';
  end if;

  for v_fact in select value from jsonb_array_elements(coalesce(p_source_facts,'[]'::jsonb)) loop
    if jsonb_typeof(v_fact)<>'object' then raise exception 'NURSERY_FACT_VALUE_INVALID'; end if;
    select count(*)::integer into v_top_level_key_count from jsonb_object_keys(v_fact);
    if v_top_level_key_count>6 or exists(
      select 1 from jsonb_object_keys(v_fact) as allowed_key(key)
      where key not in (
        'child_school_context_id','fact_kind','normalized_value','confidence_band','source_locator','source_label'
      )
    ) then raise exception 'NURSERY_FACT_VALUE_INVALID'; end if;
    if coalesce(v_fact->>'fact_kind','') not in ('event','required_item','deadline','recurrence','url','note') then
      raise exception 'NURSERY_FACT_KIND_INVALID';
    end if;
    if coalesce(v_fact->>'confidence_band','') not in ('high','medium','low') then
      raise exception 'NURSERY_FACT_CONFIDENCE_INVALID';
    end if;
    begin
      v_context_id:=nullif(v_fact->>'child_school_context_id','')::uuid;
    exception when others then
      raise exception 'NURSERY_CHILD_SCHOOL_SCOPE_REQUIRED';
    end;
    if v_context_id is null or not exists (
      select 1 from public.child_school_contexts s
      where s.household_id=p_household_id and s.id=v_context_id and s.active
    ) then raise exception 'NURSERY_CHILD_SCHOOL_SCOPE_REQUIRED'; end if;
    perform private.fn_validate_nursery_fact_value_v2(v_fact->>'fact_kind',v_fact->'normalized_value');
    v_fact_count:=v_fact_count+1;
  end loop;

  for v_candidate in select value from jsonb_array_elements(coalesce(p_ai_candidates,'[]'::jsonb)) loop
    if jsonb_typeof(v_candidate)<>'object' then raise exception 'NURSERY_AI_CANDIDATE_INVALID'; end if;
    select count(*)::integer into v_top_level_key_count from jsonb_object_keys(v_candidate);
    if v_top_level_key_count>7 or exists(
      select 1 from jsonb_object_keys(v_candidate) as allowed_key(key)
      where key not in (
        'child_school_context_id','target_type','target_id','proposed_patch','explanation',
        'current_snapshot_hash','confidence_band'
      )
    ) or coalesce(v_candidate->>'target_type','') not in ('family_event','task','recurrence','info')
      or jsonb_typeof(v_candidate->'proposed_patch')<>'object'
      or nullif(btrim(coalesce(v_candidate->>'explanation','')),'') is null then
      raise exception 'NURSERY_AI_CANDIDATE_INVALID';
    end if;
    begin
      v_context_id:=nullif(v_candidate->>'child_school_context_id','')::uuid;
    exception when others then
      raise exception 'NURSERY_CHILD_SCHOOL_SCOPE_REQUIRED';
    end;
    if v_context_id is null or not exists (
      select 1 from public.child_school_contexts s
      where s.household_id=p_household_id and s.id=v_context_id and s.active
    ) then raise exception 'NURSERY_CHILD_SCHOOL_SCOPE_REQUIRED'; end if;
    perform private.fn_validate_nursery_ai_patch_v2(
      v_candidate->>'target_type',v_candidate->'proposed_patch'
    );
    v_candidate_count:=v_candidate_count+1;
  end loop;

  update private.document_extractions
  set school_context_candidate=p_school_context_candidate,
      state='review',
      revision=revision+1
  where id=p_extraction_id
  returning revision into v_revision;

  v_receipt_result:=jsonb_build_object(
    'extraction_id',p_extraction_id,
    'state','review',
    'revision',v_revision,
    'durable_source_fact_slots',64,
    'durable_ai_candidate_slots',32,
    'structured_persistence','withheld_untrusted_r0',
    'side_effects','none'
  );
  perform private.fn_complete_canonical_operation_v1(
    v_receipt_id,'document_extraction',p_extraction_id,v_receipt_result
  );
  v_response:=v_receipt_result||jsonb_build_object(
    'source_fact_count',v_fact_count,
    'ai_candidate_count',v_candidate_count
  );
  return v_response;
end;
$$;

revoke all on function private.fn_command_record_nursery_extraction_v1(
  uuid,uuid,uuid,uuid,uuid,uuid,bigint,jsonb,jsonb,jsonb,text
) from public,anon,authenticated;
grant execute on function private.fn_command_record_nursery_extraction_v1(
  uuid,uuid,uuid,uuid,uuid,uuid,bigint,jsonb,jsonb,jsonb,text
) to service_role;
