-- DD9 regression: table-boundary minimization must remain active when lineage
-- or scope columns are modified together with a structured value.
\set ON_ERROR_STOP on
set role service_role;

do $$
declare
  v_owner uuid:='57000000-0000-0000-0000-000000000001';
  v_other_owner uuid:='57000000-0000-0000-0000-000000000002';
  v_household uuid; v_other_household uuid; v_actor uuid;
  v_child uuid; v_context uuid; v_intake jsonb; v_review jsonb;
  v_extraction uuid; v_fact uuid; v_candidate uuid; v_error text;
begin
  insert into auth.users(id) values(v_owner),(v_other_owner) on conflict do nothing;
  insert into public.profiles(user_id,display_name)
  values(v_owner,'Scope guard owner'),(v_other_owner,'Scope guard peer')
  on conflict do nothing;

  v_household:=(public.server_tx_create_household(
    v_owner,'57000000-0000-0000-0000-000000000010','Scope guard household','Asia/Tokyo'
  )->>'household_id')::uuid;
  v_other_household:=(public.server_tx_create_household(
    v_other_owner,'57000000-0000-0000-0000-000000000011','Scope guard peer household','Asia/Tokyo'
  )->>'household_id')::uuid;

  select id into v_actor from public.domain_actor_refs
  where household_id=v_household and actor_kind='real_user' and real_user_id=v_owner;

  insert into public.family_children(household_id,display_name)
  values(v_household,'Scope guard child') returning id into v_child;
  insert into public.child_school_contexts(
    household_id,child_id,school_display_name,class_display_name,effective_from,recognition_aliases
  ) values(v_household,v_child,'Scope school','そら組','2030-01-01',array['そら組'])
  returning id into v_context;

  v_intake:=private.fn_command_create_nursery_intake_v1(
    v_household,v_owner,v_actor,null,'57000000-0000-0000-0000-000000000101',
    'codmon_notice','private/dd9/scope-guard','2030-01-01 09:00+09','scope-guard-v1',
    jsonb_build_object('provider','test'),'pwa'
  );
  v_extraction:=(v_intake->>'extraction_id')::uuid;

  v_review:=private.fn_command_record_nursery_extraction_v1(
    v_household,v_owner,v_actor,null,'57000000-0000-0000-0000-000000000102',
    v_extraction,1,jsonb_build_object('child_school_context_id',v_context),
    jsonb_build_array(jsonb_build_object(
      'child_school_context_id',v_context,'fact_kind','event',
      'normalized_value',jsonb_build_object('event_type','食育','date','2030-01-02','all_day',true),
      'confidence_band','high'
    )),
    jsonb_build_array(jsonb_build_object(
      'child_school_context_id',v_context,'target_type','task',
      'proposed_patch',jsonb_build_object('scheduled_date','2030-01-02'),
      'explanation','scope guard candidate'
    )),'pwa'
  );
  if v_review->>'state'<>'review' then raise exception 'FAIL scope guard fixture'; end if;

  select id into v_fact from private.document_facts where extraction_id=v_extraction limit 1;
  select id into v_candidate from public.change_candidates
  where household_id=v_household and source_type='ai_inference' and source_ref=v_extraction::text limit 1;

  begin
    update private.document_facts
    set household_id=v_other_household,child_school_context_id=null,
        normalized_value=jsonb_build_object('event_type','food_education','date','2179-01-01','all_day',true)
    where id=v_fact;
    raise exception 'FAIL scope guard fact update accepted';
  exception when others then
    v_error:=sqlerrm;
    if v_error like 'FAIL scope guard%' then raise; end if;
    if v_error not like '%NURSERY_DOCUMENT_FACT_SCOPE_MISMATCH%' then raise; end if;
  end;

  begin
    update public.change_candidates
    set source_type='manual_import',source_ref='changed-source',
        proposed_patch=jsonb_build_object('scheduled_date','2179-01-01')
    where id=v_candidate;
    raise exception 'FAIL scope guard candidate provenance update accepted';
  exception when others then
    v_error:=sqlerrm;
    if v_error like 'FAIL scope guard%' then raise; end if;
    if v_error not like '%NURSERY_CHANGE_CANDIDATE_PROVENANCE_IMMUTABLE%' then raise; end if;
  end;

  begin
    update public.change_candidates
    set household_id=v_other_household,
        proposed_patch=jsonb_build_object('scheduled_date','2179-01-01')
    where id=v_candidate;
    raise exception 'FAIL scope guard candidate scope update accepted';
  exception when others then
    v_error:=sqlerrm;
    if v_error like 'FAIL scope guard%' then raise; end if;
    if v_error not like '%NURSERY_CHANGE_CANDIDATE_SCOPE_MISMATCH%' then raise; end if;
  end;

  if not exists(select 1 from private.document_facts f where f.id=v_fact and f.household_id=v_household and not(f.normalized_value?'date')) then
    raise exception 'FAIL scope guard fact row changed';
  end if;
  if not exists(select 1 from public.change_candidates c where c.id=v_candidate and c.household_id=v_household
    and c.source_type='ai_inference' and c.source_ref=v_extraction::text
    and not(c.proposed_patch?'scheduled_date')) then
    raise exception 'FAIL scope guard candidate row changed';
  end if;
end;
$$;

reset role;
select '57_dd9_pre_review_scope_guard: PASS' as result;