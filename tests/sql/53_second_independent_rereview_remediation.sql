-- Second independent re-review remediation regression for PR #45.
-- DD9 HIGH: current_snapshot_hash must not be a reversible covert-storage
-- channel, and model supplied target_id must not become a trusted binding.
-- DD8 MEDIUM is covered by Edge unit tests because the failure is at the
-- Google HTTP contract boundary.
\set ON_ERROR_STOP on
set role service_role;

do $$
declare
  v_owner uuid:='53000000-0000-0000-0000-000000000001';
  v_household uuid; v_owner_ref uuid; v_child uuid; v_context uuid;
  v_intake jsonb; v_extraction uuid; v_candidates jsonb; v_review jsonb;
  v_candidate_id uuid; v_count integer;
begin
  insert into auth.users(id) values(v_owner) on conflict do nothing;
  insert into public.profiles(user_id,display_name)
  values(v_owner,'Second rereview owner') on conflict do nothing;

  v_household:=(public.server_tx_create_household(
    v_owner,'53000000-0000-0000-0000-000000000010',
    'Second rereview household','Asia/Tokyo'
  )->>'household_id')::uuid;

  select id into v_owner_ref
  from public.domain_actor_refs
  where household_id=v_household
    and actor_kind='real_user'
    and real_user_id=v_owner;

  insert into public.family_children(household_id,display_name)
  values(v_household,'DD9 target child') returning id into v_child;

  insert into public.child_school_contexts(
    household_id,child_id,school_display_name,class_display_name,
    effective_from,recognition_aliases
  ) values (
    v_household,v_child,'DD9 school','ひかり組','2030-01-01',array['ひかり組']
  ) returning id into v_context;

  v_intake:=private.fn_command_create_nursery_intake_v1(
    v_household,v_owner,v_owner_ref,null,
    '53000000-0000-0000-0000-000000000101',
    'codmon_notice','private/dd9/second-rereview-object',
    '2030-04-04 09:00+09','second-rereview-v1',
    jsonb_build_object('provider','test'),'pwa'
  );
  v_extraction:=(v_intake->>'extraction_id')::uuid;

  -- 32 candidates x 32 caller-controlled bytes.  Each value is a valid
  -- 64-hex string and is directly reversible with decode(...,'hex').
  select jsonb_agg(jsonb_build_object(
    'child_school_context_id',v_context,
    'target_type','task',
    'target_id',v_child,
    'proposed_patch',jsonb_build_object('scheduled_date','2030-04-05'),
    'explanation','review candidate',
    'current_snapshot_hash',encode(convert_to(
      rpad('YAMADA09011112222-'||lpad(g::text,2,'0'),32,'X'),
      'UTF8'
    ),'hex'),
    'confidence_band','high'
  )) into v_candidates
  from generate_series(1,32) g;

  if jsonb_array_length(v_candidates)<>32
     or length(v_candidates->0->>'current_snapshot_hash')<>64
     or convert_from(decode(v_candidates->0->>'current_snapshot_hash','hex'),'UTF8')
          not like 'YAMADA09011112222-%' then
    raise exception 'FAIL second rereview DD9: hostile reversible hash fixture invalid';
  end if;

  v_review:=private.fn_command_record_nursery_extraction_v1(
    v_household,v_owner,v_owner_ref,null,
    '53000000-0000-0000-0000-000000000102',
    v_extraction,1,
    jsonb_build_object(
      'child_school_context_id',v_context,
      'school_display_name','DD9 school',
      'class_display_name','ひかり組'
    ),
    '[]'::jsonb,
    v_candidates,
    'pwa'
  );

  if (v_review->>'ai_candidate_count')::integer<>32
     or v_review->>'state'<>'review' then
    raise exception 'FAIL second rereview DD9: hostile payload did not reach review boundary: %',v_review;
  end if;

  select count(*)::integer into v_count
  from public.change_candidates
  where household_id=v_household
    and source_type='ai_inference'
    and source_ref=v_extraction::text;
  if v_count<>32 then
    raise exception 'FAIL second rereview DD9: expected 32 durable review markers, got %',v_count;
  end if;

  if exists (
    select 1
    from public.change_candidates
    where household_id=v_household
      and source_type='ai_inference'
      and source_ref=v_extraction::text
      and (current_snapshot_hash is not null or target_id is not null)
  ) then
    raise exception 'FAIL second rereview DD9: model technical field survived durable minimization';
  end if;

  -- Defense in depth: even a later service-role UPDATE cannot rehydrate the
  -- covert field or bind the model-provided UUID while the row remains a
  -- nursery pre-review candidate.
  select id into v_candidate_id
  from public.change_candidates
  where household_id=v_household
    and source_type='ai_inference'
    and source_ref=v_extraction::text
  order by created_at,id
  limit 1;

  update public.change_candidates
  set current_snapshot_hash=repeat('41',32),target_id=v_child
  where id=v_candidate_id;

  if exists (
    select 1 from public.change_candidates
    where id=v_candidate_id
      and (current_snapshot_hash is not null or target_id is not null)
  ) then
    raise exception 'FAIL second rereview DD9: UPDATE reopened minimized technical fields';
  end if;
end;
$$;

reset role;
select '53_second_independent_rereview_remediation: PASS' as result;
