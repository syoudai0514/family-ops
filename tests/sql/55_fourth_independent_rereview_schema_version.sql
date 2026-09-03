-- Fourth independent re-review remediation regression for PR #45.
-- DD9 HIGH: caller/model supplied numeric schema_version must not provide a
-- reversible durable storage channel in pre-review document_extractions.
\set ON_ERROR_STOP on
set role service_role;

do $$
declare
  v_owner uuid:='55000000-0000-0000-0000-000000000001';
  v_household uuid; v_owner_ref uuid; v_child uuid; v_context uuid;
  v_secret bytea; v_roundtrip bytea; v_cells jsonb;
  v_intake jsonb; v_review jsonb; v_extraction uuid;
  v_extraction_ids uuid[]:='{}'::uuid[];
  v_encoded_values integer[]:='{}'::integer[];
  v_encoded integer; v_count integer; g integer;
begin
  insert into auth.users(id) values(v_owner) on conflict do nothing;
  insert into public.profiles(user_id,display_name)
  values(v_owner,'Fourth rereview owner') on conflict do nothing;

  v_household:=(public.server_tx_create_household(
    v_owner,'55000000-0000-0000-0000-000000000010',
    'Fourth rereview household','Asia/Tokyo'
  )->>'household_id')::uuid;

  select id into v_owner_ref
  from public.domain_actor_refs
  where household_id=v_household
    and actor_kind='real_user'
    and real_user_id=v_owner;

  insert into public.family_children(household_id,display_name)
  values(v_household,'DD9 schema target child') returning id into v_child;

  insert into public.child_school_contexts(
    household_id,child_id,school_display_name,class_display_name,
    effective_from,recognition_aliases
  ) values (
    v_household,v_child,'DD9 schema school','あお組','2030-01-01',array['あお組']
  ) returning id into v_context;

  -- 64 decimal cells x 16 controlled bits = 128 reversible bytes.  Keep the
  -- fixture ASCII so each character is exactly one byte and every two-byte
  -- value lies inside the accepted 0..65535 / 1-6 digit decimal space.
  v_secret:=convert_to(rpad(
    'YAMADA-HANAKO|090-3333-4444|schema-channel@example.test|THIRD-PARTY-PII|',
    128,'Q'
  ),'UTF8');
  if length(v_secret)<>128 then
    raise exception 'FAIL fourth rereview DD9: covert schema fixture is not 128 bytes';
  end if;

  select jsonb_agg(to_jsonb((
    get_byte(v_secret,(n-1)*2)*256 + get_byte(v_secret,(n-1)*2+1)
  )::text) order by n)
  into v_cells
  from generate_series(1,64) n;

  if jsonb_array_length(v_cells)<>64
     or exists (
       select 1 from jsonb_array_elements(v_cells) c
       where (c#>>'{}') !~ '^[0-9]{1,6}$'
          or (c#>>'{}')::integer not between 0 and 65535
     ) then
    raise exception 'FAIL fourth rereview DD9: hostile schema_version fixture is not individually valid';
  end if;

  -- Prove the submitted decimal cells alone reconstruct the exact original
  -- bytes.  This establishes a real reversible channel before persistence.
  select decode(string_agg(
    lpad(to_hex((c.value#>>'{}')::integer),4,'0'),
    '' order by c.ordinality
  ),'hex')
  into v_roundtrip
  from jsonb_array_elements(v_cells) with ordinality as c(value,ordinality);

  if v_roundtrip<>v_secret then
    raise exception 'FAIL fourth rereview DD9: hostile schema_version fixture is not reversible';
  end if;

  for g in 1..64 loop
    v_encoded:=(v_cells->>(g-1))::integer;
    v_encoded_values:=array_append(v_encoded_values,v_encoded);

    v_intake:=private.fn_command_create_nursery_intake_v1(
      v_household,v_owner,v_owner_ref,null,
      ('55100000-0000-0000-0000-'||lpad(g::text,12,'0'))::uuid,
      'codmon_notice','private/dd9/fourth-rereview-'||g::text,
      '2030-04-07 09:00+09'::timestamptz + make_interval(secs=>g),
      'caller-controlled-extractor-'||g::text,
      jsonb_build_object(
        'provider','test',
        'schema_version',v_encoded::text,
        'model','model-controlled-'||g::text,
        'model_version','version-controlled-'||g::text,
        'extractor_version','extractor-controlled-'||g::text
      ),
      'pwa'
    );
    v_extraction:=(v_intake->>'extraction_id')::uuid;
    v_extraction_ids:=array_append(v_extraction_ids,v_extraction);

    -- Continue through the ordinary extraction review transition rather than
    -- inspecting an artificial direct insert only.
    v_review:=private.fn_command_record_nursery_extraction_v1(
      v_household,v_owner,v_owner_ref,null,
      ('55200000-0000-0000-0000-'||lpad(g::text,12,'0'))::uuid,
      v_extraction,1,
      jsonb_build_object(
        'child_school_context_id',v_context,
        'school_display_name','DD9 schema school',
        'class_display_name','あお組'
      ),
      '[]'::jsonb,
      '[]'::jsonb,
      'pwa'
    );

    if v_review->>'state'<>'review' then
      raise exception 'FAIL fourth rereview DD9: extraction % did not reach review: %',g,v_review;
    end if;
  end loop;

  if cardinality(v_extraction_ids)<>64 then
    raise exception 'FAIL fourth rereview DD9: expected 64 extraction ids';
  end if;

  select count(*)::integer into v_count
  from private.document_extractions d
  where d.id=any(v_extraction_ids)
    and d.state='review'
    and d.extraction_version='pre_review_minimized_v3'
    and d.provider_metadata->>'provider'='test'
    and d.provider_metadata->>'schema_version'='1'
    and d.provider_metadata->>'model_fingerprint'='redacted-pre-review'
    and d.provider_metadata->>'model_version_fingerprint'='redacted-pre-review'
    and d.provider_metadata->>'extractor_version_fingerprint'='redacted-pre-review';

  if v_count<>64 then
    raise exception 'FAIL fourth rereview DD9: not all 64 durable review rows use fixed server metadata, got %',v_count;
  end if;

  -- The original 64 decimal cells must not survive durable metadata.  The
  -- ASCII fixture cannot contain the server marker value 1 as a two-byte cell.
  if exists (
    select 1
    from unnest(v_extraction_ids,v_encoded_values) as f(extraction_id,encoded_value)
    join private.document_extractions d on d.id=f.extraction_id
    where d.provider_metadata->>'schema_version'=f.encoded_value::text
  ) then
    raise exception 'FAIL fourth rereview DD9: caller schema_version survived durable minimization';
  end if;

  -- Defense in depth at the actual table boundary: simulate a later
  -- service-role UPDATE attempting to put every original covert cell back.
  for g in 1..64 loop
    update private.document_extractions
    set provider_metadata=jsonb_set(
      provider_metadata,'{schema_version}',to_jsonb(v_encoded_values[g]::text),true
    )
    where id=v_extraction_ids[g];
  end loop;

  select count(*)::integer into v_count
  from private.document_extractions d
  where d.id=any(v_extraction_ids)
    and d.provider_metadata->>'schema_version'='1';

  if v_count<>64 then
    raise exception 'FAIL fourth rereview DD9: service-role UPDATE reopened schema_version channel, fixed rows=%',v_count;
  end if;

  if exists (
    select 1
    from unnest(v_extraction_ids,v_encoded_values) as f(extraction_id,encoded_value)
    join private.document_extractions d on d.id=f.extraction_id
    where d.provider_metadata->>'schema_version'=f.encoded_value::text
  ) then
    raise exception 'FAIL fourth rereview DD9: original decimal cells were rehydrated after UPDATE';
  end if;
end;
$$;

reset role;
select '55_fourth_independent_rereview_schema_version: PASS' as result;
