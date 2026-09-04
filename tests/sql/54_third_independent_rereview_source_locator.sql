-- Third independent re-review remediation regression for PR #45.
-- DD9 HIGH: a regex-valid model supplied source_locator must not provide a
-- reversible durable storage channel before human review.
\set ON_ERROR_STOP on
set role service_role;

do $$
declare
  v_owner uuid:='54000000-0000-0000-0000-000000000001';
  v_household uuid; v_owner_ref uuid; v_child uuid; v_context uuid;
  v_intake jsonb; v_extraction uuid; v_facts jsonb; v_review jsonb;
  v_secret bytea; v_roundtrip bytea; v_fact_id uuid; v_count integer;
begin
  insert into auth.users(id) values(v_owner) on conflict do nothing;
  insert into public.profiles(user_id,display_name)
  values(v_owner,'Third rereview owner') on conflict do nothing;

  v_household:=(public.server_tx_create_household(
    v_owner,'54000000-0000-0000-0000-000000000010',
    'Third rereview household','Asia/Tokyo'
  )->>'household_id')::uuid;

  select id into v_owner_ref
  from public.domain_actor_refs
  where household_id=v_household
    and actor_kind='real_user'
    and real_user_id=v_owner;

  insert into public.family_children(household_id,display_name)
  values(v_household,'DD9 locator target child') returning id into v_child;

  insert into public.child_school_contexts(
    household_id,child_id,school_display_name,class_display_name,
    effective_from,recognition_aliases
  ) values (
    v_household,v_child,'DD9 locator school','ひかり組','2030-01-01',array['ひかり組']
  ) returning id into v_context;

  v_intake:=private.fn_command_create_nursery_intake_v1(
    v_household,v_owner,v_owner_ref,null,
    '54000000-0000-0000-0000-000000000101',
    'codmon_notice','private/dd9/third-rereview-object',
    '2030-04-06 09:00+09','third-rereview-v1',
    jsonb_build_object('provider','test'),'pwa'
  );
  v_extraction:=(v_intake->>'extraction_id')::uuid;

  -- 64 regex-valid locators x 16 controlled bits = 128 reversible bytes.
  -- The fixture is ASCII so 128 characters are exactly 128 bytes.
  v_secret:=convert_to(rpad(
    'YAMADA-HANAKO|090-1111-2222|third-party@example.test|OCR-TRANSCRIPT|',
    128,'X'
  ),'UTF8');
  if length(v_secret)<>128 then
    raise exception 'FAIL third rereview DD9: covert locator fixture is not 128 bytes';
  end if;

  select jsonb_agg(jsonb_build_object(
    'child_school_context_id',v_context,
    'fact_kind','required_item',
    'normalized_value',jsonb_build_object('item','エプロン'),
    'confidence_band','high',
    'source_locator','item:'||(
      get_byte(v_secret,(g-1)*2)*256 + get_byte(v_secret,(g-1)*2+1)
    )::text
  ) order by g)
  into v_facts
  from generate_series(1,64) g;

  if jsonb_array_length(v_facts)<>64
     or exists (
       select 1
       from jsonb_array_elements(v_facts) f
       where f->>'source_locator' !~ '^(page|block|line|item):[0-9]{1,5}$'
     ) then
    raise exception 'FAIL third rereview DD9: hostile locator fixture is not regex-valid';
  end if;

  -- Prove the submitted locator numbers are sufficient to reconstruct the
  -- original caller-controlled bytes exactly before persistence.
  select decode(string_agg(
    lpad(to_hex(split_part(f.value->>'source_locator',':',2)::integer),4,'0'),
    '' order by f.ordinality
  ),'hex')
  into v_roundtrip
  from jsonb_array_elements(v_facts) with ordinality as f(value,ordinality);
  if v_roundtrip<>v_secret then
    raise exception 'FAIL third rereview DD9: hostile locator fixture is not reversible';
  end if;

  v_review:=private.fn_command_record_nursery_extraction_v1(
    v_household,v_owner,v_owner_ref,null,
    '54000000-0000-0000-0000-000000000102',
    v_extraction,1,
    jsonb_build_object(
      'child_school_context_id',v_context,
      'school_display_name','DD9 locator school',
      'class_display_name','ひかり組'
    ),
    v_facts,
    '[]'::jsonb,
    'pwa'
  );

  if (v_review->>'source_fact_count')::integer<>64
     or v_review->>'state'<>'review' then
    raise exception 'FAIL third rereview DD9: hostile locator payload did not reach review boundary: %',v_review;
  end if;

  select count(*)::integer into v_count
  from private.document_facts
  where household_id=v_household and extraction_id=v_extraction;
  if v_count<>64 then
    raise exception 'FAIL third rereview DD9: expected 64 durable minimized facts, got %',v_count;
  end if;

  if exists (
    select 1 from private.document_facts
    where household_id=v_household
      and extraction_id=v_extraction
      and source_locator is not null
  ) then
    raise exception 'FAIL third rereview DD9: regex-valid model locator survived durable minimization';
  end if;

  -- Defense in depth: a later service-role UPDATE cannot rehydrate the field
  -- while it remains linked to the document extraction boundary.
  select id into v_fact_id
  from private.document_facts
  where household_id=v_household and extraction_id=v_extraction
  order by created_at,id
  limit 1;

  update private.document_facts
  set source_locator='item:18537'
  where id=v_fact_id;

  if exists (
    select 1 from private.document_facts
    where id=v_fact_id and source_locator is not null
  ) then
    raise exception 'FAIL third rereview DD9: UPDATE reopened source_locator durable channel';
  end if;
end;
$$;

reset role;
select '54_third_independent_rereview_source_locator: PASS' as result;
