-- WP-DD9: Nursery/Codmon intake is an evidence and proposal pipeline.
-- No function in this migration creates a Task/Event, sends LINE, calls an AI
-- provider, or mutates Google.  Those effects remain behind later reviewed
-- target adapters after a human has selected a candidate.

alter table private.document_extractions
  add column revision bigint not null default 1 check (revision >= 1);
create unique index document_extractions_source_version_unique_v1
  on private.document_extractions (source_document_id, extraction_version);

create or replace function private.fn_validate_nursery_structured_value_v1(
  p_value jsonb
) returns void language plpgsql immutable security invoker set search_path='' as $$
declare v_text text;
begin
  if p_value is null or jsonb_typeof(p_value) not in ('object','array','string','number','boolean') then
    raise exception 'NURSERY_FACT_VALUE_INVALID';
  end if;
  -- These are intentionally not durable household business data.  The raw
  -- document remains the controlled evidence store while it exists.
  v_text:=lower(p_value::text);
  if v_text like '%full_transcript%' or v_text like '%class_roster%'
     or v_text like '%other_child%' or v_text like '%third_party_contact%' then
    raise exception 'NURSERY_THIRD_PARTY_DATA_FORBIDDEN';
  end if;
end;
$$;

create or replace function private.fn_command_create_nursery_intake_v1(
  p_household_id uuid,p_operator_user_id uuid,p_actor_ref_id uuid,p_test_context_id uuid,
  p_operation_id uuid,p_document_kind text,p_storage_object_key text,p_captured_at timestamptz,
  p_extraction_version text,p_provider_metadata jsonb,p_source text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_claim jsonb; v_receipt_id uuid; v_document_id uuid; v_extraction_id uuid; v_result jsonb;
begin
  if p_source not in ('line','pwa') then raise exception 'COMMAND_SOURCE_INVALID'; end if;
  if nullif(btrim(coalesce(p_document_kind,'')),'') is null
     or nullif(btrim(coalesce(p_extraction_version,'')),'') is null then
    raise exception 'NURSERY_DOCUMENT_INPUT_INVALID';
  end if;
  if nullif(btrim(coalesce(p_storage_object_key,'')),'') is null
     or p_storage_object_key ~* '^[a-z][a-z0-9+.-]*://' then
    raise exception 'NURSERY_PRIVATE_OBJECT_KEY_REQUIRED';
  end if;
  v_claim:=private.fn_claim_canonical_operation_v1(
    p_household_id,p_operator_user_id,p_actor_ref_id,p_test_context_id,p_operation_id,
    'nursery.intake.create',private.fn_canonical_request_hash_v1(jsonb_build_object(
      'document_kind',p_document_kind,'storage_object_key',p_storage_object_key,
      'captured_at',p_captured_at,'extraction_version',p_extraction_version,
      'provider_metadata',coalesce(p_provider_metadata,'{}'::jsonb),'source',p_source
    ))
  );
  if v_claim->>'disposition'='replay' then return v_claim->'result_payload'; end if;
  v_receipt_id:=(v_claim->>'receipt_id')::uuid;

  insert into private.source_documents(
    household_id,uploaded_by_actor_ref_id,document_kind,storage_object_key,captured_at,test_context_id
  ) values (
    p_household_id,p_actor_ref_id,btrim(p_document_kind),p_storage_object_key,p_captured_at,p_test_context_id
  ) returning id into v_document_id;
  insert into private.document_extractions(
    household_id,source_document_id,extraction_version,provider_metadata,state,test_context_id
  ) values (
    p_household_id,v_document_id,btrim(p_extraction_version),coalesce(p_provider_metadata,'{}'::jsonb),
    'processing',p_test_context_id
  ) returning id into v_extraction_id;
  v_result:=jsonb_build_object('source_document_id',v_document_id,'extraction_id',v_extraction_id,
    'state','processing','side_effects','none');
  perform private.fn_complete_canonical_operation_v1(v_receipt_id,'source_document',v_document_id,v_result);
  return v_result;
end;
$$;

create or replace function private.fn_command_record_nursery_extraction_v1(
  p_household_id uuid,p_operator_user_id uuid,p_actor_ref_id uuid,p_test_context_id uuid,
  p_operation_id uuid,p_extraction_id uuid,p_expected_revision bigint,
  p_school_context_candidate jsonb,p_source_facts jsonb,p_ai_candidates jsonb,p_source text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_claim jsonb; v_receipt_id uuid; v_extraction private.document_extractions%rowtype;
  v_fact jsonb; v_candidate jsonb; v_context_id uuid; v_fact_id uuid; v_candidate_id uuid;
  v_fact_count integer:=0; v_candidate_count integer:=0; v_revision bigint; v_result jsonb;
begin
  if p_source not in ('line','pwa') then raise exception 'COMMAND_SOURCE_INVALID'; end if;
  if jsonb_typeof(coalesce(p_source_facts,'[]'::jsonb))<>'array'
     or jsonb_typeof(coalesce(p_ai_candidates,'[]'::jsonb))<>'array' then
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
  if v_claim->>'disposition'='replay' then return v_claim->'result_payload'; end if;
  v_receipt_id:=(v_claim->>'receipt_id')::uuid;
  select * into v_extraction from private.document_extractions
  where household_id=p_household_id and id=p_extraction_id for update;
  if not found then raise exception 'NURSERY_EXTRACTION_NOT_FOUND'; end if;
  if v_extraction.test_context_id is distinct from p_test_context_id then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
  if v_extraction.revision<>p_expected_revision then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  if v_extraction.state not in ('processing','review') then raise exception 'NURSERY_EXTRACTION_NOT_RECORDABLE'; end if;

  for v_fact in select value from jsonb_array_elements(coalesce(p_source_facts,'[]'::jsonb)) loop
    if jsonb_typeof(v_fact)<>'object' then raise exception 'NURSERY_FACT_VALUE_INVALID'; end if;
    if coalesce(v_fact->>'fact_kind','') not in ('event','required_item','deadline','recurrence','url','note') then
      raise exception 'NURSERY_FACT_KIND_INVALID';
    end if;
    if coalesce(v_fact->>'confidence_band','') not in ('high','medium','low') then
      raise exception 'NURSERY_FACT_CONFIDENCE_INVALID';
    end if;
    v_context_id:=nullif(v_fact->>'child_school_context_id','')::uuid;
    if v_context_id is null or not exists (
      select 1 from public.child_school_contexts s
      where s.household_id=p_household_id and s.id=v_context_id and s.active
    ) then raise exception 'NURSERY_CHILD_SCHOOL_SCOPE_REQUIRED'; end if;
    perform private.fn_validate_nursery_structured_value_v1(v_fact->'normalized_value');
    insert into private.document_facts(
      household_id,extraction_id,child_school_context_id,fact_kind,normalized_value,
      confidence_band,source_locator,fact_origin,test_context_id
    ) values (
      p_household_id,p_extraction_id,v_context_id,v_fact->>'fact_kind',v_fact->'normalized_value',
      v_fact->>'confidence_band',nullif(v_fact->>'source_locator',''),'source_explicit',p_test_context_id
    ) returning id into v_fact_id;
    v_fact_count:=v_fact_count+1;
  end loop;

  for v_candidate in select value from jsonb_array_elements(coalesce(p_ai_candidates,'[]'::jsonb)) loop
    if jsonb_typeof(v_candidate)<>'object'
       or coalesce(v_candidate->>'target_type','') not in ('family_event','task','recurrence','info')
       or jsonb_typeof(v_candidate->'proposed_patch')<>'object'
       or nullif(btrim(coalesce(v_candidate->>'explanation','')),'') is null then
      raise exception 'NURSERY_AI_CANDIDATE_INVALID';
    end if;
    v_context_id:=nullif(v_candidate->>'child_school_context_id','')::uuid;
    if v_context_id is null or not exists (
      select 1 from public.child_school_contexts s
      where s.household_id=p_household_id and s.id=v_context_id and s.active
    ) then raise exception 'NURSERY_CHILD_SCHOOL_SCOPE_REQUIRED'; end if;
    perform private.fn_validate_nursery_structured_value_v1(v_candidate->'proposed_patch');
    insert into public.change_candidates(
      household_id,target_type,target_id,source_type,source_ref,proposed_patch,current_snapshot_hash,test_context_id
    ) values (
      p_household_id,v_candidate->>'target_type',nullif(v_candidate->>'target_id','')::uuid,
      'ai_inference',p_extraction_id::text,
      (v_candidate->'proposed_patch') || jsonb_build_object(
        'origin_label','ai_inference','explanation',v_candidate->>'explanation',
        'child_school_context_id',v_context_id
      ),nullif(v_candidate->>'current_snapshot_hash',''),p_test_context_id
    ) returning id into v_candidate_id;
    v_candidate_count:=v_candidate_count+1;
  end loop;
  update private.document_extractions
  set school_context_candidate=p_school_context_candidate,state='review',revision=revision+1
  where id=p_extraction_id returning revision into v_revision;
  v_result:=jsonb_build_object('extraction_id',p_extraction_id,'state','review','revision',v_revision,
    'source_fact_count',v_fact_count,'ai_candidate_count',v_candidate_count,'side_effects','none');
  perform private.fn_complete_canonical_operation_v1(v_receipt_id,'document_extraction',p_extraction_id,v_result);
  return v_result;
end;
$$;

create or replace function private.fn_command_confirm_school_preparation_rule_v1(
  p_household_id uuid,p_operator_user_id uuid,p_actor_ref_id uuid,p_test_context_id uuid,
  p_operation_id uuid,p_child_school_context_id uuid,p_trigger_spec jsonb,p_preparation_template jsonb,
  p_effective_from date,p_effective_to date,p_source text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_claim jsonb; v_receipt_id uuid; v_rule_id uuid; v_result jsonb;
begin
  if p_test_context_id is not null then raise exception 'TEST_SIDE_EFFECT_FORBIDDEN'; end if;
  if p_source not in ('line','pwa') or p_effective_from is null
     or (p_effective_to is not null and p_effective_to<p_effective_from) then
    raise exception 'NURSERY_PREPARATION_RULE_INPUT_INVALID'; end if;
  perform private.fn_validate_nursery_structured_value_v1(p_trigger_spec);
  perform private.fn_validate_nursery_structured_value_v1(p_preparation_template);
  if not exists (select 1 from public.child_school_contexts s
    where s.household_id=p_household_id and s.id=p_child_school_context_id and s.active) then
    raise exception 'NURSERY_CHILD_SCHOOL_SCOPE_REQUIRED'; end if;
  v_claim:=private.fn_claim_canonical_operation_v1(
    p_household_id,p_operator_user_id,p_actor_ref_id,null,p_operation_id,
    'nursery.preparation_rule.confirm',private.fn_canonical_request_hash_v1(jsonb_build_object(
      'child_school_context_id',p_child_school_context_id,'trigger_spec',p_trigger_spec,
      'preparation_template',p_preparation_template,'effective_from',p_effective_from,
      'effective_to',p_effective_to,'source',p_source
    ))
  );
  if v_claim->>'disposition'='replay' then return v_claim->'result_payload'; end if;
  v_receipt_id:=(v_claim->>'receipt_id')::uuid;
  insert into public.school_preparation_rules(
    household_id,child_school_context_id,trigger_spec,preparation_template,confirmed_by_actor_ref_id,
    effective_from,effective_to
  ) values (
    p_household_id,p_child_school_context_id,p_trigger_spec,p_preparation_template,p_actor_ref_id,
    p_effective_from,p_effective_to
  ) returning id into v_rule_id;
  v_result:=jsonb_build_object('school_preparation_rule_id',v_rule_id,'confirmed',true);
  perform private.fn_complete_canonical_operation_v1(v_receipt_id,'school_preparation_rule',v_rule_id,v_result);
  return v_result;
end;
$$;

revoke all on function private.fn_command_create_nursery_intake_v1(uuid,uuid,uuid,uuid,uuid,text,text,timestamptz,text,jsonb,text) from public,anon,authenticated;
revoke all on function private.fn_command_record_nursery_extraction_v1(uuid,uuid,uuid,uuid,uuid,uuid,bigint,jsonb,jsonb,jsonb,text) from public,anon,authenticated;
revoke all on function private.fn_command_confirm_school_preparation_rule_v1(uuid,uuid,uuid,uuid,uuid,uuid,jsonb,jsonb,date,date,text) from public,anon,authenticated;
grant execute on function private.fn_command_create_nursery_intake_v1(uuid,uuid,uuid,uuid,uuid,text,text,timestamptz,text,jsonb,text) to service_role;
grant execute on function private.fn_command_record_nursery_extraction_v1(uuid,uuid,uuid,uuid,uuid,uuid,bigint,jsonb,jsonb,jsonb,text) to service_role;
grant execute on function private.fn_command_confirm_school_preparation_rule_v1(uuid,uuid,uuid,uuid,uuid,uuid,jsonb,jsonb,date,date,text) to service_role;
