-- DD9: explicit source facts and AI inference remain separate, scoped, and
-- review-only.  This test uses no storage adapter, AI provider, Google call,
-- or production notification.
\set ON_ERROR_STOP on
set role service_role;

do $$
declare
  v_owner uuid:='10000000-0000-0000-0000-000000000047';
  v_household uuid; v_actor uuid; v_child uuid; v_context uuid;
  v_intake jsonb; v_review jsonb; v_rule jsonb; v_extraction uuid; v_doc uuid;
begin
  insert into auth.users(id) values(v_owner) on conflict do nothing;
  insert into public.profiles(user_id,display_name) values(v_owner,'DD9 owner') on conflict do nothing;
  v_household:=(public.server_tx_create_household(v_owner,'20000000-0000-0000-0000-000000000047','DD9 household','Asia/Tokyo')->>'household_id')::uuid;
  select id into v_actor from public.domain_actor_refs
  where household_id=v_household and actor_kind='real_user' and real_user_id=v_owner;
  insert into public.family_children(household_id,display_name) values(v_household,'対象児') returning id into v_child;
  insert into public.child_school_contexts(household_id,child_id,school_display_name,class_display_name,effective_from,recognition_aliases)
  values(v_household,v_child,'DD9園','ひかり組','2030-01-01',array['ひかり組']) returning id into v_context;

  v_intake:=private.fn_command_create_nursery_intake_v1(
    v_household,v_owner,v_actor,null,'20000000-0000-0000-0000-000000000147',
    'codmon_notice','private/dd9/opaque-object-key','2030-02-01 09:00+09','dd9-test-v1',jsonb_build_object('provider','test'),'pwa'
  );
  v_doc:=(v_intake->>'source_document_id')::uuid;
  v_extraction:=(v_intake->>'extraction_id')::uuid;
  v_review:=private.fn_command_record_nursery_extraction_v1(
    v_household,v_owner,v_actor,null,'20000000-0000-0000-0000-000000000247',v_extraction,1,
    jsonb_build_object('child_school_context_id',v_context),
    jsonb_build_array(jsonb_build_object('child_school_context_id',v_context,'fact_kind','required_item','normalized_value',jsonb_build_object('item','エプロン'),'confidence_band','high','source_locator','p1')),
    jsonb_build_array(jsonb_build_object('child_school_context_id',v_context,'target_type','task','proposed_patch',jsonb_build_object('title','前夜に準備'),'explanation','家庭での準備提案')),
    'pwa'
  );
  if v_review->>'state'<>'review' or v_review->>'side_effects'<>'none' then raise exception 'FAIL DD9: intake left review-only pipeline'; end if;
  if not exists(select 1 from private.document_facts where extraction_id=v_extraction and fact_origin='source_explicit' and child_school_context_id=v_context) then raise exception 'FAIL DD9: source fact missing/scope lost'; end if;
  if not exists(select 1 from public.change_candidates where household_id=v_household and source_type='ai_inference' and source_ref=v_extraction::text and status='pending') then raise exception 'FAIL DD9: AI inference did not remain candidate'; end if;
  if exists(select 1 from public.task_instances where household_id=v_household)
     or exists(select 1 from public.family_events where household_id=v_household)
     or exists(select 1 from public.user_notifications where household_id=v_household) then
    raise exception 'FAIL DD9: extraction caused business/notification side effect'; end if;
  v_rule:=private.fn_command_confirm_school_preparation_rule_v1(
    v_household,v_owner,v_actor,null,'20000000-0000-0000-0000-000000000347',v_context,
    jsonb_build_object('event_type','食育'),jsonb_build_object('item','エプロン'),'2030-02-01',null,'pwa'
  );
  if v_rule->>'confirmed'<>'true' then raise exception 'FAIL DD9: explicit preparation-rule confirmation failed'; end if;
  update private.source_documents set raw_deleted_at=now() where id=v_doc;
  if not exists(select 1 from private.document_facts where extraction_id=v_extraction)
     or not exists(select 1 from public.school_preparation_rules where id=(v_rule->>'school_preparation_rule_id')::uuid) then
    raise exception 'FAIL DD9: raw deletion removed confirmed structured history'; end if;
end;
$$;

reset role;
select '47_dd9_nursery_intake_pipeline: PASS' as result;
