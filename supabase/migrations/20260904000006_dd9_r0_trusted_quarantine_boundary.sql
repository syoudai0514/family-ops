-- DD9 final R0 privacy hardening after integrated independent re-review.
--
-- R0 does not yet have an independently reviewed server-side parser/token
-- inventory that can attest model-selected nursery facts.  Therefore model
-- payloads are validated for shape but MUST NOT determine pre-review durable
-- structured state.  This migration:
--   * replaces caller-controlled Storage keys with server-issued opaque keys;
--   * binds document_extractions to their source-document scope and makes the
--     school-context candidate server-selected from an active household context;
--   * represents document facts as exactly 64 DB-issued quarantine slots whose
--     values are constant and cannot be inserted/deleted/relabelled by service_role;
--   * represents nursery AI candidates as exactly 32 DB-issued quarantine slots
--     with constant review-only values and immutable provenance;
--   * keeps the submitted model payload only in the command request hash/raw
--     evidence boundary, never in the pre-review structured tables.
--
-- No OCR/AI/Storage adapter, P1 reader/writer, LINE delivery, Google mutation,
-- or production activation is enabled here.

alter table private.document_facts
  add column pre_review_slot smallint null;

alter table public.change_candidates
  add column nursery_pre_review_slot smallint null;

-- ---------------------------------------------------------------------------
-- source_documents: object identity is server-issued, not caller-minted.
-- ---------------------------------------------------------------------------

update private.source_documents
set storage_object_key='nursery-r0/'||id::text,
    retention_policy='short_lived';

alter table private.source_documents
  add constraint source_documents_r0_object_key_v1_chk
    check (storage_object_key='nursery-r0/'||id::text),
  add constraint source_documents_document_kind_v1_chk
    check (document_kind in (
      'codmon_notice','nursery_notice','monthly_schedule','school_notice','other_notice'
    )),
  add constraint source_documents_retention_r0_v1_chk
    check (retention_policy='short_lived');

create or replace function private.fn_guard_nursery_source_document_r0_v1()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  if tg_op='INSERT' then
    if new.document_kind not in (
      'codmon_notice','nursery_notice','monthly_schedule','school_notice','other_notice'
    ) then
      raise exception 'NURSERY_DOCUMENT_INPUT_INVALID';
    end if;
    -- Ignore every caller-provided technical identity.  The row id and object
    -- key are minted together at the durable boundary.
    new.id:=gen_random_uuid();
    new.storage_object_key:='nursery-r0/'||new.id::text;
    new.uploaded_at:=statement_timestamp();
    new.captured_at:=new.uploaded_at;
    new.raw_deleted_at:=null;
    new.retention_policy:='short_lived';
    return new;
  end if;

  if new.id is distinct from old.id
     or new.household_id is distinct from old.household_id
     or new.uploaded_by_actor_ref_id is distinct from old.uploaded_by_actor_ref_id
     or new.document_kind is distinct from old.document_kind
     or new.storage_object_key is distinct from old.storage_object_key
     or new.retention_policy is distinct from old.retention_policy
     or new.test_context_id is distinct from old.test_context_id then
    raise exception 'NURSERY_SOURCE_DOCUMENT_PROVENANCE_IMMUTABLE';
  end if;

  new.id:=old.id;
  new.household_id:=old.household_id;
  new.uploaded_by_actor_ref_id:=old.uploaded_by_actor_ref_id;
  new.document_kind:=old.document_kind;
  new.storage_object_key:=old.storage_object_key;
  new.uploaded_at:=old.uploaded_at;
  new.captured_at:=old.uploaded_at;
  new.retention_policy:='short_lived';
  new.test_context_id:=old.test_context_id;
  if old.raw_deleted_at is null and new.raw_deleted_at is not null then
    new.raw_deleted_at:=statement_timestamp();
  else
    new.raw_deleted_at:=old.raw_deleted_at;
  end if;
  return new;
end;
$$;
revoke all on function private.fn_guard_nursery_source_document_r0_v1()
  from public,anon,authenticated,service_role;

drop trigger if exists source_documents_r0_trusted_identity_v1 on private.source_documents;
create trigger source_documents_r0_trusted_identity_v1
before insert or update on private.source_documents
for each row execute function private.fn_guard_nursery_source_document_r0_v1();

