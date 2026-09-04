-- Follow-up to 20260903030022.
-- Make the pre-review technical metadata sanitizer idempotent so the command
-- boundary and the table trigger can both apply it without deleting the fixed
-- redaction marker. Arbitrary caller text is still never retained.
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

  if nullif(p_value->>'model','') is not null
     or p_value->>'model_fingerprint'='redacted-pre-review' then
    v_result:=v_result||jsonb_build_object('model_fingerprint','redacted-pre-review');
  end if;
  if nullif(p_value->>'model_version','') is not null
     or p_value->>'model_version_fingerprint'='redacted-pre-review' then
    v_result:=v_result||jsonb_build_object('model_version_fingerprint','redacted-pre-review');
  end if;
  if nullif(p_value->>'extractor_version','') is not null
     or p_value->>'extractor_version_fingerprint'='redacted-pre-review' then
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
