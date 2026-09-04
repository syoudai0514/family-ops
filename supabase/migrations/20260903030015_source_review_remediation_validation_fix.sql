-- PostgreSQL 16 compatibility fix for PR #45 source-review remediation.
-- The prior remediation migration defines the intended structural boundary;
-- this migration replaces only object-cardinality expressions that are not
-- available as jsonb_object_length() in PostgreSQL 16.

create or replace function private.fn_validate_nursery_fact_value_v2(
  p_fact_kind text,p_value jsonb
) returns void language plpgsql immutable security invoker set search_path='' as $$
declare
  v_allowed text[]; v_key text; v_val jsonb; v_url text;
begin
  case p_fact_kind
    when 'event' then v_allowed:=array['title','event_type','date','start_date','end_date','all_day','location'];
    when 'required_item' then v_allowed:=array['item','quantity','note'];
    when 'deadline' then v_allowed:=array['label','date','time'];
    when 'recurrence' then v_allowed:=array['label','frequency','day_of_week','until'];
    when 'url' then v_allowed:=array['url','label'];
    when 'note' then v_allowed:=array['category','summary'];
    else raise exception 'NURSERY_FACT_KIND_INVALID';
  end case;
  perform private.fn_nursery_assert_object_allowlist_v2(
    p_value,v_allowed,2048,'NURSERY_FACT_VALUE_INVALID'
  );
  if p_value='{}'::jsonb then raise exception 'NURSERY_FACT_VALUE_INVALID'; end if;
  for v_key,v_val in select key,value from jsonb_each(p_value) loop
    if jsonb_typeof(v_val) not in ('string','number','boolean') then
      raise exception 'NURSERY_FACT_VALUE_INVALID';
    end if;
    if jsonb_typeof(v_val)='string' and length(v_val#>>'{}')>500 then
      raise exception 'NURSERY_FACT_VALUE_INVALID';
    end if;
  end loop;
  if p_fact_kind='required_item'
     and nullif(btrim(coalesce(p_value->>'item','')),'') is null then
    raise exception 'NURSERY_FACT_VALUE_INVALID';
  elsif p_fact_kind='url' then
    v_url:=p_value->>'url';
    if v_url is null or length(v_url)>2048 or v_url !~* '^https?://[^[:space:]]+$' then
      raise exception 'NURSERY_URL_INVALID';
    end if;
  elsif p_fact_kind='note' and length(coalesce(p_value->>'summary',''))>240 then
    raise exception 'NURSERY_FACT_VALUE_INVALID';
  end if;
end;
$$;

create or replace function private.fn_validate_nursery_structured_value_v1(p_value jsonb)
returns void language plpgsql immutable security invoker set search_path='' as $$
declare v_key text; v_val jsonb; v_key_count integer;
begin
  if p_value is null or jsonb_typeof(p_value)<>'object'
     or octet_length(p_value::text)>4096 then
    raise exception 'NURSERY_FACT_VALUE_INVALID';
  end if;
  select count(*)::integer into v_key_count from jsonb_object_keys(p_value);
  if v_key_count>12 then raise exception 'NURSERY_FACT_VALUE_INVALID'; end if;
  for v_key,v_val in select key,value from jsonb_each(p_value) loop
    if lower(v_key) in (
      'full_transcript','transcript','raw_text','class_roster','other_child','other_children',
      'third_party_contact','contact','contacts','person_profile','people','members','phone','email'
    ) then raise exception 'NURSERY_THIRD_PARTY_DATA_FORBIDDEN'; end if;
    if jsonb_typeof(v_val) not in ('string','number','boolean','null') then
      raise exception 'NURSERY_FACT_VALUE_INVALID';
    end if;
    if jsonb_typeof(v_val)='string' and length(v_val#>>'{}')>500 then
      raise exception 'NURSERY_FACT_VALUE_INVALID';
    end if;
  end loop;
end;
$$;

create or replace function private.fn_validate_nursery_ai_patch_v2(
  p_target_type text,p_patch jsonb
) returns void language plpgsql immutable security invoker set search_path='' as $$
declare v_allowed text[]; v_key text; v_val jsonb; v_url text;
begin
  case p_target_type
    when 'task' then v_allowed:=array['title','scheduled_date','due_at','calendar_ends_at','notes'];
    when 'family_event' then v_allowed:=array['title','all_day','start_date','end_date','starts_at','ends_at','location','notes'];
    when 'recurrence' then v_allowed:=array['title','rrule','effective_from','effective_to','notes'];
    when 'info' then v_allowed:=array['title','summary','effective_from','effective_to','url'];
    else raise exception 'NURSERY_AI_CANDIDATE_INVALID';
  end case;
  perform private.fn_nursery_assert_object_allowlist_v2(
    p_patch,v_allowed,4096,'NURSERY_AI_CANDIDATE_INVALID'
  );
  if p_patch='{}'::jsonb then raise exception 'NURSERY_AI_CANDIDATE_INVALID'; end if;
  for v_key,v_val in select key,value from jsonb_each(p_patch) loop
    if jsonb_typeof(v_val) not in ('string','number','boolean','null') then
      raise exception 'NURSERY_AI_CANDIDATE_INVALID';
    end if;
    if jsonb_typeof(v_val)='string' and length(v_val#>>'{}')>500 then
      raise exception 'NURSERY_AI_CANDIDATE_INVALID';
    end if;
  end loop;
  if p_patch ? 'url' then
    v_url:=p_patch->>'url';
    if v_url is null or length(v_url)>2048 or v_url !~* '^https?://[^[:space:]]+$' then
      raise exception 'NURSERY_URL_INVALID';
    end if;
  end if;
end;
$$;

create or replace function private.fn_command_record_nursery_extraction_v1(
  p_household_id uuid,p_operator_user_id uuid,p_actor_ref_id uuid,p_test_context_id uuid,
  p_operation_id uuid,p_extraction_id uuid,p_expected_revision bigint,
  p_school_context_candidate jsonb,p_source_facts jsonb,p_ai_candidates jsonb,p_source text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_claim jsonb; v_receipt_id uuid; v_extraction private.document_extractions%rowtype;
  v_fact jsonb; v_candidate jsonb; v_context_id uuid; v_fact_id uuid; v_candidate_id uuid;
  v_fact_count integer:=0; v_candidate_count integer:=0; v_revision bigint; v_result jsonb;
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
  if v_claim->>'disposition'='replay' then return v_claim->'result_payload'; end if;
  v_receipt_id:=(v_claim->>'receipt_id')::uuid;
  perform private.fn_validate_nursery_school_context_candidate_v2(p_school_context_candidate);
  select * into v_extraction from private.document_extractions
  where household_id=p_household_id and id=p_extraction_id for update;
  if not found then raise exception 'NURSERY_EXTRACTION_NOT_FOUND'; end if;
  if v_extraction.test_context_id is distinct from p_test_context_id then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
  if v_extraction.revision<>p_expected_revision then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  if v_extraction.state not in ('processing','review') then raise exception 'NURSERY_EXTRACTION_NOT_RECORDABLE'; end if;

  for v_fact in select value from jsonb_array_elements(coalesce(p_source_facts,'[]'::jsonb)) loop
    if jsonb_typeof(v_fact)<>'object' then raise exception 'NURSERY_FACT_VALUE_INVALID'; end if;
    select count(*)::integer into v_top_level_key_count from jsonb_object_keys(v_fact);
    if v_top_level_key_count>6 then raise exception 'NURSERY_FACT_VALUE_INVALID'; end if;
    if exists(
      select 1 from jsonb_object_keys(v_fact) as allowed_key(key)
      where key not in ('child_school_context_id','fact_kind','normalized_value','confidence_band','source_locator','source_label')
    ) then raise exception 'NURSERY_FACT_VALUE_INVALID'; end if;
    if coalesce(v_fact->>'fact_kind','') not in ('event','required_item','deadline','recurrence','url','note') then
      raise exception 'NURSERY_FACT_KIND_INVALID';
    end if;
    if coalesce(v_fact->>'confidence_band','') not in ('high','medium','low') then
      raise exception 'NURSERY_FACT_CONFIDENCE_INVALID';
    end if;
    if length(coalesce(v_fact->>'source_locator',''))>128
       or length(coalesce(v_fact->>'source_label',''))>120 then
      raise exception 'NURSERY_FACT_VALUE_INVALID';
    end if;
    begin v_context_id:=nullif(v_fact->>'child_school_context_id','')::uuid;
    exception when others then raise exception 'NURSERY_CHILD_SCHOOL_SCOPE_REQUIRED'; end;
    if v_context_id is null or not exists (
      select 1 from public.child_school_contexts s
      where s.household_id=p_household_id and s.id=v_context_id and s.active
    ) then raise exception 'NURSERY_CHILD_SCHOOL_SCOPE_REQUIRED'; end if;
    perform private.fn_validate_nursery_fact_value_v2(v_fact->>'fact_kind',v_fact->'normalized_value');
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
    if jsonb_typeof(v_candidate)<>'object' then raise exception 'NURSERY_AI_CANDIDATE_INVALID'; end if;
    select count(*)::integer into v_top_level_key_count from jsonb_object_keys(v_candidate);
    if v_top_level_key_count>7
       or exists(
         select 1 from jsonb_object_keys(v_candidate) as allowed_key(key)
         where key not in ('child_school_context_id','target_type','target_id','proposed_patch','explanation','current_snapshot_hash','confidence_band')
       )
       or coalesce(v_candidate->>'target_type','') not in ('family_event','task','recurrence','info')
       or jsonb_typeof(v_candidate->'proposed_patch')<>'object'
       or nullif(btrim(coalesce(v_candidate->>'explanation','')),'') is null
       or length(v_candidate->>'explanation')>500
       or length(coalesce(v_candidate->>'current_snapshot_hash',''))>160 then
      raise exception 'NURSERY_AI_CANDIDATE_INVALID';
    end if;
    begin v_context_id:=nullif(v_candidate->>'child_school_context_id','')::uuid;
    exception when others then raise exception 'NURSERY_CHILD_SCHOOL_SCOPE_REQUIRED'; end;
    if v_context_id is null or not exists (
      select 1 from public.child_school_contexts s
      where s.household_id=p_household_id and s.id=v_context_id and s.active
    ) then raise exception 'NURSERY_CHILD_SCHOOL_SCOPE_REQUIRED'; end if;
    perform private.fn_validate_nursery_ai_patch_v2(v_candidate->>'target_type',v_candidate->'proposed_patch');
    insert into public.change_candidates(
      household_id,target_type,target_id,source_type,source_ref,proposed_patch,current_snapshot_hash,test_context_id
    ) values (
      p_household_id,v_candidate->>'target_type',nullif(v_candidate->>'target_id','')::uuid,
      'ai_inference',p_extraction_id::text,
      (v_candidate->'proposed_patch')||jsonb_build_object(
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