-- ---------------------------------------------------------------------------
-- document_extractions: source scope is immutable.  A submitted school-context
-- id must be a real same-household active UUID, but the durable context is
-- selected deterministically by the DB so the model cannot choose among ids.
-- ---------------------------------------------------------------------------

create or replace function private.fn_guard_nursery_extraction_r0_v1()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  v_doc_household uuid;
  v_doc_test_context uuid;
  v_requested_context_text text;
  v_requested_context uuid;
  v_server_context uuid;
begin
  select d.household_id,d.test_context_id
    into v_doc_household,v_doc_test_context
  from private.source_documents d
  where d.id=new.source_document_id;
  if not found then
    raise exception 'NURSERY_SOURCE_DOCUMENT_NOT_FOUND';
  end if;
  if new.household_id is distinct from v_doc_household
     or new.test_context_id is distinct from v_doc_test_context then
    raise exception 'NURSERY_EXTRACTION_SOURCE_SCOPE_MISMATCH';
  end if;

  v_requested_context_text:=nullif(
    btrim(coalesce(new.school_context_candidate->>'child_school_context_id','')),''
  );
  if v_requested_context_text is not null then
    begin
      v_requested_context:=v_requested_context_text::uuid;
    exception when others then
      raise exception 'NURSERY_SCHOOL_CONTEXT_ID_INVALID';
    end;
    if not exists (
      select 1 from public.child_school_contexts s
      where s.id=v_requested_context
        and s.household_id=v_doc_household
        and s.active
    ) then
      raise exception 'NURSERY_CHILD_SCHOOL_SCOPE_REQUIRED';
    end if;
  end if;

  select s.id into v_server_context
  from public.child_school_contexts s
  where s.household_id=v_doc_household and s.active
  order by s.id::text
  limit 1;

  if tg_op='INSERT' then
    new.id:=gen_random_uuid();
    new.extraction_version:='pre_review_minimized_v3';
    new.provider_metadata:=private.fn_minimize_nursery_provider_metadata_v3(
      coalesce(new.provider_metadata,'{}'::jsonb)
    );
    new.school_context_candidate:=null;
    new.state:='processing';
    new.revision:=1;
    new.created_at:=statement_timestamp();
    new.updated_at:=new.created_at;
    return new;
  end if;

  if new.id is distinct from old.id
     or new.household_id is distinct from old.household_id
     or new.source_document_id is distinct from old.source_document_id
     or new.test_context_id is distinct from old.test_context_id then
    raise exception 'NURSERY_EXTRACTION_PROVENANCE_IMMUTABLE';
  end if;

  new.id:=old.id;
  new.household_id:=old.household_id;
  new.source_document_id:=old.source_document_id;
  new.test_context_id:=old.test_context_id;
  new.extraction_version:='pre_review_minimized_v3';
  new.provider_metadata:=private.fn_minimize_nursery_provider_metadata_v3(
    coalesce(new.provider_metadata,'{}'::jsonb)
  );
  new.created_at:=old.created_at;
  new.updated_at:=statement_timestamp();
  if new.revision is distinct from old.revision then
    new.revision:=old.revision+1;
  else
    new.revision:=old.revision;
  end if;

  if new.state='review' or new.school_context_candidate is not null then
    new.school_context_candidate:=jsonb_build_object(
      'review_required',true,
      'reason_code','trusted_source_binding_required'
    );
    if v_server_context is not null then
      new.school_context_candidate:=new.school_context_candidate||
        jsonb_build_object('child_school_context_id',v_server_context);
    end if;
  else
    new.school_context_candidate:=null;
  end if;
  return new;
end;
$$;
revoke all on function private.fn_guard_nursery_extraction_r0_v1()
  from public,anon,authenticated,service_role;

drop trigger if exists document_extractions_r0_trusted_boundary_v1
  on private.document_extractions;
create trigger document_extractions_r0_trusted_boundary_v1
before insert or update on private.document_extractions
for each row execute function private.fn_guard_nursery_extraction_r0_v1();

