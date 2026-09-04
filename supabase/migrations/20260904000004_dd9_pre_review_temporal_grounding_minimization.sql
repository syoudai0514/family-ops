-- Final integrated review remediation for DD9 temporal covert channels.
--
-- Parsed temporal syntax is not trusted provenance.  R0 has no server-issued
-- inventory of temporal tokens observed in the raw nursery document, so a
-- model/extractor must not mint arbitrary dates/times/timestamps and have them
-- copied into pre-review durable structured data.  Until a separately reviewed
-- trusted token inventory exists, caller/model supplied temporal scalars are
-- removed at both command minimization and durable table boundaries.
--
-- This migration does not activate OCR/AI/Storage adapters, target apply, P1,
-- production readers/writers, LINE delivery, or Google provider mutation.

-- ---------------------------------------------------------------------------
-- Command minimizers: retain only low-cardinality canonical facts.  These are
-- deliberately idempotent because table triggers re-apply them to already
-- minimized values.
-- ---------------------------------------------------------------------------

create or replace function private.fn_minimize_nursery_school_context_v3(p_value jsonb)
returns jsonb
language plpgsql
immutable
security invoker
set search_path=''
as $$
declare
  v_result jsonb:='{}'::jsonb;
begin
  if p_value is null then return null; end if;
  if p_value ? 'child_school_context_id' then
    v_result:=jsonb_build_object('child_school_context_id',p_value->>'child_school_context_id');
  end if;
  -- effective_from/effective_to are intentionally not durable pre-review.  R0
  -- has no trusted observed-temporal-token inventory against which to ground
  -- model supplied dates.
  return v_result;
end;
$$;

create or replace function private.fn_minimize_nursery_fact_value_v3(
  p_fact_kind text,p_value jsonb
) returns jsonb
language plpgsql
immutable
security invoker
set search_path=''
as $$
declare
  v_result jsonb:='{}'::jsonb;
  v_text text;
  v_quantity integer;
begin
  case p_fact_kind
    when 'event' then
      v_text:=lower(btrim(coalesce(p_value->>'event_type','')));
      v_result:=jsonb_build_object('event_type',case v_text
        when '食育' then 'food_education' when 'food_education' then 'food_education'
        when '保護者会' then 'parent_meeting' when 'parent_meeting' then 'parent_meeting'
        when 'プール' then 'pool' when 'pool' then 'pool'
        when '遠足' then 'outing' when 'outing' then 'outing'
        when '健診' then 'health_check' when 'health_check' then 'health_check'
        when '参観' then 'observation_day' when 'observation_day' then 'observation_day'
        when 'other_review_required' then 'other_review_required'
        else 'other_review_required' end);
      if p_value ? 'all_day' and jsonb_typeof(p_value->'all_day')='boolean' then
        v_result:=v_result||jsonb_build_object('all_day',(p_value->>'all_day')::boolean);
      end if;
      -- date/start_date/end_date are intentionally discarded pre-review.

    when 'required_item' then
      v_text:=lower(btrim(coalesce(p_value->>'item_code',p_value->>'item','')));
      v_result:=jsonb_build_object('item_code',case v_text
        when 'エプロン' then 'apron' when 'apron' then 'apron'
        when 'タオル' then 'towel' when 'towel' then 'towel'
        when '水筒' then 'water_bottle' when 'water bottle' then 'water_bottle' when 'water_bottle' then 'water_bottle'
        when '帽子' then 'hat' when 'hat' then 'hat'
        when '着替え' then 'change_of_clothes' when 'change_of_clothes' then 'change_of_clothes'
        when '上履き' then 'indoor_shoes' when 'indoor_shoes' then 'indoor_shoes'
        when '水着' then 'swimsuit' when 'swimsuit' then 'swimsuit'
        when '水泳帽' then 'swim_cap' when 'swim_cap' then 'swim_cap'
        when 'おむつ' then 'diaper' when 'diaper' then 'diaper'
        when 'おしりふき' then 'wipes' when 'wipes' then 'wipes'
        when 'other_review_required' then 'other_review_required'
        else 'other_review_required' end);
      if p_value ? 'quantity' and jsonb_typeof(p_value->'quantity')='number' then
        begin
          v_quantity:=(p_value->>'quantity')::integer;
          if v_quantity between 1 and 20 then
            v_result:=v_result||jsonb_build_object('quantity',v_quantity);
          end if;
        exception when others then null;
        end;
      end if;
      -- note is intentionally discarded pre-review.

    when 'deadline' then
      v_result:=jsonb_build_object('deadline_kind','other_review_required');
      -- date/time are intentionally discarded pre-review.

    when 'recurrence' then
      v_text:=lower(btrim(coalesce(p_value->>'frequency','')));
      v_result:=jsonb_build_object(
        'frequency',case when v_text in ('daily','weekly','monthly') then v_text else 'other_review_required' end
      );
      v_text:=lower(btrim(coalesce(p_value->>'day_of_week','')));
      if v_text in ('mon','tue','wed','thu','fri','sat','sun') then
        v_result:=v_result||jsonb_build_object('day_of_week',v_text);
      end if;
      -- until is intentionally discarded pre-review.

    when 'url' then
      v_result:=jsonb_build_object('review_required',true,'value_kind','url');

    when 'note' then
      v_result:=jsonb_build_object('review_required',true,'value_kind','note');

    else raise exception 'NURSERY_FACT_KIND_INVALID';
  end case;
  return v_result;
