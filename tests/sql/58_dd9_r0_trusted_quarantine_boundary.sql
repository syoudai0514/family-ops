-- DD9 independent re-review remediation regression.
--
-- Proves three previously untested pre-review channels are closed:
--   1) school_context_candidate cannot persist arbitrary/non-household strings;
--   2) source_documents.storage_object_key is server-issued and immutable;
--   3) a real order-independent 39-byte / 64-row legal required-item multiset
--      reaches the ordinary command, while durable facts/candidates remain a
--      DB-issued constant quarantine representation independent of the secret.
\set ON_ERROR_STOP on
set role service_role;

create temporary table dd9_r0_temp_bootstrap(x integer);

create or replace function pg_temp.dd9_binom(p_n integer,p_k integer)
returns numeric
language plpgsql
immutable
as $$
declare
  v_k integer:=least(p_k,p_n-p_k);
  v_i integer;
  v_result numeric:=1;
begin
  if p_k<0 or p_k>p_n then return 0; end if;
  if v_k=0 then return 1; end if;
  for v_i in 1..v_k loop
    v_result:=v_result*(p_n-v_k+v_i)/v_i;
  end loop;
  return trunc(v_result);
end;
$$;

create or replace function pg_temp.dd9_unrank_multiset(
  p_rank numeric,p_symbol_count integer,p_k integer
) returns integer[]
language plpgsql
immutable
as $$
declare
  v_n integer:=p_symbol_count+p_k-1;
  v_rank numeric:=p_rank;
  v_result integer[]:='{}'::integer[];
  v_prev integer:=-1;
  v_i integer;
  v_y integer;
  v_count numeric;
  v_chosen boolean;
begin
  if p_rank<0 or p_rank>=pg_temp.dd9_binom(v_n,p_k) then
    raise exception 'DD9_MULTISET_RANK_OUT_OF_RANGE';
  end if;
  for v_i in 0..p_k-1 loop
    v_chosen:=false;
    for v_y in v_prev+1..v_n-(p_k-v_i) loop
      v_count:=pg_temp.dd9_binom(v_n-v_y-1,p_k-v_i-1);
      if v_rank<v_count then
        v_result:=array_append(v_result,v_y-v_i);
        v_prev:=v_y;
        v_chosen:=true;
        exit;
      end if;
      v_rank:=v_rank-v_count;
    end loop;
    if not v_chosen then raise exception 'DD9_MULTISET_UNRANK_FAILED'; end if;
  end loop;
  return v_result;
end;
$$;

create or replace function pg_temp.dd9_rank_multiset(
  p_values integer[],p_symbol_count integer
) returns numeric
language plpgsql
immutable
as $$
declare
  v_k integer:=cardinality(p_values);
  v_n integer:=p_symbol_count+cardinality(p_values)-1;
  v_rank numeric:=0;
  v_prev integer:=-1;
  v_i integer;
  v_y integer;
  v_target integer;
begin
  if v_k is null or v_k=0 then return 0; end if;
  for v_i in 0..v_k-1 loop
    v_target:=p_values[v_i+1]+v_i;
    if v_target>v_prev+1 then
      for v_y in v_prev+1..v_target-1 loop
        v_rank:=v_rank+pg_temp.dd9_binom(v_n-v_y-1,v_k-v_i-1);
      end loop;
    end if;
    v_prev:=v_target;
  end loop;
  return v_rank;
end;
$$;

create or replace function pg_temp.dd9_bytes_to_numeric(p_value bytea)
returns numeric
language plpgsql
immutable
as $$
declare
  v_result numeric:=0;
  v_i integer;
begin
  if length(p_value)=0 then return 0; end if;
  for v_i in 0..length(p_value)-1 loop
    v_result:=v_result*256+get_byte(p_value,v_i);
  end loop;
  return v_result;
end;
$$;

create or replace function pg_temp.dd9_numeric_to_bytes(p_value numeric,p_length integer)
returns bytea
language plpgsql
immutable
as $$
declare
  v_value numeric:=trunc(p_value);
  v_result bytea:=decode(repeat('00',p_length),'hex');
  v_i integer;
  v_byte integer;