-- ---------------------------------------------------------------------------
-- document_facts: exactly 64 constant DB-issued quarantine slots/extraction.
-- The model cannot choose the row count, tuple multiset, confidence, locator,
-- ordering slot, context id, timestamps, or any other durable fact field.
-- ---------------------------------------------------------------------------

create or replace function private.fn_minimize_nursery_document_fact_value_v1()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  v_extraction_household uuid;
  v_extraction_test_context uuid;
  v_server_context uuid;
begin
  select e.household_id,e.test_context_id
    into v_extraction_household,v_extraction_test_context
  from private.document_extractions e
  where e.id=new.extraction_id;
  if not found then
    raise exception 'NURSERY_DOCUMENT_FACT_EXTRACTION_NOT_FOUND';
  end if;
  if v_extraction_household is distinct from new.household_id
     or v_extraction_test_context is distinct from new.test_context_id then
    raise exception 'NURSERY_DOCUMENT_FACT_SCOPE_MISMATCH';
  end if;

  if tg_op='UPDATE' then
    if new.id is distinct from old.id
       or new.extraction_id is distinct from old.extraction_id
       or new.pre_review_slot is distinct from old.pre_review_slot then
      raise exception 'NURSERY_DOCUMENT_FACT_PROVENANCE_IMMUTABLE';
    end if;
    new.id:=old.id;
    new.pre_review_slot:=old.pre_review_slot;
    new.created_at:=old.created_at;
  else
    if new.pre_review_slot is null or new.pre_review_slot not between 1 and 64 then
      raise exception 'NURSERY_DOCUMENT_FACT_SLOT_REQUIRED_R0';
    end if;
  end if;

  select s.id into v_server_context
  from public.child_school_contexts s
  where s.household_id=v_extraction_household and s.active
  order by s.id::text
  limit 1;

  new.household_id:=v_extraction_household;
  new.test_context_id:=v_extraction_test_context;
  new.child_school_context_id:=v_server_context;
  new.fact_kind:='event';
  new.normalized_value:=jsonb_build_object(
    'event_type','food_education',
    'all_day',true,
    'review_required',true,
    'value_kind','r0_untrusted_source_fact_withheld'
  );
  new.confidence_band:='low';
  new.source_locator:=null;
  new.fact_origin:='source_explicit';
  return new;
end;
$$;
revoke all on function private.fn_minimize_nursery_document_fact_value_v1()
  from public,anon,authenticated,service_role;

drop trigger if exists document_facts_minimize_value_update_v1 on private.document_facts;
create trigger document_facts_minimize_value_update_v1
before update on private.document_facts
for each row execute function private.fn_minimize_nursery_document_fact_value_v1();

create or replace function private.fn_block_nursery_document_fact_delete_r0_v1()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  raise exception 'NURSERY_DOCUMENT_FACT_DELETE_DISABLED_R0';
end;
$$;
revoke all on function private.fn_block_nursery_document_fact_delete_r0_v1()
  from public,anon,authenticated,service_role;

-- Existing pre-review structured facts are not trusted under the new boundary.
delete from private.document_facts;

insert into private.document_facts(
  household_id,extraction_id,child_school_context_id,fact_kind,normalized_value,
  confidence_band,source_locator,fact_origin,test_context_id,pre_review_slot
)
select e.household_id,e.id,null,'event','{}'::jsonb,'low',null,'source_explicit',e.test_context_id,g
from private.document_extractions e
cross join generate_series(1,64) g;

alter table private.document_facts
  alter column pre_review_slot set not null,
  add constraint document_facts_pre_review_slot_v1_chk
    check (pre_review_slot between 1 and 64);
create unique index document_facts_pre_review_slots_v1
  on private.document_facts(extraction_id,pre_review_slot);

drop trigger if exists document_facts_block_delete_r0_v1 on private.document_facts;
create trigger document_facts_block_delete_r0_v1
before delete on private.document_facts
for each row execute function private.fn_block_nursery_document_fact_delete_r0_v1();

-- ---------------------------------------------------------------------------
-- Nursery change_candidates: exactly 32 constant DB-issued quarantine slots.
-- Generic non-nursery change candidates remain unaffected.
-- ---------------------------------------------------------------------------

