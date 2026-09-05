-- Q89-Q106 worker adapters. These expose no authenticated direct table access;
-- Edge uses service_role after provider/worker/user authentication.

create or replace function public.server_tx_prepare_nursery_line_source(
  p_intake_id uuid,p_expected_revision bigint,p_storage_object_key text,p_parser_version text
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare v_i private.nursery_line_image_intakes%rowtype; v_result jsonb; v_source uuid; v_extraction uuid;
begin
  select * into v_i from private.nursery_line_image_intakes where id=p_intake_id for update;
  if not found then raise exception 'NURSERY_INTAKE_NOT_FOUND'; end if;
  if v_i.status<>'processing' or v_i.revision<>p_expected_revision then raise exception 'NURSERY_INTAKE_STALE'; end if;
  if nullif(btrim(coalesce(p_storage_object_key,'')),'') is null or octet_length(p_storage_object_key)>512 then raise exception 'NURSERY_STORAGE_KEY_INVALID'; end if;
  v_result:=private.fn_command_create_nursery_intake_v1(
    v_i.household_id,v_i.actor_id,v_i.actor_ref_id,null,gen_random_uuid(),
    'codmon_notice',p_storage_object_key,v_i.received_at,coalesce(nullif(p_parser_version,''),'nursery-line-v1'),
    jsonb_build_object('provider','line','source','image'), 'line'
  );
  v_source:=(v_result->>'source_document_id')::uuid; v_extraction:=(v_result->>'extraction_id')::uuid;
  update private.nursery_line_image_intakes set source_document_id=v_source,extraction_id=v_extraction,revision=revision+1,updated_at=now()
    where id=v_i.id returning * into v_i;
  return jsonb_build_object('intake_id',v_i.id,'revision',v_i.revision,'source_document_id',v_source,'extraction_id',v_extraction);
end $$;
revoke all on function public.server_tx_prepare_nursery_line_source(uuid,bigint,text,text) from public,anon,authenticated;
grant execute on function public.server_tx_prepare_nursery_line_source(uuid,bigint,text,text) to service_role;

create or replace function public.server_tx_record_nursery_line_analysis(
  p_intake_id uuid,p_expected_revision bigint,p_child_school_context_id uuid,p_context_confidence text,p_ambiguity_fields text[],
  p_source_facts jsonb,p_ai_candidates jsonb,p_review_items jsonb,p_status text
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare v_i private.nursery_line_image_intakes%rowtype; v_review jsonb;
begin
  select * into v_i from private.nursery_line_image_intakes where id=p_intake_id for update;
  if not found then raise exception 'NURSERY_INTAKE_NOT_FOUND'; end if;
  if v_i.status<>'processing' or v_i.revision<>p_expected_revision or v_i.source_document_id is null or v_i.extraction_id is null then raise exception 'NURSERY_INTAKE_STALE'; end if;
  if p_status not in ('needs_clarification','review_ready') then raise exception 'NURSERY_STATUS_INVALID'; end if;
  if p_child_school_context_id is not null then
    v_review:=private.fn_command_record_nursery_extraction_v1(
      v_i.household_id,v_i.actor_id,v_i.actor_ref_id,null,gen_random_uuid(),v_i.extraction_id,1,
      jsonb_build_object('child_school_context_id',p_child_school_context_id),
      coalesce(p_source_facts,'[]'::jsonb),coalesce(p_ai_candidates,'[]'::jsonb),'line'
    );
    if v_review->>'state'<>'review' or v_review->>'side_effects'<>'none' then raise exception 'NURSERY_DD9_SIDE_EFFECT_BOUNDARY'; end if;
  end if;
  return public.server_tx_finish_nursery_image_review(
    p_intake_id,p_expected_revision,p_status,v_i.source_document_id,v_i.extraction_id,p_child_school_context_id,
    p_context_confidence,p_ambiguity_fields,p_review_items,false
  );
end $$;
revoke all on function public.server_tx_record_nursery_line_analysis(uuid,bigint,uuid,text,text[],jsonb,jsonb,jsonb,text) from public,anon,authenticated;
grant execute on function public.server_tx_record_nursery_line_analysis(uuid,bigint,uuid,text,text[],jsonb,jsonb,jsonb,text) to service_role;

create or replace function public.server_read_nursery_source_locator(p_actor_id uuid,p_intake_id uuid)
returns jsonb language plpgsql stable security invoker set search_path='' as $$
declare v_i private.nursery_line_image_intakes%rowtype; v_key text; v_deleted timestamptz;
begin
  select i.* into v_i from private.nursery_line_image_intakes i join public.household_members m on m.household_id=i.household_id
    where i.id=p_intake_id and m.user_id=p_actor_id;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if v_i.source_document_id is null then return jsonb_build_object('available',false); end if;
  select storage_object_key,raw_deleted_at into v_key,v_deleted from private.source_documents where id=v_i.source_document_id and household_id=v_i.household_id;
  if v_deleted is not null or v_i.raw_deleted_at is not null then return jsonb_build_object('available',false); end if;
  return jsonb_build_object('available',true,'storage_object_key',v_key);
end $$;
revoke all on function public.server_read_nursery_source_locator(uuid,uuid) from public,anon,authenticated;
grant execute on function public.server_read_nursery_source_locator(uuid,uuid) to service_role;

create or replace function public.server_tx_authorize_nursery_raw_delete(p_actor_id uuid,p_intake_id uuid,p_expected_revision bigint)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare v_i private.nursery_line_image_intakes%rowtype; v_key text; v_deleted timestamptz;
begin
  select i.* into v_i from private.nursery_line_image_intakes i join public.household_members m on m.household_id=i.household_id
    where i.id=p_intake_id and m.user_id=p_actor_id for update of i;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if v_i.revision<>p_expected_revision then raise exception 'NURSERY_INTAKE_STALE'; end if;
  if v_i.source_document_id is null then return jsonb_build_object('authorized',true,'already_absent',true); end if;
  select storage_object_key,raw_deleted_at into v_key,v_deleted from private.source_documents where id=v_i.source_document_id and household_id=v_i.household_id;
  if v_deleted is not null or v_i.raw_deleted_at is not null then return jsonb_build_object('authorized',true,'already_absent',true); end if;
  return jsonb_build_object('authorized',true,'already_absent',false,'storage_object_key',v_key);
end $$;
revoke all on function public.server_tx_authorize_nursery_raw_delete(uuid,uuid,bigint) from public,anon,authenticated;
grant execute on function public.server_tx_authorize_nursery_raw_delete(uuid,uuid,bigint) to service_role;

-- Fix enqueue disposition deterministically without changing its idempotent key.
create or replace function public.server_tx_enqueue_nursery_line_image(
  p_provider_event_id text,p_line_message_id text,p_line_user_id text,p_received_at timestamptz default now()
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare v_link private.line_user_links%rowtype; v_actor_ref uuid; v_id uuid; v_created boolean:=false;
begin
  if nullif(btrim(coalesce(p_provider_event_id,'')),'') is null or nullif(btrim(coalesce(p_line_message_id,'')),'') is null
     or nullif(btrim(coalesce(p_line_user_id,'')),'') is null then raise exception 'INVALID_INPUT'; end if;
  select * into v_link from private.line_user_links where line_user_id=p_line_user_id and status='active';
  if not found then return jsonb_build_object('disposition','unlinked'); end if;
  select id into v_actor_ref from public.domain_actor_refs where household_id=v_link.household_id and actor_kind='real_user' and real_user_id=v_link.user_id;
  if v_actor_ref is null then raise exception 'LINE_ACTOR_REF_NOT_FOUND'; end if;
  insert into private.nursery_line_image_intakes(provider_event_id,line_message_id,household_id,actor_id,actor_ref_id,line_user_id,received_at)
  values(p_provider_event_id,p_line_message_id,v_link.household_id,v_link.user_id,v_actor_ref,p_line_user_id,coalesce(p_received_at,now()))
  on conflict(provider_event_id) do nothing returning id into v_id;
  v_created:=v_id is not null;
  if v_id is null then select id into v_id from private.nursery_line_image_intakes where provider_event_id=p_provider_event_id; end if;
  return jsonb_build_object('disposition',case when v_created then 'created' else 'existing' end,'intake_id',v_id);
end $$;
revoke all on function public.server_tx_enqueue_nursery_line_image(text,text,text,timestamptz) from public,anon,authenticated;
grant execute on function public.server_tx_enqueue_nursery_line_image(text,text,text,timestamptz) to service_role;
