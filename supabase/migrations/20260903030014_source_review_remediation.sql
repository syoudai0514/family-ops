-- Independent source-review remediation for PR #45.
-- Forward-only: PR #44 canonical foundation remains unchanged.
-- This migration activates no P1 capability, provider writer, OCR/AI adapter,
-- Storage worker, LINE delivery, or production reader/writer.

-- ---------------------------------------------------------------------------
-- DD8 HIGH: provider mutation authorization/fencing for ordinary Task mirrors
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_authorize_family_ops_calendar_mirror(
  p_household_id uuid,
  p_projection_key text,
  p_lease_token uuid,
  p_calendar_connection_id uuid,
  p_provider_event_id text
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_mirror private.family_ops_calendar_mirrors%rowtype;
  v_expected_event_id text;
begin
  if p_household_id is null
     or nullif(btrim(coalesce(p_projection_key,'')),'') is null
     or p_lease_token is null
     or p_calendar_connection_id is null
     or nullif(btrim(coalesce(p_provider_event_id,'')),'') is null then
    return jsonb_build_object('authorized',false,'reason','INVALID_PROVIDER_FENCE_INPUT');
  end if;

  -- Lock the same durable owner row that transfer/reclaim paths lock.  This
  -- serializes authorization with a Family Event handoff and with lease reuse.
  select * into v_mirror
  from private.family_ops_calendar_mirrors m
  where m.household_id=p_household_id and m.projection_key=p_projection_key
  for update;

  if not found
     or v_mirror.sync_state<>'processing'
     or v_mirror.lease_token is distinct from p_lease_token
     or v_mirror.lease_until is null
     or v_mirror.lease_until<=now() then
    return jsonb_build_object('authorized',false,'reason','LEASE_OR_JOB_STALE');
  end if;

  if v_mirror.ownership_transfer_state='transferred' then
    return jsonb_build_object('authorized',false,'reason','TASK_MIRROR_TRANSFERRED');
  end if;

  if v_mirror.calendar_connection_id is distinct from p_calendar_connection_id then
    return jsonb_build_object('authorized',false,'reason','PROVIDER_CONNECTION_CHANGED');
  end if;

  v_expected_event_id:=coalesce(
    v_mirror.provider_event_id,
    'fo'||substr(md5(v_mirror.household_id::text||':'||v_mirror.projection_key),1,32)
  );
  if v_expected_event_id is distinct from p_provider_event_id then
    return jsonb_build_object('authorized',false,'reason','PROVIDER_IDENTITY_CHANGED');
  end if;

  -- Ordinary Task-mirror work is only valid on the CURRENT family write
  -- target.  A target change hands cleanup to the dedicated deletion owner.
  if not exists (
    select 1 from public.calendar_connections c
    where c.id=v_mirror.calendar_connection_id
      and c.household_id=v_mirror.household_id
      and c.active and not c.reauth_required and c.is_family_write_target
  ) then
    return jsonb_build_object('authorized',false,'reason','CALENDAR_TARGET_CHANGED');
  end if;

  if exists (
    select 1 from public.family_event_external_links l
    where l.calendar_connection_id=v_mirror.calendar_connection_id
      and l.google_event_id=v_expected_event_id
      and l.ownership_transfer_state in ('validated','active')
  ) then
    return jsonb_build_object('authorized',false,'reason','FAMILY_EVENT_PROVIDER_OWNERSHIP');
  end if;

  if exists (
    select 1 from private.family_ops_calendar_target_deletions d
    where d.calendar_connection_id=v_mirror.calendar_connection_id
      and d.provider_event_id=v_expected_event_id
      and d.ownership_transfer_state='delete_owned'
      and d.sync_state<>'deleted'
  ) then
    return jsonb_build_object('authorized',false,'reason','TARGET_DELETION_PROVIDER_OWNERSHIP');
  end if;

  -- An identity discovered through the orphan inventory cannot be adopted by
  -- inference.  Missing/blocked revalidation is a hard provider-write stop.
  if exists (
    select 1 from private.family_ops_calendar_orphaned_mirrors o
    where o.household_id=v_mirror.household_id
      and o.calendar_connection_id=v_mirror.calendar_connection_id
      and o.provider_event_id=v_expected_event_id
      and (
        o.adoption_blocked
        or o.provider_identity_revalidated_at is null
        or o.provider_revalidated_etag is null
        or (v_mirror.provider_etag is not null
          and o.provider_revalidated_etag is distinct from v_mirror.provider_etag)
      )
  ) then
    return jsonb_build_object('authorized',false,'reason','ORPHAN_PROVIDER_REVALIDATION_REQUIRED');
  end if;

  -- Refresh a short ownership fence immediately before the provider mutation.
  -- Transfer takes the same row lock and refuses a live processing lease, so a
  -- successful authorization cannot be followed by a concurrent handoff in
  -- the normal provider-call window.  An already-expired lease is never revived.
  update private.family_ops_calendar_mirrors
  set lease_until=greatest(lease_until,now()+interval '120 seconds'),updated_at=now()
  where household_id=p_household_id and projection_key=p_projection_key
    and sync_state='processing' and lease_token=p_lease_token
    and ownership_transfer_state<>'transferred'
  returning * into v_mirror;
  if not found then
    return jsonb_build_object('authorized',false,'reason','LEASE_OR_JOB_STALE');
  end if;

  return jsonb_build_object(
    'authorized',true,
    'calendar_connection_id',v_mirror.calendar_connection_id,
    'provider_event_id',v_expected_event_id,
    'lease_until',v_mirror.lease_until
  );
end;
$$;

revoke all on function public.server_tx_authorize_family_ops_calendar_mirror(uuid,text,uuid,uuid,text)
  from public,anon,authenticated;
grant execute on function public.server_tx_authorize_family_ops_calendar_mirror(uuid,text,uuid,uuid,text)
  to service_role;

-- Keep the already-reviewed target-deletion owner semantics, but refresh the
-- same short provider fence on every successful authorization.  The Edge
-- worker re-calls this function before every DELETE, including a 412 retry.
create or replace function public.server_tx_authorize_family_ops_calendar_target_deletion(
  p_id uuid,p_lease_token uuid
) returns jsonb
language plpgsql
security invoker
set search_path=''
as $$
declare v_job private.family_ops_calendar_target_deletions%rowtype;
begin
  select * into v_job from private.family_ops_calendar_target_deletions
  where id=p_id for update;
  if not found or v_job.sync_state<>'processing'
     or v_job.lease_token is distinct from p_lease_token
     or v_job.lease_until is null or v_job.lease_until<=now() then
    return jsonb_build_object('authorized',false,'reason','LEASE_OR_JOB_STALE');
  end if;
  if v_job.ownership_transfer_state<>'delete_owned' or exists (
    select 1 from public.family_event_external_links l
    where l.calendar_connection_id=v_job.calendar_connection_id
      and l.google_event_id=v_job.provider_event_id
      and l.ownership_transfer_state in ('validated','active')
  ) then
    update private.family_ops_calendar_target_deletions
    set ownership_transfer_state='superseded',sync_state='blocked',lease_token=null,lease_until=null,
        ownership_transfer_block_reason='FAMILY_EVENT_PROVIDER_OWNERSHIP',updated_at=now()
    where id=v_job.id;
    return jsonb_build_object('authorized',false,'reason','FAMILY_EVENT_PROVIDER_OWNERSHIP');
  end if;
  update private.family_ops_calendar_target_deletions
  set lease_until=greatest(lease_until,now()+interval '120 seconds'),updated_at=now()
  where id=v_job.id and sync_state='processing' and lease_token=p_lease_token
    and ownership_transfer_state='delete_owned'
  returning * into v_job;
  if not found then return jsonb_build_object('authorized',false,'reason','LEASE_OR_JOB_STALE'); end if;
  return jsonb_build_object('authorized',true,'lease_until',v_job.lease_until);
end;
$$;

-- ---------------------------------------------------------------------------
-- DD10 MEDIUM: completed archive receipt replay survives context archival
-- ---------------------------------------------------------------------------

create or replace function private.fn_replay_completed_test_archive_v1(
  p_household_id uuid,
  p_operator_user_id uuid,
  p_operator_actor_ref_id uuid,
  p_test_context_id uuid,
  p_operation_id uuid,
  p_request_hash text
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_receipt private.canonical_operation_receipts%rowtype;
begin
  -- Replay scope validation deliberately does not require context.status=active.
  -- It still requires the exact real operator ActorRef and exact owned context.
  if not exists (
    select 1 from public.household_members hm
    where hm.household_id=p_household_id and hm.user_id=p_operator_user_id
  ) then raise exception 'ACTOR_NOT_IN_HOUSEHOLD'; end if;
  if not exists (
    select 1 from public.domain_actor_refs a
    where a.household_id=p_household_id and a.id=p_operator_actor_ref_id
      and a.actor_kind='real_user' and a.real_user_id=p_operator_user_id
      and a.test_context_id is null
  ) then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
  if not exists (
    select 1 from public.test_simulation_contexts c
    where c.household_id=p_household_id and c.id=p_test_context_id
      and c.operator_user_id=p_operator_user_id
  ) then raise exception 'TEST_CONTEXT_OPERATOR_MISMATCH'; end if;

  select * into v_receipt
  from private.canonical_operation_receipts r
  where r.actor_ref_id=p_operator_actor_ref_id
    and r.operation_id=p_operation_id
    and r.test_context_id is not distinct from p_test_context_id
  for update;
  if not found then return jsonb_build_object('disposition','none'); end if;
  if v_receipt.household_id is distinct from p_household_id
     or v_receipt.operator_user_id is distinct from p_operator_user_id then
    raise exception 'ACTOR_SCOPE_CONFLICT';
  end if;
  if v_receipt.action_type is distinct from 'test_simulation.archive'
     or v_receipt.request_hash is distinct from p_request_hash then
    raise exception 'IDEMPOTENCY_CONFLICT';
  end if;
  if v_receipt.completed_at is null then raise exception 'OPERATION_IN_PROGRESS'; end if;
  return jsonb_build_object(
    'disposition','replay','receipt_id',v_receipt.id,
    'result_type',v_receipt.result_type,'result_id',v_receipt.result_id,
    'result_payload',v_receipt.result_payload
  );
end;
$$;
revoke all on function private.fn_replay_completed_test_archive_v1(uuid,uuid,uuid,uuid,uuid,text)
  from public,anon,authenticated;
grant execute on function private.fn_replay_completed_test_archive_v1(uuid,uuid,uuid,uuid,uuid,text)
  to service_role;

create or replace function private.fn_command_archive_test_simulation_v1(
  p_household_id uuid,p_operator_user_id uuid,p_operator_actor_ref_id uuid,p_test_context_id uuid,
  p_expected_revision bigint,p_operation_id uuid
) returns jsonb
language plpgsql
security definer
set search_path=''
as $$
declare
  v_claim jsonb; v_replay jsonb; v_receipt_id uuid;
  v_context public.test_simulation_contexts%rowtype; v_result jsonb; v_request_hash text;
begin
  v_request_hash:=private.fn_canonical_request_hash_v1(jsonb_build_object(
    'test_context_id',p_test_context_id,'expected_revision',p_expected_revision
  ));

  -- First, replay only an already-completed exact archive receipt.  Archived
  -- context is acceptable for this one read-only idempotency path.
  v_replay:=private.fn_replay_completed_test_archive_v1(
    p_household_id,p_operator_user_id,p_operator_actor_ref_id,p_test_context_id,
    p_operation_id,v_request_hash
  );
  if v_replay->>'disposition'='replay' then return v_replay->'result_payload'; end if;

  -- No prior completed receipt: use the canonical claim path, which still
  -- requires an active context.  A different operation_id after archive is
  -- therefore rejected with TEST_CONTEXT_NOT_ACTIVE.
  v_claim:=private.fn_claim_canonical_operation_v1(
    p_household_id,p_operator_user_id,p_operator_actor_ref_id,p_test_context_id,p_operation_id,
    'test_simulation.archive',v_request_hash
  );
  if v_claim->>'disposition'='replay' then return v_claim->'result_payload'; end if;
  v_receipt_id:=(v_claim->>'receipt_id')::uuid;
  select * into v_context from public.test_simulation_contexts
  where household_id=p_household_id and id=p_test_context_id for update;
  if not found then raise exception 'TEST_CONTEXT_NOT_FOUND'; end if;
  if v_context.operator_user_id is distinct from p_operator_user_id then raise exception 'TEST_CONTEXT_OPERATOR_MISMATCH'; end if;
  if v_context.revision<>p_expected_revision then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  if v_context.status<>'active' then raise exception 'TEST_CONTEXT_NOT_ACTIVE'; end if;
  update public.test_simulation_contexts
  set status='archived',archived_at=now(),revision=revision+1
  where id=p_test_context_id returning * into v_context;
  v_result:=jsonb_build_object('test_context_id',p_test_context_id,'status','archived',
    'revision',v_context.revision,'production_conversion',false);
  perform private.fn_complete_canonical_operation_v1(
    v_receipt_id,'test_simulation_context',p_test_context_id,v_result
  );
  return v_result;
end;
$$;

-- ---------------------------------------------------------------------------
-- DD9 MEDIUM: typed/minimized durable structured-persistence boundary
-- ---------------------------------------------------------------------------

create or replace function private.fn_nursery_assert_object_allowlist_v2(
  p_value jsonb,p_allowed_keys text[],p_max_bytes integer,p_error text
) returns void
language plpgsql
immutable
security invoker
set search_path=''
as $$
declare v_key text;
begin
  if p_value is null or jsonb_typeof(p_value)<>'object'
     or octet_length(p_value::text)>p_max_bytes then
    raise exception using message=p_error;
  end if;
  for v_key in select jsonb_object_keys(p_value) loop
    if not (v_key=any(p_allowed_keys)) then raise exception using message=p_error; end if;
  end loop;
end;
$$;

create or replace function private.fn_validate_nursery_provider_metadata_v2(p_value jsonb)
returns void language plpgsql immutable security invoker set search_path='' as $$
declare v_key text; v_val jsonb;
begin
  perform private.fn_nursery_assert_object_allowlist_v2(
    coalesce(p_value,'{}'::jsonb),
    array['provider','model','model_version','extractor_version','schema_version'],2048,
    'NURSERY_PROVIDER_METADATA_INVALID'
  );
  for v_key,v_val in select key,value from jsonb_each(coalesce(p_value,'{}'::jsonb)) loop
    if jsonb_typeof(v_val)<>'string' or length(v_val#>>'{}')>160 then
      raise exception 'NURSERY_PROVIDER_METADATA_INVALID';
    end if;
  end loop;
end;
$$;

create or replace function private.fn_validate_nursery_school_context_candidate_v2(p_value jsonb)
returns void language plpgsql immutable security invoker set search_path='' as $$
declare v_context_id uuid;
begin
  if p_value is null then return; end if;
  perform private.fn_nursery_assert_object_allowlist_v2(
    p_value,array['child_school_context_id','school_display_name','class_display_name','effective_from','effective_to'],1024,
    'NURSERY_SCHOOL_CONTEXT_CANDIDATE_INVALID'
  );
  if p_value ? 'child_school_context_id' then
    begin v_context_id:=(p_value->>'child_school_context_id')::uuid;
    exception when others then raise exception 'NURSERY_SCHOOL_CONTEXT_CANDIDATE_INVALID'; end;
    if v_context_id is null then raise exception 'NURSERY_SCHOOL_CONTEXT_CANDIDATE_INVALID'; end if;
  end if;
  if length(coalesce(p_value->>'school_display_name',''))>160
     or length(coalesce(p_value->>'class_display_name',''))>80 then
    raise exception 'NURSERY_SCHOOL_CONTEXT_CANDIDATE_INVALID';
  end if;
  if p_value ? 'effective_from' then
    begin perform (p_value->>'effective_from')::date;
    exception when others then raise exception 'NURSERY_SCHOOL_CONTEXT_CANDIDATE_INVALID'; end;
  end if;
  if p_value ? 'effective_to' then
    begin perform (p_value->>'effective_to')::date;
    exception when others then raise exception 'NURSERY_SCHOOL_CONTEXT_CANDIDATE_INVALID'; end;
  end if;
end;
$$;

create or replace function private.fn_validate_nursery_fact_value_v2(
  p_fact_kind text,p_value jsonb
) returns void language plpgsql immutable security invoker set search_path='' as $$
declare
  v_allowed text[]; v_key text; v_val jsonb; v_url text;
begin
  case p_fact_kind
    when 'event' then v_allowed:=array['title','event_type','date','start_date','end_date','all_day','location'];
    when 'required_item' then v_allowed:=array['item','quantity','note'];
    when 'deadline' then v_allowed:=array['label','date','time'];
    when 'recurrence' then v_allowed:=array['label','frequency','day_of_week','until'];
    when 'url' then v_allowed:=array['url','label'];
    when 'note' then v_allowed:=array['category','summary'];
    else raise exception 'NURSERY_FACT_KIND_INVALID';
  end case;
  perform private.fn_nursery_assert_object_allowlist_v2(
    p_value,v_allowed,2048,'NURSERY_FACT_VALUE_INVALID'
  );
  if jsonb_object_length(p_value)=0 then raise exception 'NURSERY_FACT_VALUE_INVALID'; end if;
  for v_key,v_val in select key,value from jsonb_each(p_value) loop
    if jsonb_typeof(v_val) not in ('string','number','boolean') then
      raise exception 'NURSERY_FACT_VALUE_INVALID';
    end if;
    if jsonb_typeof(v_val)='string' and length(v_val#>>'{}')>500 then
      raise exception 'NURSERY_FACT_VALUE_INVALID';
    end if;
  end loop;
  if p_fact_kind='required_item'
     and nullif(btrim(coalesce(p_value->>'item','')),'') is null then
    raise exception 'NURSERY_FACT_VALUE_INVALID';
  elsif p_fact_kind='url' then
    v_url:=p_value->>'url';
    if v_url is null or length(v_url)>2048 or v_url !~* '^https?://[^[:space:]]+$' then
      raise exception 'NURSERY_URL_INVALID';
    end if;
  elsif p_fact_kind='note' and length(coalesce(p_value->>'summary',''))>240 then
    raise exception 'NURSERY_FACT_VALUE_INVALID';
  end if;
end;
$$;

-- Generic structured values are still used by explicit, human-confirmed
-- preparation rules.  They are now bounded flat objects rather than arbitrary
-- durable transcript-shaped JSON.
create or replace function private.fn_validate_nursery_structured_value_v1(p_value jsonb)
returns void language plpgsql immutable security invoker set search_path='' as $$
declare v_key text; v_val jsonb;
begin
  if p_value is null or jsonb_typeof(p_value)<>'object'
     or octet_length(p_value::text)>4096 or jsonb_object_length(p_value)>12 then
    raise exception 'NURSERY_FACT_VALUE_INVALID';
  end if;
  for v_key,v_val in select key,value from jsonb_each(p_value) loop
    if lower(v_key) in (
      'full_transcript','transcript','raw_text','class_roster','other_child','other_children',
      'third_party_contact','contact','contacts','person_profile','people','members','phone','email'
    ) then raise exception 'NURSERY_THIRD_PARTY_DATA_FORBIDDEN'; end if;
    if jsonb_typeof(v_val) not in ('string','number','boolean','null') then
      raise exception 'NURSERY_FACT_VALUE_INVALID';
    end if;
    if jsonb_typeof(v_val)='string' and length(v_val#>>'{}')>500 then
      raise exception 'NURSERY_FACT_VALUE_INVALID';
    end if;
  end loop;
end;
$$;

create or replace function private.fn_validate_nursery_ai_patch_v2(
  p_target_type text,p_patch jsonb
) returns void language plpgsql immutable security invoker set search_path='' as $$
declare v_allowed text[]; v_key text; v_val jsonb; v_url text;
begin
  case p_target_type
    when 'task' then v_allowed:=array['title','scheduled_date','due_at','calendar_ends_at','notes'];
    when 'family_event' then v_allowed:=array['title','all_day','start_date','end_date','starts_at','ends_at','location','notes'];
    when 'recurrence' then v_allowed:=array['title','rrule','effective_from','effective_to','notes'];
    when 'info' then v_allowed:=array['title','summary','effective_from','effective_to','url'];
    else raise exception 'NURSERY_AI_CANDIDATE_INVALID';
  end case;
  perform private.fn_nursery_assert_object_allowlist_v2(
    p_patch,v_allowed,4096,'NURSERY_AI_CANDIDATE_INVALID'
  );
  if jsonb_object_length(p_patch)=0 then raise exception 'NURSERY_AI_CANDIDATE_INVALID'; end if;
  for v_key,v_val in select key,value from jsonb_each(p_patch) loop
    if jsonb_typeof(v_val) not in ('string','number','boolean','null') then
      raise exception 'NURSERY_AI_CANDIDATE_INVALID';
    end if;
    if jsonb_typeof(v_val)='string' and length(v_val#>>'{}')>500 then
      raise exception 'NURSERY_AI_CANDIDATE_INVALID';
    end if;
  end loop;
  if p_patch ? 'url' then
    v_url:=p_patch->>'url';
    if v_url is null or length(v_url)>2048 or v_url !~* '^https?://[^[:space:]]+$' then
      raise exception 'NURSERY_URL_INVALID';
    end if;
  end if;
end;
$$;

create or replace function private.fn_command_create_nursery_intake_v1(
  p_household_id uuid,p_operator_user_id uuid,p_actor_ref_id uuid,p_test_context_id uuid,
  p_operation_id uuid,p_document_kind text,p_storage_object_key text,p_captured_at timestamptz,
  p_extraction_version text,p_provider_metadata jsonb,p_source text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare v_claim jsonb; v_receipt_id uuid; v_document_id uuid; v_extraction_id uuid; v_result jsonb;
begin
  if p_source not in ('line','pwa') then raise exception 'COMMAND_SOURCE_INVALID'; end if;
  if nullif(btrim(coalesce(p_document_kind,'')),'') is null
     or length(p_document_kind)>80
     or nullif(btrim(coalesce(p_extraction_version,'')),'') is null
     or length(p_extraction_version)>160 then raise exception 'NURSERY_DOCUMENT_INPUT_INVALID'; end if;
  if nullif(btrim(coalesce(p_storage_object_key,'')),'') is null
     or length(p_storage_object_key)>512
     or p_storage_object_key ~* '^[a-z][a-z0-9+.-]*://' then
    raise exception 'NURSERY_PRIVATE_OBJECT_KEY_REQUIRED';
  end if;
  v_claim:=private.fn_claim_canonical_operation_v1(
    p_household_id,p_operator_user_id,p_actor_ref_id,p_test_context_id,p_operation_id,
    'nursery.intake.create',private.fn_canonical_request_hash_v1(jsonb_build_object(
      'document_kind',p_document_kind,'storage_object_key',p_storage_object_key,
      'captured_at',p_captured_at,'extraction_version',p_extraction_version,
      'provider_metadata',coalesce(p_provider_metadata,'{}'::jsonb),'source',p_source
    ))
  );
  if v_claim->>'disposition'='replay' then return v_claim->'result_payload'; end if;
  v_receipt_id:=(v_claim->>'receipt_id')::uuid;
  perform private.fn_validate_nursery_provider_metadata_v2(coalesce(p_provider_metadata,'{}'::jsonb));
  insert into private.source_documents(
    household_id,uploaded_by_actor_ref_id,document_kind,storage_object_key,captured_at,test_context_id
  ) values (
    p_household_id,p_actor_ref_id,btrim(p_document_kind),p_storage_object_key,p_captured_at,p_test_context_id
  ) returning id into v_document_id;
  insert into private.document_extractions(
    household_id,source_document_id,extraction_version,provider_metadata,state,test_context_id
  ) values (
    p_household_id,v_document_id,btrim(p_extraction_version),coalesce(p_provider_metadata,'{}'::jsonb),
    'processing',p_test_context_id
  ) returning id into v_extraction_id;
  v_result:=jsonb_build_object('source_document_id',v_document_id,'extraction_id',v_extraction_id,
    'state','processing','side_effects','none');
  perform private.fn_complete_canonical_operation_v1(v_receipt_id,'source_document',v_document_id,v_result);
  return v_result;
end;
$$;

create or replace function private.fn_command_record_nursery_extraction_v1(
  p_household_id uuid,p_operator_user_id uuid,p_actor_ref_id uuid,p_test_context_id uuid,
  p_operation_id uuid,p_extraction_id uuid,p_expected_revision bigint,
  p_school_context_candidate jsonb,p_source_facts jsonb,p_ai_candidates jsonb,p_source text
) returns jsonb language plpgsql security definer set search_path='' as $$
declare
  v_claim jsonb; v_receipt_id uuid; v_extraction private.document_extractions%rowtype;
  v_fact jsonb; v_candidate jsonb; v_context_id uuid; v_fact_id uuid; v_candidate_id uuid;
  v_fact_count integer:=0; v_candidate_count integer:=0; v_revision bigint; v_result jsonb;
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
  select * into v_extraction from private.document_extractions
  where household_id=p_household_id and id=p_extraction_id for update;
  if not found then raise exception 'NURSERY_EXTRACTION_NOT_FOUND'; end if;
  if v_extraction.test_context_id is distinct from p_test_context_id then raise exception 'ACTOR_SCOPE_CONFLICT'; end if;
  if v_extraction.revision<>p_expected_revision then raise exception 'AGGREGATE_REVISION_CONFLICT'; end if;
  if v_extraction.state not in ('processing','review') then raise exception 'NURSERY_EXTRACTION_NOT_RECORDABLE'; end if;

  for v_fact in select value from jsonb_array_elements(coalesce(p_source_facts,'[]'::jsonb)) loop
    if jsonb_typeof(v_fact)<>'object'
       or jsonb_object_length(v_fact)>6 then raise exception 'NURSERY_FACT_VALUE_INVALID'; end if;
    if exists(select 1 from jsonb_object_keys(v_fact) k
      where k not in ('child_school_context_id','fact_kind','normalized_value','confidence_band','source_locator','source_label')) then
      raise exception 'NURSERY_FACT_VALUE_INVALID';
    end if;
    if coalesce(v_fact->>'fact_kind','') not in ('event','required_item','deadline','recurrence','url','note') then
      raise exception 'NURSERY_FACT_KIND_INVALID';
    end if;
    if coalesce(v_fact->>'confidence_band','') not in ('high','medium','low') then
      raise exception 'NURSERY_FACT_CONFIDENCE_INVALID';
    end if;
    if length(coalesce(v_fact->>'source_locator',''))>128
       or length(coalesce(v_fact->>'source_label',''))>120 then
      raise exception 'NURSERY_FACT_VALUE_INVALID';
    end if;
    v_context_id:=nullif(v_fact->>'child_school_context_id','')::uuid;
    if v_context_id is null or not exists (
      select 1 from public.child_school_contexts s
      where s.household_id=p_household_id and s.id=v_context_id and s.active
    ) then raise exception 'NURSERY_CHILD_SCHOOL_SCOPE_REQUIRED'; end if;
    perform private.fn_validate_nursery_fact_value_v2(v_fact->>'fact_kind',v_fact->'normalized_value');
    insert into private.document_facts(
      household_id,extraction_id,child_school_context_id,fact_kind,normalized_value,
      confidence_band,source_locator,fact_origin,test_context_id
    ) values (
      p_household_id,p_extraction_id,v_context_id,v_fact->>'fact_kind',v_fact->'normalized_value',
      v_fact->>'confidence_band',nullif(v_fact->>'source_locator',''),'source_explicit',p_test_context_id
    ) returning id into v_fact_id;
    v_fact_count:=v_fact_count+1;
  end loop;

  for v_candidate in select value from jsonb_array_elements(coalesce(p_ai_candidates,'[]'::jsonb)) loop
    if jsonb_typeof(v_candidate)<>'object' or jsonb_object_length(v_candidate)>7
       or exists(select 1 from jsonb_object_keys(v_candidate) k
         where k not in ('child_school_context_id','target_type','target_id','proposed_patch','explanation','current_snapshot_hash','confidence_band'))
       or coalesce(v_candidate->>'target_type','') not in ('family_event','task','recurrence','info')
       or jsonb_typeof(v_candidate->'proposed_patch')<>'object'
       or nullif(btrim(coalesce(v_candidate->>'explanation','')),'') is null
       or length(v_candidate->>'explanation')>500
       or length(coalesce(v_candidate->>'current_snapshot_hash',''))>160 then
      raise exception 'NURSERY_AI_CANDIDATE_INVALID';
    end if;
    v_context_id:=nullif(v_candidate->>'child_school_context_id','')::uuid;
    if v_context_id is null or not exists (
      select 1 from public.child_school_contexts s
      where s.household_id=p_household_id and s.id=v_context_id and s.active
    ) then raise exception 'NURSERY_CHILD_SCHOOL_SCOPE_REQUIRED'; end if;
    perform private.fn_validate_nursery_ai_patch_v2(v_candidate->>'target_type',v_candidate->'proposed_patch');
    insert into public.change_candidates(
      household_id,target_type,target_id,source_type,source_ref,proposed_patch,current_snapshot_hash,test_context_id
    ) values (
      p_household_id,v_candidate->>'target_type',nullif(v_candidate->>'target_id','')::uuid,
      'ai_inference',p_extraction_id::text,
      (v_candidate->'proposed_patch')||jsonb_build_object(
        'origin_label','ai_inference','explanation',v_candidate->>'explanation',
        'child_school_context_id',v_context_id
      ),nullif(v_candidate->>'current_snapshot_hash',''),p_test_context_id
    ) returning id into v_candidate_id;
    v_candidate_count:=v_candidate_count+1;
  end loop;
  update private.document_extractions
  set school_context_candidate=p_school_context_candidate,state='review',revision=revision+1
  where id=p_extraction_id returning revision into v_revision;
  v_result:=jsonb_build_object('extraction_id',p_extraction_id,'state','review','revision',v_revision,
    'source_fact_count',v_fact_count,'ai_candidate_count',v_candidate_count,'side_effects','none');
  perform private.fn_complete_canonical_operation_v1(v_receipt_id,'document_extraction',p_extraction_id,v_result);
  return v_result;
end;
$$;

revoke all on function private.fn_nursery_assert_object_allowlist_v2(jsonb,text[],integer,text) from public,anon,authenticated;
revoke all on function private.fn_validate_nursery_provider_metadata_v2(jsonb) from public,anon,authenticated;
revoke all on function private.fn_validate_nursery_school_context_candidate_v2(jsonb) from public,anon,authenticated;
revoke all on function private.fn_validate_nursery_fact_value_v2(text,jsonb) from public,anon,authenticated;
revoke all on function private.fn_validate_nursery_ai_patch_v2(text,jsonb) from public,anon,authenticated;
revoke all on function private.fn_validate_nursery_structured_value_v1(jsonb) from public,anon,authenticated;
revoke all on function private.fn_command_create_nursery_intake_v1(uuid,uuid,uuid,uuid,uuid,text,text,timestamptz,text,jsonb,text) from public,anon,authenticated;
revoke all on function private.fn_command_record_nursery_extraction_v1(uuid,uuid,uuid,uuid,uuid,uuid,bigint,jsonb,jsonb,jsonb,text) from public,anon,authenticated;
grant execute on function private.fn_command_create_nursery_intake_v1(uuid,uuid,uuid,uuid,uuid,text,text,timestamptz,text,jsonb,text) to service_role;
grant execute on function private.fn_command_record_nursery_extraction_v1(uuid,uuid,uuid,uuid,uuid,uuid,bigint,jsonb,jsonb,jsonb,text) to service_role;