create or replace function private.fn_minimize_nursery_change_candidate_pre_review_v1()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  v_old_linked boolean:=false;
  v_new_linked boolean:=false;
  v_extraction_household uuid;
  v_extraction_test_context uuid;
  v_server_context uuid;
  v_patch jsonb;
begin
  if tg_op='UPDATE' then
    v_old_linked:=old.nursery_pre_review_slot is not null
      or (
        old.source_type='ai_inference'
        and exists(select 1 from private.document_extractions e where e.id::text=old.source_ref)
      );
  end if;

  if new.source_type='ai_inference' and nullif(btrim(coalesce(new.source_ref,'')),'') is not null then
    select e.household_id,e.test_context_id
      into v_extraction_household,v_extraction_test_context
    from private.document_extractions e
    where e.id::text=new.source_ref;
    if found then v_new_linked:=true; end if;
  end if;

  if tg_op='UPDATE' and v_old_linked then
    if new.source_type is distinct from old.source_type
       or new.source_ref is distinct from old.source_ref
       or new.test_context_id is distinct from old.test_context_id then
      raise exception 'NURSERY_CHANGE_CANDIDATE_PROVENANCE_IMMUTABLE';
    end if;
    select e.household_id,e.test_context_id
      into v_extraction_household,v_extraction_test_context
    from private.document_extractions e
    where e.id::text=old.source_ref;
    v_new_linked:=true;
  end if;

  if not v_new_linked then
    return new;
  end if;

  if v_extraction_household is distinct from new.household_id
     or v_extraction_test_context is distinct from new.test_context_id then
    raise exception 'NURSERY_CHANGE_CANDIDATE_SCOPE_MISMATCH';
  end if;

  if tg_op='INSERT' then
    if new.nursery_pre_review_slot is null
       or new.nursery_pre_review_slot not between 1 and 32 then
      raise exception 'NURSERY_CHANGE_CANDIDATE_SLOT_REQUIRED_R0';
    end if;
    new.id:=gen_random_uuid();
    new.created_at:=statement_timestamp();
  else
    if new.id is distinct from old.id
       or new.nursery_pre_review_slot is distinct from old.nursery_pre_review_slot then
      raise exception 'NURSERY_CHANGE_CANDIDATE_PROVENANCE_IMMUTABLE';
    end if;
    new.id:=old.id;
    new.nursery_pre_review_slot:=old.nursery_pre_review_slot;
    new.created_at:=old.created_at;
  end if;

  select s.id into v_server_context
  from public.child_school_contexts s
  where s.household_id=v_extraction_household and s.active
  order by s.id::text
  limit 1;

  v_patch:=jsonb_build_object(
    'review_required',true,
    'origin_label','ai_inference',
    'reason_code','trusted_source_binding_required',
    'value_kind','r0_untrusted_ai_candidate_withheld'
  );
  if v_server_context is not null then
    v_patch:=v_patch||jsonb_build_object('child_school_context_id',v_server_context);
  end if;

  new.household_id:=v_extraction_household;
  new.target_type:='info';
  new.target_id:=null;
  new.source_type:='ai_inference';
  new.proposed_patch:=v_patch;
  new.current_snapshot_hash:=null;
  new.status:='pending';
  new.resolved_at:=null;
  new.resolved_by_actor_ref_id:=null;
  new.revision:=1;
  new.test_context_id:=v_extraction_test_context;
  new.updated_at:=statement_timestamp();
  return new;
end;
$$;
revoke all on function private.fn_minimize_nursery_change_candidate_pre_review_v1()
  from public,anon,authenticated,service_role;

drop trigger if exists change_candidates_minimize_nursery_pre_review_update_v1
  on public.change_candidates;
create trigger change_candidates_minimize_nursery_pre_review_update_v1
before update on public.change_candidates
for each row execute function private.fn_minimize_nursery_change_candidate_pre_review_v1();

create or replace function private.fn_block_nursery_change_candidate_delete_r0_v1()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  if old.nursery_pre_review_slot is not null
     or (
       old.source_type='ai_inference'
       and exists(select 1 from private.document_extractions e where e.id::text=old.source_ref)
     ) then
    raise exception 'NURSERY_CHANGE_CANDIDATE_DELETE_DISABLED_R0';
  end if;
  return old;
