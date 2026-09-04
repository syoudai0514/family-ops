-- Final table-boundary defense for DD9 pre-review minimization.
--
-- The temporal minimizers already remove caller/model controlled dates, times,
-- timestamps, RRULEs, technical identifiers, locators, and free text from the
-- ordinary nursery intake/review path.  This migration closes a privileged
-- scope-smuggling edge at the durable boundary: a service-role write must not
-- be able to change lineage/scope columns in the same statement as a hostile
-- value and thereby make a conditional minimizer skip the row.
--
-- No production/P1 activation is performed here.

-- ---------------------------------------------------------------------------
-- document_facts is an extraction-backed DD9 evidence table.  extraction_id is
-- NOT NULL, so every INSERT/UPDATE must resolve to the same household/test
-- scope before the normalized value is accepted.  Mismatch fails closed.
-- ---------------------------------------------------------------------------

create or replace function private.fn_minimize_nursery_document_fact_value_v1()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  v_extraction_household_id uuid;
  v_extraction_test_context_id uuid;
begin
  select e.household_id,e.test_context_id
    into v_extraction_household_id,v_extraction_test_context_id
  from private.document_extractions e
  where e.id=new.extraction_id;

  if not found then
    raise exception 'NURSERY_DOCUMENT_FACT_EXTRACTION_NOT_FOUND';
  end if;

  if v_extraction_household_id is distinct from new.household_id
     or v_extraction_test_context_id is distinct from new.test_context_id then
    raise exception 'NURSERY_DOCUMENT_FACT_SCOPE_MISMATCH';
  end if;

  new.normalized_value:=private.fn_minimize_nursery_fact_value_v3(
    new.fact_kind,coalesce(new.normalized_value,'{}'::jsonb)
  );
  return new;
end;
$$;

revoke all on function private.fn_minimize_nursery_document_fact_value_v1()
  from public,anon,authenticated,service_role;

-- Existing triggers from 20260904000004 call the replaced function for INSERT
-- and for updates of household/extraction/fact/value/test scope columns.

-- ---------------------------------------------------------------------------
-- change_candidates is shared, so only candidates linked to a DD9 extraction
-- are minimized.  For a new ai_inference row, an extraction-looking source_ref
-- that resolves to an extraction MUST have matching household/test scope.
-- For an existing nursery candidate, its provenance/scope is immutable; a
-- service-role UPDATE cannot relabel it as manual_import or change source_ref in
-- the same statement as hostile structured data to evade the minimizer.
-- ---------------------------------------------------------------------------

create or replace function private.fn_minimize_nursery_change_candidate_pre_review_v1()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
declare
  v_patch jsonb;
  v_context_id uuid;
  v_linked_new boolean:=false;
  v_linked_old boolean:=false;
  v_extraction_household_id uuid;
  v_extraction_test_context_id uuid;
begin
  if tg_op='UPDATE' then
    v_linked_old:=
      old.source_type='ai_inference'
      and (
        (
          old.proposed_patch->>'origin_label'='ai_inference'
          and old.proposed_patch->>'reason_code'='model_candidate_requires_review'
        )
        or exists (
          select 1 from private.document_extractions e
          where e.id::text=old.source_ref
        )
      );
  end if;

  if new.source_type='ai_inference'
     and nullif(btrim(coalesce(new.source_ref,'')),'') is not null then
    select e.household_id,e.test_context_id
      into v_extraction_household_id,v_extraction_test_context_id
    from private.document_extractions e
    where e.id::text=new.source_ref;

    if found then
      if v_extraction_household_id is distinct from new.household_id
         or v_extraction_test_context_id is distinct from new.test_context_id then
        raise exception 'NURSERY_CHANGE_CANDIDATE_SCOPE_MISMATCH';
      end if;
      v_linked_new:=true;
    end if;
  end if;

  if tg_op='UPDATE' and v_linked_old then
    if new.household_id is distinct from old.household_id
       or new.source_type is distinct from old.source_type
       or new.source_ref is distinct from old.source_ref
       or new.test_context_id is distinct from old.test_context_id then
      raise exception 'NURSERY_CHANGE_CANDIDATE_PROVENANCE_IMMUTABLE';
    end if;
    v_linked_new:=true;
  end if;

  if v_linked_new then
    new.current_snapshot_hash:=null;
    new.target_id:=null;

    v_patch:=private.fn_minimize_nursery_ai_patch_v3(
      new.target_type,coalesce(new.proposed_patch,'{}'::jsonb)
    );

    begin
      v_context_id:=nullif(new.proposed_patch->>'child_school_context_id','')::uuid;
    exception when others then
      v_context_id:=null;
    end;

    if v_context_id is not null and exists (
      select 1 from public.child_school_contexts s
      where s.id=v_context_id
        and s.household_id=new.household_id
        and s.active
    ) then
      v_patch:=v_patch||jsonb_build_object('child_school_context_id',v_context_id);
    end if;

    new.proposed_patch:=v_patch||jsonb_build_object(
      'origin_label','ai_inference',
      'reason_code','model_candidate_requires_review'
    );
  end if;

  return new;
end;
$$;

revoke all on function private.fn_minimize_nursery_change_candidate_pre_review_v1()
  from public,anon,authenticated,service_role;

-- Existing INSERT/UPDATE triggers from 20260904000004 call the replaced
-- function.  No grants are required for trigger invocation.