end;
$$;

create or replace function private.fn_minimize_nursery_ai_patch_v3(
  p_target_type text,p_patch jsonb
) returns jsonb
language plpgsql
immutable
security invoker
set search_path=''
as $$
declare
  v_result jsonb:='{}'::jsonb;
  v_rrule text;
  v_frequency text;
begin
  if p_target_type='task' then
    -- scheduled_date/due_at/calendar_ends_at are ungrounded model scalars in R0.
    v_result:=jsonb_build_object('review_required',true);

  elsif p_target_type='family_event' then
    if p_patch ? 'all_day' and jsonb_typeof(p_patch->'all_day')='boolean' then
      v_result:=jsonb_build_object('all_day',(p_patch->>'all_day')::boolean);
    else
      v_result:=jsonb_build_object('review_required',true);
    end if;
    -- start_date/end_date/starts_at/ends_at are intentionally discarded.

  elsif p_target_type='recurrence' then
    v_frequency:=lower(btrim(coalesce(p_patch->>'recurrence_frequency','')));
    if v_frequency not in ('daily','weekly','monthly') then
      v_rrule:=upper(btrim(coalesce(p_patch->>'rrule','')));
      if v_rrule~'^FREQ=DAILY([;].*)?$' then v_frequency:='daily';
      elsif v_rrule~'^FREQ=WEEKLY([;].*)?$' then v_frequency:='weekly';
      elsif v_rrule~'^FREQ=MONTHLY([;].*)?$' then v_frequency:='monthly';
      else v_frequency:=null;
      end if;
    end if;
    if v_frequency is not null then
      v_result:=jsonb_build_object('recurrence_frequency',v_frequency);
    else
      v_result:=jsonb_build_object('review_required',true);
    end if;
    -- Raw RRULE (including UNTIL/INTERVAL/BYDAY) and effective dates are not
    -- durable pre-review because their combinatorial state space is caller controlled.

  elsif p_target_type='info' then
    v_result:=jsonb_build_object('review_required',true);
    -- effective_from/effective_to are intentionally discarded.

  else raise exception 'NURSERY_AI_CANDIDATE_INVALID';
  end if;
  return v_result;
end;
$$;

revoke all on function private.fn_minimize_nursery_school_context_v3(jsonb)
  from public,anon,authenticated,service_role;
revoke all on function private.fn_minimize_nursery_fact_value_v3(text,jsonb)
  from public,anon,authenticated,service_role;
revoke all on function private.fn_minimize_nursery_ai_patch_v3(text,jsonb)
  from public,anon,authenticated,service_role;

-- ---------------------------------------------------------------------------
-- Durable boundary: source-document capture time is caller supplied by the R0
-- intake command today.  Treat it as untrusted until a reviewed adapter can
-- attest it.  uploaded_at/captured_at therefore become the same server-issued
-- timestamp and cannot be changed later by a service-role update.
-- ---------------------------------------------------------------------------

create or replace function private.fn_minimize_nursery_source_document_temporal_v1()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  if tg_op='INSERT' then
    new.uploaded_at:=statement_timestamp();
  else
    new.uploaded_at:=old.uploaded_at;
  end if;
  new.captured_at:=new.uploaded_at;
  return new;
end;
$$;
revoke all on function private.fn_minimize_nursery_source_document_temporal_v1()
  from public,anon,authenticated,service_role;

drop trigger if exists source_documents_minimize_temporal_insert_v1 on private.source_documents;
create trigger source_documents_minimize_temporal_insert_v1
before insert on private.source_documents
for each row execute function private.fn_minimize_nursery_source_document_temporal_v1();

drop trigger if exists source_documents_minimize_temporal_update_v1 on private.source_documents;
create trigger source_documents_minimize_temporal_update_v1
before update of captured_at,uploaded_at on private.source_documents
for each row execute function private.fn_minimize_nursery_source_document_temporal_v1();

