-- DD9 defense-in-depth after independent re-review.
--
-- The pre-review privacy boundary must not expose an alternate durable free-text
-- channel through technical metadata.  Raw source/object locators remain private
-- by design, but extraction/model labels are reduced to controlled markers.
-- This migration does not activate OCR/AI/Storage adapters or any target writer.

create or replace function private.fn_minimize_nursery_provider_metadata_v3(p_value jsonb)
returns jsonb
language plpgsql
immutable
security invoker
set search_path=''
as $$
declare
  v_provider text:=lower(coalesce(p_value->>'provider','unknown'));
  v_result jsonb:='{}'::jsonb;
  v_schema_version text;
begin
  if v_provider not in ('codmon','openai','google','manual','test','unknown') then
    v_provider:='unknown';
  end if;
  v_result:=jsonb_build_object('provider',v_provider);

  -- Presence markers are intentionally constant.  Do not hash arbitrary model
  -- strings: a low-entropy phone/name placed in a technical field could make a
  -- deterministic hash itself a durable third-party pseudonymous identifier.
  if nullif(p_value->>'model','') is not null then
    v_result:=v_result||jsonb_build_object('model_fingerprint','redacted-pre-review');
  end if;
  if nullif(p_value->>'model_version','') is not null then
    v_result:=v_result||jsonb_build_object('model_version_fingerprint','redacted-pre-review');
  end if;
  if nullif(p_value->>'extractor_version','') is not null then
    v_result:=v_result||jsonb_build_object('extractor_version_fingerprint','redacted-pre-review');
  end if;

  v_schema_version:=nullif(p_value->>'schema_version','');
  if v_schema_version is not null and v_schema_version~'^[0-9]{1,6}$' then
    v_result:=v_result||jsonb_build_object('schema_version',v_schema_version);
  end if;
  return v_result;
end;
$$;
revoke all on function private.fn_minimize_nursery_provider_metadata_v3(jsonb)
  from public,anon,authenticated,service_role;

create or replace function private.fn_minimize_nursery_extraction_metadata_v1()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  -- extraction_version is a pipeline implementation label, not a household
  -- fact.  Persist one controlled boundary version instead of caller-supplied
  -- text so it cannot be abused as a phone/name/profile storage channel.
  new.extraction_version:='pre_review_minimized_v3';
  new.provider_metadata:=private.fn_minimize_nursery_provider_metadata_v3(
    coalesce(new.provider_metadata,'{}'::jsonb)
  );
  return new;
end;
$$;
revoke all on function private.fn_minimize_nursery_extraction_metadata_v1()
  from public,anon,authenticated,service_role;

drop trigger if exists document_extractions_minimize_pre_review_metadata_v1
  on private.document_extractions;
create trigger document_extractions_minimize_pre_review_metadata_v1
before insert or update of extraction_version,provider_metadata
on private.document_extractions
for each row execute function private.fn_minimize_nursery_extraction_metadata_v1();
