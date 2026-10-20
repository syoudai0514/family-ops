-- LINE notice images were analyzed successfully, then rejected at source creation
-- because source is not an allowed provider_metadata key. Keep the strict
-- privacy allowlist; the command already receives source=line separately.
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
    jsonb_build_object('provider','line'), 'line'
  );
  v_source:=(v_result->>'source_document_id')::uuid; v_extraction:=(v_result->>'extraction_id')::uuid;
  update private.nursery_line_image_intakes set source_document_id=v_source,extraction_id=v_extraction,revision=revision+1,updated_at=now()
    where id=v_i.id returning * into v_i;
  return jsonb_build_object('intake_id',v_i.id,'revision',v_i.revision,'source_document_id',v_source,'extraction_id',v_extraction);
end $$;
revoke all on function public.server_tx_prepare_nursery_line_source(uuid,bigint,text,text) from public,anon,authenticated;
grant execute on function public.server_tx_prepare_nursery_line_source(uuid,bigint,text,text) to service_role;