-- ---------------------------------------------------------------------------
-- Durable boundary: school-context candidate temporal values.
-- ---------------------------------------------------------------------------

create or replace function private.fn_minimize_nursery_extraction_school_context_v1()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  new.school_context_candidate:=private.fn_minimize_nursery_school_context_v3(new.school_context_candidate);
  return new;
end;
$$;
revoke all on function private.fn_minimize_nursery_extraction_school_context_v1()
  from public,anon,authenticated,service_role;

drop trigger if exists document_extractions_minimize_school_context_insert_v1
  on private.document_extractions;
create trigger document_extractions_minimize_school_context_insert_v1
before insert on private.document_extractions
for each row execute function private.fn_minimize_nursery_extraction_school_context_v1();

drop trigger if exists document_extractions_minimize_school_context_update_v1
  on private.document_extractions;
create trigger document_extractions_minimize_school_context_update_v1
before update of school_context_candidate on private.document_extractions
for each row execute function private.fn_minimize_nursery_extraction_school_context_v1();

-- ---------------------------------------------------------------------------
-- Durable boundary: document fact normalized values.
-- ---------------------------------------------------------------------------

create or replace function private.fn_minimize_nursery_document_fact_value_v1()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  if new.extraction_id is not null
     and exists (
       select 1 from private.document_extractions e
       where e.id=new.extraction_id
         and e.household_id=new.household_id
         and e.test_context_id is not distinct from new.test_context_id
     ) then
    new.normalized_value:=private.fn_minimize_nursery_fact_value_v3(
      new.fact_kind,coalesce(new.normalized_value,'{}'::jsonb)
    );
  end if;
  return new;
end;
$$;
revoke all on function private.fn_minimize_nursery_document_fact_value_v1()
  from public,anon,authenticated,service_role;

drop trigger if exists document_facts_minimize_value_insert_v1 on private.document_facts;
create trigger document_facts_minimize_value_insert_v1
before insert on private.document_facts
for each row execute function private.fn_minimize_nursery_document_fact_value_v1();

drop trigger if exists document_facts_minimize_value_update_v1 on private.document_facts;
create trigger document_facts_minimize_value_update_v1
before update of household_id,extraction_id,fact_kind,normalized_value,test_context_id
on private.document_facts
for each row execute function private.fn_minimize_nursery_document_fact_value_v1();

-- ---------------------------------------------------------------------------
-- Durable boundary: nursery AI candidate proposed_patch.  Extend the existing
-- target/hash minimizer so a future direct service-role insert/update cannot
-- re-open an ungrounded temporal channel through proposed_patch.
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
begin
  if new.source_type='ai_inference'
     and nullif(btrim(coalesce(new.source_ref,'')),'') is not null
     and exists (
       select 1
       from private.document_extractions e
       where e.id::text=new.source_ref
         and e.household_id=new.household_id
         and e.test_context_id is not distinct from new.test_context_id
     ) then
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
      where s.id=v_context_id and s.household_id=new.household_id and s.active
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

drop trigger if exists change_candidates_minimize_nursery_pre_review_insert_v1
  on public.change_candidates;
create trigger change_candidates_minimize_nursery_pre_review_insert_v1
before insert on public.change_candidates
for each row execute function private.fn_minimize_nursery_change_candidate_pre_review_v1();

drop trigger if exists change_candidates_minimize_nursery_pre_review_update_v1
  on public.change_candidates;
create trigger change_candidates_minimize_nursery_pre_review_update_v1
before update of household_id,source_type,source_ref,target_type,proposed_patch,target_id,current_snapshot_hash,test_context_id
on public.change_candidates
for each row execute function private.fn_minimize_nursery_change_candidate_pre_review_v1();

-- ---------------------------------------------------------------------------
-- Scrub values persisted by earlier review heads.  All operations below are
-- idempotent and cross the same triggers installed above.
-- ---------------------------------------------------------------------------

update private.source_documents
set captured_at=uploaded_at;

update private.document_extractions
set school_context_candidate=private.fn_minimize_nursery_school_context_v3(school_context_candidate)
where school_context_candidate is not null;

update private.document_facts f
set normalized_value=private.fn_minimize_nursery_fact_value_v3(f.fact_kind,f.normalized_value)
where f.extraction_id is not null;

update public.change_candidates c
set proposed_patch=c.proposed_patch
where c.source_type='ai_inference'
  and nullif(btrim(coalesce(c.source_ref,'')),'') is not null
  and exists (
    select 1 from private.document_extractions e
    where e.id::text=c.source_ref
      and e.household_id=c.household_id
      and e.test_context_id is not distinct from c.test_context_id
  );