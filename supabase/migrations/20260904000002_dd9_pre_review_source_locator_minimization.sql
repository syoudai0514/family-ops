-- Third independent re-review remediation for PR #45.
-- DD9 HIGH: source_locator is extractor/model supplied and therefore is not
-- trusted provenance. A regex-valid numeric locator can encode arbitrary bytes
-- unless it is resolved against a trusted server-side locator inventory.
--
-- No such trusted locator inventory exists in R0. Until one is introduced by a
-- separately reviewed migration, nursery/document extraction facts must not
-- durably retain source_locator at all.

create or replace function private.fn_minimize_document_fact_source_locator_v1()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  if new.extraction_id is not null
     and exists (
       select 1
       from private.document_extractions e
       where e.id=new.extraction_id
         and e.household_id=new.household_id
         and e.test_context_id is not distinct from new.test_context_id
     ) then
    -- The submitted value is not trusted provenance. Syntax such as
    -- item:18537 is still a reversible 16-bit storage cell when the model is
    -- free to choose the number, so every locator is removed at the durable
    -- table boundary.
    new.source_locator:=null;
  end if;
  return new;
end;
$$;

revoke all on function private.fn_minimize_document_fact_source_locator_v1()
  from public,anon,authenticated,service_role;

-- Scrub rows created by earlier heads before the table-boundary fence existed.
update private.document_facts f
set source_locator=null
from private.document_extractions e
where e.id=f.extraction_id
  and e.household_id=f.household_id
  and e.test_context_id is not distinct from f.test_context_id
  and f.source_locator is not null;

drop trigger if exists document_facts_minimize_source_locator_insert_v1
  on private.document_facts;
create trigger document_facts_minimize_source_locator_insert_v1
before insert on private.document_facts
for each row execute function private.fn_minimize_document_fact_source_locator_v1();

drop trigger if exists document_facts_minimize_source_locator_update_v1
  on private.document_facts;
create trigger document_facts_minimize_source_locator_update_v1
before update of household_id,extraction_id,source_locator,test_context_id
on private.document_facts
for each row execute function private.fn_minimize_document_fact_source_locator_v1();