begin
  for v_i in reverse p_length-1..0 loop
    v_byte:=mod(v_value,256)::integer;
    v_result:=set_byte(v_result,v_i,v_byte);
    v_value:=trunc(v_value/256);
  end loop;
  if v_value<>0 then raise exception 'DD9_NUMERIC_BYTE_OVERFLOW'; end if;
  return v_result;
end;
$$;

do $$
declare
  v_owner uuid:='58000000-0000-0000-0000-000000000001';
  v_other_owner uuid:='58000000-0000-0000-0000-000000000002';
  v_household uuid; v_other_household uuid;
  v_actor uuid; v_other_actor uuid;
  v_child uuid; v_other_child uuid;
  v_context_a uuid; v_context_b uuid; v_expected_context uuid; v_foreign_context uuid;
  v_intake jsonb; v_intake2 jsonb; v_review jsonb;
  v_doc uuid; v_doc2 uuid; v_extraction uuid; v_extraction2 uuid;
  v_direct_doc uuid; v_direct_key text;
  v_secret bytea; v_secret2 bytea; v_roundtrip bytea;
  v_rank numeric; v_rank2 numeric; v_symbols integer[]; v_symbols2 integer[];
  v_facts jsonb:='[]'::jsonb; v_facts2 jsonb:='[]'::jsonb;
  v_item_codes text[]:=array[
    'apron','towel','water_bottle','hat','change_of_clothes','indoor_shoes',
    'swimsuit','swim_cap','diaper','wipes','other_review_required'
  ];
  v_symbol integer; v_item_idx integer; v_quantity_idx integer; v_conf_idx integer;
  v_normalized jsonb; v_confidence text;
  v_snap1 jsonb; v_snap2 jsonb; v_candidate_snap1 jsonb; v_candidate_snap2 jsonb;
  v_fact_id uuid; v_candidate_id uuid; v_count integer; v_error text; g integer;
