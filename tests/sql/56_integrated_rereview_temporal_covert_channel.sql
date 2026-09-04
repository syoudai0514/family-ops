-- Integrated source re-review remediation regression for DD9.
-- HIGH: parseable date/time/timestamptz values are not trusted provenance.  This
-- test proves a real 128-byte reversible channel through 64 individually valid
-- event dates, then requires the ordinary intake/review path and all durable
-- table boundaries to remove those caller/model temporal cells.
\set ON_ERROR_STOP on
set role service_role;

do $$
declare
  v_owner uuid:='56000000-0000-0000-0000-000000000001';
  v_household uuid; v_actor uuid; v_child uuid; v_context uuid;
  v_intake jsonb; v_review jsonb; v_doc uuid; v_extraction uuid;
  v_secret bytea; v_roundtrip bytea; v_cells jsonb; v_facts jsonb; v_ai jsonb;
  v_encoded integer; v_date date; v_count integer; g integer;
  v_fact_ids uuid[]:='{}'::uuid[];
  v_hostile_capture timestamptz:='2179-01-01 12:34:56+09'::timestamptz;
begin
  insert into auth.users(id) values(v_owner) on conflict do nothing;
  insert into public.profiles(user_id,display_name)
  values(v_owner,'Temporal rereview owner') on conflict do nothing;

  v_household:=(public.server_tx_create_household(
    v_owner,'56000000-0000-0000-0000-000000000010',
    'Temporal rereview household','Asia/Tokyo'
  )->>'household_id')::uuid;

  select id into v_actor
  from public.domain_actor_refs
  where household_id=v_household and actor_kind='real_user' and real_user_id=v_owner;

  insert into public.family_children(household_id,display_name)
  values(v_household,'Temporal target child') returning id into v_child;

  insert into public.child_school_contexts(
    household_id,child_id,school_display_name,class_display_name,
    effective_from,recognition_aliases
  ) values (
    v_household,v_child,'Temporal school','あお組','2030-01-01',array['あお組']
  ) returning id into v_context;

  -- 64 date cells x 16 controlled bits = 128 reversible bytes.  Every cell is
  -- a valid PostgreSQL date between 2000 and ~2179.
  v_secret:=convert_to(rpad(
    'YAMADA-HANAKO|090-7777-8888|temporal-channel@example.test|THIRD-PARTY-PII|',
    128,'T'
  ),'UTF8');
  if length(v_secret)<>128 then
    raise exception 'FAIL temporal rereview: covert fixture is not 128 bytes';
  end if;

  select jsonb_agg(to_jsonb(
    get_byte(v_secret,(n-1)*2)*256 + get_byte(v_secret,(n-1)*2+1)
  ) order by n)
  into v_cells
  from generate_series(1,64) n;

  if jsonb_array_length(v_cells)<>64 then
    raise exception 'FAIL temporal rereview: expected 64 encoded cells';
  end if;

  -- Prove the hostile dates alone reconstruct the original bytes before any
  -- persistence.  n = stored_date - 2000-01-01.
  select decode(string_agg(
    lpad(to_hex(((date '2000-01-01'+((c.value#>>'{}')::integer))-date '2000-01-01')::integer),4,'0'),
    '' order by c.ordinality
  ),'hex')
  into v_roundtrip
  from jsonb_array_elements(v_cells) with ordinality as c(value,ordinality);

  if v_roundtrip<>v_secret then
    raise exception 'FAIL temporal rereview: date channel fixture is not reversible';
  end if;

  select jsonb_agg(jsonb_build_object(
    'child_school_context_id',v_context,
    'fact_kind','event',
    'normalized_value',jsonb_build_object(
      'event_type','食育',
      'date',(date '2000-01-01'+((c.value#>>'{}')::integer))::text,
      'all_day',true
    ),
    'confidence_band','high'
  ) order by c.ordinality)
  into v_facts
  from jsonb_array_elements(v_cells) with ordinality as c(value,ordinality);

  -- Exercise every model-supplied temporal surface in the AI patch minimizer.
  v_ai:=jsonb_build_array(
    jsonb_build_object(
      'child_school_context_id',v_context,'target_type','task',
      'proposed_patch',jsonb_build_object(
        'scheduled_date','2179-01-01','due_at','2179-01-01T01:02:03+09:00',
        'calendar_ends_at','2179-01-01T04:05:06+09:00'
      ),'explanation','temporal task candidate'
    ),
    jsonb_build_object(
      'child_school_context_id',v_context,'target_type','family_event',
      'proposed_patch',jsonb_build_object(
        'all_day',true,'start_date','2178-12-30','end_date','2179-01-02',
        'starts_at','2178-12-30T08:00:00+09:00','ends_at','2179-01-02T18:00:00+09:00'
      ),'explanation','temporal event candidate'
    ),
    jsonb_build_object(
      'child_school_context_id',v_context,'target_type','recurrence',
      'proposed_patch',jsonb_build_object(
        'rrule','FREQ=WEEKLY;INTERVAL=63;BYDAY=MO,TU,WE,TH,FR;UNTIL=21790101',
        'effective_from','2178-01-01','effective_to','2179-01-01'
      ),'explanation','temporal recurrence candidate'
    ),
    jsonb_build_object(
      'child_school_context_id',v_context,'target_type','info',
      'proposed_patch',jsonb_build_object(
        'effective_from','2178-02-03','effective_to','2179-04-05'
      ),'explanation','temporal info candidate'
    )
  );

  v_intake:=private.fn_command_create_nursery_intake_v1(
    v_household,v_owner,v_actor,null,
    '56000000-0000-0000-0000-000000000101',
    'codmon_notice','private/dd9/temporal-rereview',v_hostile_capture,
    'temporal-review-v1',jsonb_build_object('provider','test'),'pwa'
  );
  v_doc:=(v_intake->>'source_document_id')::uuid;
  v_extraction:=(v_intake->>'extraction_id')::uuid;

  -- Caller-supplied capture time must already be replaced with a server-issued
  -- timestamp at the source-document table boundary.
  if not exists (
    select 1 from private.source_documents d
    where d.id=v_doc and d.captured_at=d.uploaded_at and d.captured_at is distinct from v_hostile_capture
  ) then
    raise exception 'FAIL temporal rereview: caller captured_at survived intake';
  end if;

  v_review:=private.fn_command_record_nursery_extraction_v1(
    v_household,v_owner,v_actor,null,
    '56000000-0000-0000-0000-000000000102',v_extraction,1,
    jsonb_build_object(
      'child_school_context_id',v_context,
      'school_display_name','Temporal school',
      'class_display_name','あお組',
      'effective_from','2178-01-01',
      'effective_to','2179-01-01'
    ),
    v_facts,v_ai,'pwa'
  );

  if v_review->>'state'<>'review'
     or (v_review->>'source_fact_count')::integer<>64
     or (v_review->>'ai_candidate_count')::integer<>4 then
    raise exception 'FAIL temporal rereview: hostile payload did not reach normal review boundary: %',v_review;
  end if;

  select array_agg(id order by id),count(*)::integer
  into v_fact_ids,v_count
  from private.document_facts
  where extraction_id=v_extraction;
  if v_count<>64 then
    raise exception 'FAIL temporal rereview: expected 64 durable facts, got %',v_count;
  end if;

  if exists (
    select 1 from private.document_facts f
    where f.extraction_id=v_extraction
      and (
        f.normalized_value ? 'date' or f.normalized_value ? 'start_date'
        or f.normalized_value ? 'end_date' or f.normalized_value ? 'time'
        or f.normalized_value ? 'until'
      )
  ) then
    raise exception 'FAIL temporal rereview: source temporal scalar survived durable minimization';
  end if;

  if not exists (
    select 1 from private.document_facts f
    where f.extraction_id=v_extraction
      and f.normalized_value->>'event_type'='food_education'
      and f.normalized_value->>'all_day'='true'
  ) then
    raise exception 'FAIL temporal rereview: low-cardinality event semantics were lost';
  end if;

  if exists (
    select 1 from private.document_extractions e
    where e.id=v_extraction
      and (e.school_context_candidate ? 'effective_from' or e.school_context_candidate ? 'effective_to')
  ) then
    raise exception 'FAIL temporal rereview: school-context temporal scalar survived';
  end if;
  if not exists (
    select 1 from private.document_extractions e
    where e.id=v_extraction
      and e.school_context_candidate->>'child_school_context_id'=v_context::text
  ) then
    raise exception 'FAIL temporal rereview: trusted household child context was lost';
  end if;

  if exists (
    select 1 from public.change_candidates c
    where c.source_type='ai_inference' and c.source_ref=v_extraction::text
      and (
        c.proposed_patch ? 'scheduled_date' or c.proposed_patch ? 'due_at'
        or c.proposed_patch ? 'calendar_ends_at' or c.proposed_patch ? 'start_date'
        or c.proposed_patch ? 'end_date' or c.proposed_patch ? 'starts_at'
        or c.proposed_patch ? 'ends_at' or c.proposed_patch ? 'effective_from'
        or c.proposed_patch ? 'effective_to' or c.proposed_patch ? 'rrule'
      )
  ) then
    raise exception 'FAIL temporal rereview: AI temporal scalar survived durable minimization';
  end if;

  -- Defense in depth: attempt to re-inject the exact 64 hostile date cells via
  -- service-role UPDATE.  The table trigger must minimize every row again.
  for g in 1..64 loop
    v_encoded:=(v_cells->>(g-1))::integer;
    v_date:=date '2000-01-01'+v_encoded;
    update private.document_facts
    set normalized_value=jsonb_build_object(
      'event_type','food_education','date',v_date::text,'all_day',true
    )
    where id=v_fact_ids[g];
  end loop;

  if exists (
    select 1 from private.document_facts f
    where f.extraction_id=v_extraction and f.normalized_value ? 'date'
  ) then
    raise exception 'FAIL temporal rereview: service-role UPDATE reopened 64-date channel';
  end if;

  update private.document_extractions
  set school_context_candidate=school_context_candidate||jsonb_build_object(
    'effective_from','2178-01-01','effective_to','2179-01-01'
  )
  where id=v_extraction;
  if exists (
    select 1 from private.document_extractions e
    where e.id=v_extraction
      and (e.school_context_candidate ? 'effective_from' or e.school_context_candidate ? 'effective_to')
  ) then
    raise exception 'FAIL temporal rereview: school-context UPDATE reopened temporal channel';
  end if;

  update public.change_candidates
  set proposed_patch=proposed_patch||jsonb_build_object(
    'scheduled_date','2179-01-01',
    'due_at','2179-01-01T01:02:03+09:00',
    'starts_at','2179-01-01T02:03:04+09:00',
    'effective_from','2178-01-01',
    'effective_to','2179-01-01',
    'rrule','FREQ=DAILY;INTERVAL=63;UNTIL=21790101'
  )
  where source_type='ai_inference' and source_ref=v_extraction::text;

  if exists (
    select 1 from public.change_candidates c
    where c.source_type='ai_inference' and c.source_ref=v_extraction::text
      and (
        c.proposed_patch ? 'scheduled_date' or c.proposed_patch ? 'due_at'
        or c.proposed_patch ? 'starts_at' or c.proposed_patch ? 'effective_from'
        or c.proposed_patch ? 'effective_to' or c.proposed_patch ? 'rrule'
      )
  ) then
    raise exception 'FAIL temporal rereview: candidate UPDATE reopened temporal channel';
  end if;

  update private.source_documents set captured_at=v_hostile_capture where id=v_doc;
  if not exists (
    select 1 from private.source_documents d
    where d.id=v_doc and d.captured_at=d.uploaded_at and d.captured_at is distinct from v_hostile_capture
  ) then
    raise exception 'FAIL temporal rereview: source-document UPDATE reopened captured_at channel';
  end if;
end;
$$;

reset role;
select '56_integrated_rereview_temporal_covert_channel: PASS' as result;