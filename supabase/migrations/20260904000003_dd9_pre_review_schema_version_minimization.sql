-- Fourth independent re-review remediation for PR #45.
--
-- A caller/model-controlled numeric schema_version is still a high-cardinality
-- durable channel even when it is syntactically limited to 1-6 decimal digits.
-- R0 has no trusted adapter-issued schema registry, so pre-review persistence
-- uses one server-issued constant marker instead of retaining the submitted
-- value.  The existing document_extractions trigger remains the durable table
-- boundary and therefore also closes later service-role UPDATE re-injection.

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
begin
  if v_provider not in ('codmon','openai','google','manual','test','unknown') then
    v_provider:='unknown';
  end if;

  -- provider is a fixed low-cardinality enum. Presence markers below are also
  -- fixed constants. No caller/model supplied arbitrary scalar is retained.
  v_result:=jsonb_build_object(
    'provider',v_provider,
    'schema_version','1'
  );

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

  return v_result;
end;
$$;

revoke all on function private.fn_minimize_nursery_provider_metadata_v3(jsonb)
  from public,anon,authenticated,service_role;

-- Keep the table trigger as the authoritative persistence boundary.  The
-- extraction-version marker is already server controlled; do not introduce a
-- new version label merely because the metadata minimizer was hardened.
create or replace function private.fn_minimize_nursery_extraction_metadata_v1()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  new.extraction_version:='pre_review_minimized_v3';
  new.provider_metadata:=private.fn_minimize_nursery_provider_metadata_v3(
    coalesce(new.provider_metadata,'{}'::jsonb)
  );
  return new;
end;
$$;

revoke all on function private.fn_minimize_nursery_extraction_metadata_v1()
  from public,anon,authenticated,service_role;

-- Recreate explicitly so a source reviewer can verify that INSERT and UPDATE
-- both cross the same minimized durable boundary.
drop trigger if exists document_extractions_minimize_pre_review_metadata_v1
  on private.document_extractions;
create trigger document_extractions_minimize_pre_review_metadata_v1
before insert or update of extraction_version,provider_metadata
on private.document_extractions
for each row execute function private.fn_minimize_nursery_extraction_metadata_v1();

-- Normalize rows already persisted behind the R0 pre-review marker.  This is
-- idempotent: the trigger applies the same fixed marker again, and arbitrary
-- schema_version values cannot survive the rewrite.
update private.document_extractions
set provider_metadata=private.fn_minimize_nursery_provider_metadata_v3(
      coalesce(provider_metadata,'{}'::jsonb)
    )
where extraction_version='pre_review_minimized_v3';