begin
  insert into auth.users(id) values(v_owner),(v_other_owner) on conflict do nothing;
  insert into public.profiles(user_id,display_name)
  values(v_owner,'DD9 quarantine owner'),(v_other_owner,'DD9 quarantine peer')
  on conflict do nothing;

  v_household:=(public.server_tx_create_household(
    v_owner,'58000000-0000-0000-0000-000000000010','DD9 quarantine household','Asia/Tokyo'
  )->>'household_id')::uuid;
  v_other_household:=(public.server_tx_create_household(
    v_other_owner,'58000000-0000-0000-0000-000000000011','DD9 quarantine peer','Asia/Tokyo'
  )->>'household_id')::uuid;

  select id into v_actor from public.domain_actor_refs
  where household_id=v_household and actor_kind='real_user' and real_user_id=v_owner;
  select id into v_other_actor from public.domain_actor_refs
  where household_id=v_other_household and actor_kind='real_user' and real_user_id=v_other_owner;

  insert into public.family_children(household_id,display_name)
  values(v_household,'Quarantine child') returning id into v_child;
  insert into public.child_school_contexts(
    household_id,child_id,school_display_name,class_display_name,effective_from,recognition_aliases
  ) values
    (v_household,v_child,'School A','A','2030-01-01',array['A'])
  returning id into v_context_a;
  insert into public.child_school_contexts(
    household_id,child_id,school_display_name,class_display_name,effective_from,recognition_aliases
  ) values
    (v_household,v_child,'School B','B','2030-01-01',array['B'])
  returning id into v_context_b;
  select s.id into v_expected_context from public.child_school_contexts s
  where s.household_id=v_household and s.active order by s.id::text limit 1;

  insert into public.family_children(household_id,display_name)
  values(v_other_household,'Foreign child') returning id into v_other_child;
  insert into public.child_school_contexts(
    household_id,child_id,school_display_name,class_display_name,effective_from,recognition_aliases
  ) values(v_other_household,v_other_child,'Foreign school','F','2030-01-01',array['F'])
  returning id into v_foreign_context;

  -- HIGH 2: hostile caller key reaches ordinary intake but not durable identity.
  v_intake:=private.fn_command_create_nursery_intake_v1(
    v_household,v_owner,v_actor,null,
    '58000000-0000-0000-0000-000000000101',
    'codmon_notice',
    'private/dd9/YAMADA-HANAKO/09077778888/third-party@example.test',
    '2179-01-01 09:00+09','hostile-key-v1',jsonb_build_object('provider','test'),'pwa'
  );
  v_doc:=(v_intake->>'source_document_id')::uuid;
  v_extraction:=(v_intake->>'extraction_id')::uuid;
  if not exists(
    select 1 from private.source_documents d
    where d.id=v_doc
      and d.storage_object_key='nursery-r0/'||d.id::text
      and d.storage_object_key not like '%YAMADA%'
      and d.storage_object_key not like '%09077778888%'
      and d.storage_object_key not like '%third-party%'
      and d.captured_at=d.uploaded_at
      and d.retention_policy='short_lived'
  ) then raise exception 'FAIL DD9 quarantine: caller storage key survived ordinary intake'; end if;

  begin
    update private.source_documents
    set storage_object_key='private/dd9/REINJECT/YAMADA/09077778888'
    where id=v_doc;
    raise exception 'FAIL DD9 quarantine: service-role storage key update accepted';
  exception when others then
    v_error:=sqlerrm;
    if v_error like 'FAIL DD9 quarantine:%' then raise; end if;
    if v_error not like '%NURSERY_SOURCE_DOCUMENT_PROVENANCE_IMMUTABLE%' then raise; end if;
  end;

  insert into private.source_documents(
    household_id,uploaded_by_actor_ref_id,document_kind,storage_object_key,captured_at,test_context_id
  ) values(
    v_household,v_actor,'codmon_notice','YAMADA|09077778888|direct-insert',now(),null
  ) returning id,storage_object_key into v_direct_doc,v_direct_key;
  if v_direct_key<>'nursery-r0/'||v_direct_doc::text or v_direct_key like '%YAMADA%' then
    raise exception 'FAIL DD9 quarantine: direct insert controlled source identity';
  end if;

  -- HIGH 1: valid household context is accepted as input, but DB chooses one
  -- deterministic server-issued context.  Arbitrary/foreign values fail closed.
  begin
    update private.document_extractions
    set school_context_candidate=jsonb_build_object(
      'child_school_context_id','YAMADA HANAKO|090-7777-8888|third-party@example.test'
    )
    where id=v_extraction;
    raise exception 'FAIL DD9 quarantine: arbitrary school context string accepted';
  exception when others then
    v_error:=sqlerrm;
    if v_error like 'FAIL DD9 quarantine:%' then raise; end if;
    if v_error not like '%NURSERY_SCHOOL_CONTEXT_ID_INVALID%' then raise; end if;
  end;

  begin
    update private.document_extractions
    set school_context_candidate=jsonb_build_object(
      'child_school_context_id','aaaaaaaa-aaaa-4aaa-8aaa-aaaaaaaaaaaa'
    )
    where id=v_extraction;
    raise exception 'FAIL DD9 quarantine: nonexistent school context accepted';
  exception when others then
    v_error:=sqlerrm;
    if v_error like 'FAIL DD9 quarantine:%' then raise; end if;
    if v_error not like '%NURSERY_CHILD_SCHOOL_SCOPE_REQUIRED%' then raise; end if;
  end;

  begin
    update private.document_extractions
    set school_context_candidate=jsonb_build_object('child_school_context_id',v_foreign_context)
    where id=v_extraction;
    raise exception 'FAIL DD9 quarantine: foreign school context accepted';
  exception when others then
    v_error:=sqlerrm;
    if v_error like 'FAIL DD9 quarantine:%' then raise; end if;
    if v_error not like '%NURSERY_CHILD_SCHOOL_SCOPE_REQUIRED%' then raise; end if;
  end;

  begin
    update private.document_extractions
    set household_id=v_other_household,
        source_document_id=v_direct_doc,
        school_context_candidate=jsonb_build_object('child_school_context_id',v_foreign_context)
    where id=v_extraction;
    raise exception 'FAIL DD9 quarantine: extraction scope/provenance update accepted';
  exception when others then
    v_error:=sqlerrm;
    if v_error like 'FAIL DD9 quarantine:%' then raise; end if;
    if v_error not like '%NURSERY_EXTRACTION_SOURCE_SCOPE_MISMATCH%'
       and v_error not like '%NURSERY_EXTRACTION_PROVENANCE_IMMUTABLE%' then raise; end if;
  end;

  -- HIGH 3: 693 legal symbols = 11 item codes x 21 quantity states x 3
  -- confidence bands.  The multiset space C(756,64) exceeds 2^312, so every
  -- arbitrary 39-byte value has a reversible order-independent encoding.
  if pg_temp.dd9_binom(756,64)<=power(2::numeric,312) then
    raise exception 'FAIL DD9 quarantine: multiset capacity fixture invalid';
  end if;

  v_secret:=convert_to(rpad(
    'YAMADA|09077778888|third-party@example.test|',39,'X'
  ),'UTF8');
  if length(v_secret)<>39 then raise exception 'FAIL DD9 quarantine: secret1 not 39 bytes'; end if;
  v_rank:=pg_temp.dd9_bytes_to_numeric(v_secret);
  v_symbols:=pg_temp.dd9_unrank_multiset(v_rank,693,64);
  if cardinality(v_symbols)<>64 or pg_temp.dd9_rank_multiset(v_symbols,693)<>v_rank then
    raise exception 'FAIL DD9 quarantine: multiset rank/unrank is not reversible';
  end if;
  v_roundtrip:=pg_temp.dd9_numeric_to_bytes(pg_temp.dd9_rank_multiset(v_symbols,693),39);
  if v_roundtrip<>v_secret then
    raise exception 'FAIL DD9 quarantine: multiset did not reconstruct secret byte-for-byte';
  end if;

  foreach v_symbol in array v_symbols loop
    v_item_idx:=v_symbol/(21*3);
    v_quantity_idx:=(v_symbol%(21*3))/3;
    v_conf_idx:=v_symbol%3;
    v_normalized:=jsonb_build_object('item_code',v_item_codes[v_item_idx+1]);
    if v_quantity_idx>0 then
      v_normalized:=v_normalized||jsonb_build_object('quantity',v_quantity_idx);
    end if;
    v_confidence:=case v_conf_idx when 0 then 'high' when 1 then 'medium' else 'low' end;
    v_facts:=v_facts||jsonb_build_array(jsonb_build_object(
      'child_school_context_id',v_context_b,
      'fact_kind','required_item',
      'normalized_value',v_normalized,
      'confidence_band',v_confidence
    ));
  end loop;

  v_review:=private.fn_command_record_nursery_extraction_v1(
    v_household,v_owner,v_actor,null,
    '58000000-0000-0000-0000-000000000102',v_extraction,1,
    jsonb_build_object('child_school_context_id',v_context_b),
    v_facts,'[]'::jsonb,'pwa'
  );
  if v_review->>'state'<>'review' or (v_review->>'source_fact_count')::integer<>64
     or (v_review->>'durable_source_fact_slots')::integer<>64
     or (v_review->>'durable_ai_candidate_slots')::integer<>32
     or v_review->>'structured_persistence'<>'withheld_untrusted_r0' then
    raise exception 'FAIL DD9 quarantine: ordinary hostile multiset did not reach review boundary: %',v_review;
  end if;

  if not exists(
    select 1 from private.document_extractions e
    where e.id=v_extraction
      and e.school_context_candidate->>'child_school_context_id'=v_expected_context::text
      and e.school_context_candidate->>'reason_code'='trusted_source_binding_required'
  ) then raise exception 'FAIL DD9 quarantine: durable school context was model-selected'; end if;

  select count(*)::integer into v_count from private.document_facts where extraction_id=v_extraction;
  if v_count<>64 then raise exception 'FAIL DD9 quarantine: fact quarantine cardinality is %, expected 64',v_count; end if;
  if exists(
    select 1 from private.document_facts f
    where f.extraction_id=v_extraction
      and (
        f.pre_review_slot not between 1 and 64
        or f.child_school_context_id is distinct from v_expected_context
        or f.fact_kind<>'event'
        or f.normalized_value<>jsonb_build_object(
          'event_type','food_education','all_day',true,'review_required',true,
          'value_kind','r0_untrusted_source_fact_withheld'
        )
        or f.confidence_band<>'low'
        or f.source_locator is not null
      )
  ) then raise exception 'FAIL DD9 quarantine: model-controlled fact tuple survived'; end if;

  select count(*)::integer into v_count from public.change_candidates c
  where c.source_type='ai_inference' and c.source_ref=v_extraction::text;
  if v_count<>32 then raise exception 'FAIL DD9 quarantine: candidate quarantine cardinality is %, expected 32',v_count; end if;

  -- A second, different 39-byte multiset must result in exactly the same
  -- durable fact/candidate semantics (server ids/timestamps/source_ref excluded).
  v_secret2:=convert_to(rpad(
    'OTHER|08099998888|different@example.test|',39,'Z'
  ),'UTF8');
  if length(v_secret2)<>39 or v_secret2=v_secret then
    raise exception 'FAIL DD9 quarantine: secret2 fixture invalid';
  end if;
  v_rank2:=pg_temp.dd9_bytes_to_numeric(v_secret2);
  v_symbols2:=pg_temp.dd9_unrank_multiset(v_rank2,693,64);
  if pg_temp.dd9_numeric_to_bytes(pg_temp.dd9_rank_multiset(v_symbols2,693),39)<>v_secret2 then
    raise exception 'FAIL DD9 quarantine: second multiset not reversible';
  end if;
  foreach v_symbol in array v_symbols2 loop
    v_item_idx:=v_symbol/(21*3);
    v_quantity_idx:=(v_symbol%(21*3))/3;
    v_conf_idx:=v_symbol%3;
    v_normalized:=jsonb_build_object('item_code',v_item_codes[v_item_idx+1]);
    if v_quantity_idx>0 then v_normalized:=v_normalized||jsonb_build_object('quantity',v_quantity_idx); end if;
    v_confidence:=case v_conf_idx when 0 then 'high' when 1 then 'medium' else 'low' end;
    v_facts2:=v_facts2||jsonb_build_array(jsonb_build_object(
      'child_school_context_id',v_context_a,'fact_kind','required_item',
      'normalized_value',v_normalized,'confidence_band',v_confidence
    ));
  end loop;

  v_intake2:=private.fn_command_create_nursery_intake_v1(
    v_household,v_owner,v_actor,null,
    '58000000-0000-0000-0000-000000000103','codmon_notice',
    'private/dd9/SECOND-SECRET/PII','2178-01-01 01:02+09','second-secret-v1',
    jsonb_build_object('provider','test'),'pwa'
  );
  v_doc2:=(v_intake2->>'source_document_id')::uuid;
  v_extraction2:=(v_intake2->>'extraction_id')::uuid;
  perform private.fn_command_record_nursery_extraction_v1(
    v_household,v_owner,v_actor,null,
    '58000000-0000-0000-0000-000000000104',v_extraction2,1,
    jsonb_build_object('child_school_context_id',v_context_a),v_facts2,'[]'::jsonb,'pwa'
  );

  select jsonb_agg(jsonb_build_object(
    'slot',f.pre_review_slot,'context',f.child_school_context_id,'kind',f.fact_kind,
    'value',f.normalized_value,'confidence',f.confidence_band,
    'locator',f.source_locator,'origin',f.fact_origin
  ) order by f.pre_review_slot) into v_snap1
  from private.document_facts f where f.extraction_id=v_extraction;
  select jsonb_agg(jsonb_build_object(
    'slot',f.pre_review_slot,'context',f.child_school_context_id,'kind',f.fact_kind,
    'value',f.normalized_value,'confidence',f.confidence_band,
    'locator',f.source_locator,'origin',f.fact_origin
  ) order by f.pre_review_slot) into v_snap2
  from private.document_facts f where f.extraction_id=v_extraction2;
  if v_snap1 is distinct from v_snap2 then
    raise exception 'FAIL DD9 quarantine: different secrets produced different durable fact multisets';
  end if;

  select jsonb_agg(jsonb_build_object(
    'slot',c.nursery_pre_review_slot,'type',c.target_type,'target',c.target_id,
    'patch',c.proposed_patch,'hash',c.current_snapshot_hash,'status',c.status,'revision',c.revision
  ) order by c.nursery_pre_review_slot) into v_candidate_snap1
  from public.change_candidates c
  where c.source_type='ai_inference' and c.source_ref=v_extraction::text;
  select jsonb_agg(jsonb_build_object(
    'slot',c.nursery_pre_review_slot,'type',c.target_type,'target',c.target_id,
    'patch',c.proposed_patch,'hash',c.current_snapshot_hash,'status',c.status,'revision',c.revision
  ) order by c.nursery_pre_review_slot) into v_candidate_snap2
  from public.change_candidates c
  where c.source_type='ai_inference' and c.source_ref=v_extraction2::text;
  if v_candidate_snap1 is distinct from v_candidate_snap2 then
    raise exception 'FAIL DD9 quarantine: different secrets produced different durable candidate multisets';
  end if;

  -- Direct service-role attempts cannot change tuple state, cardinality, or slots.
  select id into v_fact_id from private.document_facts
  where extraction_id=v_extraction and pre_review_slot=1;
  update private.document_facts
  set fact_kind='required_item',
      normalized_value=jsonb_build_object('item_code','wipes','quantity',20),
      confidence_band='high',source_locator='item:65535'
  where id=v_fact_id;
  if not exists(
    select 1 from private.document_facts f
    where f.id=v_fact_id and f.fact_kind='event' and f.confidence_band='low'
      and f.source_locator is null and f.normalized_value->>'value_kind'='r0_untrusted_source_fact_withheld'
  ) then raise exception 'FAIL DD9 quarantine: service-role fact UPDATE changed fixed slot'; end if;

  begin
    insert into private.document_facts(
      household_id,extraction_id,child_school_context_id,fact_kind,normalized_value,
      confidence_band,source_locator,fact_origin,test_context_id,pre_review_slot
    ) values(v_household,v_extraction,v_expected_context,'event','{}','low',null,'source_explicit',null,1);
    raise exception 'FAIL DD9 quarantine: extra fact slot inserted';
  exception when others then
    v_error:=sqlerrm;
    if v_error like 'FAIL DD9 quarantine:%' then raise; end if;
  end;

  begin
    delete from private.document_facts where id=v_fact_id;
    raise exception 'FAIL DD9 quarantine: fixed fact slot deleted';
  exception when others then
    v_error:=sqlerrm;
    if v_error like 'FAIL DD9 quarantine:%' then raise; end if;
    if v_error not like '%NURSERY_DOCUMENT_FACT_DELETE_DISABLED_R0%' then raise; end if;
  end;

  select id into v_candidate_id from public.change_candidates
  where source_type='ai_inference' and source_ref=v_extraction::text and nursery_pre_review_slot=1;
  update public.change_candidates
  set target_type='task',target_id=v_child,
      proposed_patch=jsonb_build_object('scheduled_date','2179-01-01','title','YAMADA'),
      current_snapshot_hash=repeat('41',32),status='stale',revision=65535
  where id=v_candidate_id;
  if not exists(
    select 1 from public.change_candidates c
    where c.id=v_candidate_id and c.target_type='info' and c.target_id is null
      and c.current_snapshot_hash is null and c.status='pending' and c.revision=1
      and c.proposed_patch->>'value_kind'='r0_untrusted_ai_candidate_withheld'
  ) then raise exception 'FAIL DD9 quarantine: service-role candidate UPDATE changed fixed slot'; end if;

  begin
    insert into public.change_candidates(
      household_id,target_type,source_type,source_ref,proposed_patch,status,test_context_id
    ) values(v_household,'task','ai_inference',v_extraction::text,jsonb_build_object('title','YAMADA'),'pending',null);
    raise exception 'FAIL DD9 quarantine: unslotted nursery candidate inserted';
  exception when others then
    v_error:=sqlerrm;
    if v_error like 'FAIL DD9 quarantine:%' then raise; end if;
    if v_error not like '%NURSERY_CHANGE_CANDIDATE_SLOT_REQUIRED_R0%' then raise; end if;
  end;

  begin
    delete from public.change_candidates where id=v_candidate_id;
    raise exception 'FAIL DD9 quarantine: fixed candidate slot deleted';
  exception when others then
    v_error:=sqlerrm;
    if v_error like 'FAIL DD9 quarantine:%' then raise; end if;
    if v_error not like '%NURSERY_CHANGE_CANDIDATE_DELETE_DISABLED_R0%' then raise; end if;
  end;
end;
$$;

reset role;
select '58_dd9_r0_trusted_quarantine_boundary: PASS' as result;