end;
$$;
revoke all on function private.fn_block_nursery_change_candidate_delete_r0_v1()
  from public,anon,authenticated,service_role;

-- Remove model-selected nursery candidates persisted by earlier review heads.
delete from public.change_candidates c
using private.document_extractions e
where c.source_type='ai_inference' and c.source_ref=e.id::text;

insert into public.change_candidates(
  household_id,target_type,target_id,source_type,source_ref,proposed_patch,
  current_snapshot_hash,status,test_context_id,nursery_pre_review_slot
)
select e.household_id,'info',null,'ai_inference',e.id::text,'{}'::jsonb,
       null,'pending',e.test_context_id,g
from private.document_extractions e
cross join generate_series(1,32) g;

alter table public.change_candidates
  add constraint change_candidates_nursery_slot_v1_chk
    check (nursery_pre_review_slot is null or nursery_pre_review_slot between 1 and 32);
create unique index change_candidates_nursery_slots_v1
  on public.change_candidates(household_id,source_ref,nursery_pre_review_slot)
  where source_type='ai_inference' and nursery_pre_review_slot is not null;

drop trigger if exists change_candidates_block_nursery_delete_r0_v1
  on public.change_candidates;
create trigger change_candidates_block_nursery_delete_r0_v1
before delete on public.change_candidates
for each row execute function private.fn_block_nursery_change_candidate_delete_r0_v1();

-- ---------------------------------------------------------------------------
-- Every new extraction receives its complete quarantine representation before
-- a model payload can be recorded.  Slot cardinality is therefore DB-issued.
-- ---------------------------------------------------------------------------

create or replace function private.fn_seed_nursery_r0_quarantine_slots_v1()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  insert into private.document_facts(
    household_id,extraction_id,child_school_context_id,fact_kind,normalized_value,
    confidence_band,source_locator,fact_origin,test_context_id,pre_review_slot
  )
  select new.household_id,new.id,null,'event','{}'::jsonb,'low',null,'source_explicit',new.test_context_id,g
  from generate_series(1,64) g;

  insert into public.change_candidates(
    household_id,target_type,target_id,source_type,source_ref,proposed_patch,
    current_snapshot_hash,status,test_context_id,nursery_pre_review_slot
  )
  select new.household_id,'info',null,'ai_inference',new.id::text,'{}'::jsonb,
         null,'pending',new.test_context_id,g
  from generate_series(1,32) g;
  return new;
end;
$$;
revoke all on function private.fn_seed_nursery_r0_quarantine_slots_v1()
  from public,anon,authenticated,service_role;

drop trigger if exists document_extractions_seed_r0_quarantine_slots_v1
  on private.document_extractions;
create trigger document_extractions_seed_r0_quarantine_slots_v1
after insert on private.document_extractions
for each row execute function private.fn_seed_nursery_r0_quarantine_slots_v1();

-- Normalize existing extraction context candidates through the new boundary.
update private.document_extractions
set school_context_candidate=school_context_candidate;

-- ---------------------------------------------------------------------------
-- Ordinary extraction command: validate the submitted model payload exactly as
-- before, but never use it to create/update the quarantine slots.  Input counts
-- remain compatibility telemetry only; durable structured rows are fixed 64/32.
-- ---------------------------------------------------------------------------

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
  v_result jsonb;
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

  v_result:=jsonb_build_object(
    'extraction_id',p_extraction_id,
    'state','review',
    'revision',v_revision,
    'source_fact_count',v_fact_count,
    'ai_candidate_count',v_candidate_count,
    'durable_source_fact_slots',64,
    'durable_ai_candidate_slots',32,
    'structured_persistence','withheld_untrusted_r0',
    'side_effects','none'
  );
  perform private.fn_complete_canonical_operation_v1(
    v_receipt_id,'document_extraction',p_extraction_id,v_result
  );
  return v_result;
end;
$$;

revoke all on function private.fn_command_record_nursery_extraction_v1(
  uuid,uuid,uuid,uuid,uuid,uuid,bigint,jsonb,jsonb,jsonb,text
) from public,anon,authenticated;
grant execute on function private.fn_command_record_nursery_extraction_v1(
  uuid,uuid,uuid,uuid,uuid,uuid,bigint,jsonb,jsonb,jsonb,text
) to service_role;
