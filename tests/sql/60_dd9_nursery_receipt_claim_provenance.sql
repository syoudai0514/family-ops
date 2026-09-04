-- DD9 R0 receipt claim provenance regression.
-- A validly scoped service_role must not be able to persist arbitrary text in a
-- nursery.extraction.record request_hash by direct INSERT, generic-helper use, or
-- non-nursery -> nursery relabeling.  The ordinary canonical command path must still
-- create a server-derived digest and preserve exact idempotent replay.
\set ON_ERROR_STOP on
set role service_role;

do $$
declare
  v_owner uuid := '60000000-0000-0000-0000-000000000001';
  v_household uuid;
  v_actor uuid;
  v_child uuid;
  v_school_context uuid;
  v_intake jsonb;
  v_extraction uuid;
  v_school jsonb;
  v_review jsonb;
  v_replay jsonb;
  v_operation uuid := '60000000-0000-0000-0000-000000000102';
  v_direct_operation uuid := '60000000-0000-0000-0000-000000000190';
  v_relabel_operation uuid := '60000000-0000-0000-0000-000000000191';
  v_helper_operation uuid := '60000000-0000-0000-0000-000000000192';
  v_relabel_receipt uuid;
  v_error text;
  v_hash text;
  v_expected_hash text;
  v_hostile text := 'YAMADA HANAKO|09077778888|third-party@example.test|arbitrary-pre-review-content';
begin
  insert into auth.users(id) values(v_owner) on conflict do nothing;
  insert into public.profiles(user_id,display_name)
  values(v_owner,'DD9 claim provenance owner') on conflict do nothing;

  v_household := (public.server_tx_create_household(
    v_owner,
    '60000000-0000-0000-0000-000000000010',
    'DD9 claim provenance household',
    'Asia/Tokyo'
  )->>'household_id')::uuid;

  select id into v_actor
  from public.domain_actor_refs
  where household_id=v_household
    and actor_kind='real_user'
    and real_user_id=v_owner;

  insert into public.family_children(household_id,display_name)
  values(v_household,'Claim provenance child')
  returning id into v_child;

  insert into public.child_school_contexts(
    household_id,child_id,school_display_name,class_display_name,effective_from,recognition_aliases
  ) values(
    v_household,v_child,'Claim provenance school','R','2030-01-01',array['R']
  ) returning id into v_school_context;

  v_intake := private.fn_command_create_nursery_intake_v1(
    v_household,v_owner,v_actor,null,
    '60000000-0000-0000-0000-000000000101',
    'codmon_notice','caller-key','2179-01-01 01:02+09',
    'claim-provenance-test',jsonb_build_object('provider','test'),'pwa'
  );
  v_extraction := (v_intake->>'extraction_id')::uuid;
  v_school := jsonb_build_object('child_school_context_id',v_school_context);

  -- HIGH regression: valid scope + exact nursery action + hostile request_hash
  -- must fail at the durable table boundary.
  begin
    insert into private.canonical_operation_receipts(
      household_id,operator_user_id,actor_ref_id,test_context_id,
      operation_id,action_type,request_hash
    ) values(
      v_household,v_owner,v_actor,null,
      v_direct_operation,'nursery.extraction.record',v_hostile
    );
    raise exception 'FAIL DD9 claim provenance: direct hostile nursery receipt INSERT accepted';
  exception when others then
    v_error := sqlerrm;
    if v_error like 'FAIL DD9 claim provenance:%' then raise; end if;
    if v_error not like '%NURSERY_OPERATION_RECEIPT_DIRECT_INSERT_FORBIDDEN%' then
      raise;
    end if;
  end;

  if exists(
    select 1 from private.canonical_operation_receipts
    where actor_ref_id=v_actor and operation_id=v_direct_operation
  ) then
    raise exception 'FAIL DD9 claim provenance: rejected direct INSERT left durable receipt';
  end if;

  -- The generic claim primitive itself is no longer an RPC surface for
  -- service_role.  Otherwise the SECURITY DEFINER helper would turn a direct call
  -- into an owner-context INSERT and bypass the table guard.
  if has_function_privilege(
    'service_role',
    'private.fn_claim_canonical_operation_v1(uuid,uuid,uuid,uuid,uuid,text,text)',
    'EXECUTE'
  ) then
    raise exception 'FAIL DD9 claim provenance: generic claim helper still executable by service_role';
  end if;

  begin
    perform private.fn_claim_canonical_operation_v1(
      v_household,v_owner,v_actor,null,v_helper_operation,
      'nursery.extraction.record',v_hostile
    );
    raise exception 'FAIL DD9 claim provenance: direct generic helper bypass accepted';
  exception when others then
    v_error := sqlerrm;
    if v_error like 'FAIL DD9 claim provenance:%' then raise; end if;
    if v_error not like '%permission denied%fn_claim_canonical_operation_v1%' then
      raise;
    end if;
  end;

  -- Minting a non-nursery receipt first and relabeling it must not bypass the
  -- INSERT guard.
  insert into private.canonical_operation_receipts(
    household_id,operator_user_id,actor_ref_id,test_context_id,
    operation_id,action_type,request_hash
  ) values(
    v_household,v_owner,v_actor,null,
    v_relabel_operation,'task.complete',v_hostile
  ) returning id into v_relabel_receipt;

  begin
    update private.canonical_operation_receipts
    set action_type='nursery.extraction.record'
    where id=v_relabel_receipt;
    raise exception 'FAIL DD9 claim provenance: non-nursery -> nursery relabel bypass accepted';
  exception when others then
    v_error := sqlerrm;
    if v_error like 'FAIL DD9 claim provenance:%' then raise; end if;
    if v_error not like '%NURSERY_OPERATION_RECEIPT_RELABEL_FORBIDDEN%' then
      raise;
    end if;
  end;
  delete from private.canonical_operation_receipts where id=v_relabel_receipt;

  -- Ordinary canonical command still works.  It runs as SECURITY DEFINER,
  -- derives the request digest from the canonical request, and creates the receipt
  -- through the now-internal claim helper.
  v_review := private.fn_command_record_nursery_extraction_v1(
    v_household,v_owner,v_actor,null,v_operation,v_extraction,1,
    v_school,'[]'::jsonb,'[]'::jsonb,'pwa'
  );

  v_expected_hash := private.fn_canonical_request_hash_v1(jsonb_build_object(
    'extraction_id',v_extraction,
    'expected_revision',1,
    'school_context_candidate',v_school,
    'source_facts','[]'::jsonb,
    'ai_candidates','[]'::jsonb,
    'source','pwa'
  ));

  select request_hash into v_hash
  from private.canonical_operation_receipts
  where actor_ref_id=v_actor
    and operation_id=v_operation
    and action_type='nursery.extraction.record';

  if v_hash is null
     or v_hash !~ '^[0-9a-f]{64}$'
     or v_hash is distinct from v_expected_hash
     or v_hash like '%YAMADA%'
     or v_hash like '%09077778888%'
     or v_hash like '%third-party%' then
    raise exception 'FAIL DD9 claim provenance: canonical command did not persist server-derived digest: %',v_hash;
  end if;

  v_replay := private.fn_command_record_nursery_extraction_v1(
    v_household,v_owner,v_actor,null,v_operation,v_extraction,1,
    v_school,'[]'::jsonb,'[]'::jsonb,'pwa'
  );
  if v_replay is distinct from v_review then
    raise exception 'FAIL DD9 claim provenance: exact idempotent replay changed';
  end if;
end;
$$;
reset role;
select '60_dd9_nursery_receipt_claim_provenance: PASS' as result;
