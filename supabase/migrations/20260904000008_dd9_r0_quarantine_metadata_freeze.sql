-- DD9 R0 quarantine follow-up: a fixed tuple must stay fixed even when a
-- service-role path performs a selective UPDATE.  Generic set_updated_at
-- triggers would otherwise make the chosen subset observable as a timestamp
-- bitmask.  Nursery pre-review rows therefore preserve their server-issued
-- timestamps across direct UPDATEs.  Non-nursery change_candidates are
-- unaffected.

create or replace function private.fn_freeze_nursery_r0_candidate_metadata_v1()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  if old.nursery_pre_review_slot is not null
     or (
       old.source_type='ai_inference'
       and exists (
         select 1 from private.document_extractions e
         where e.id::text=old.source_ref
       )
     ) then
    new.created_at:=old.created_at;
    new.updated_at:=old.updated_at;
  end if;
  return new;
end;
$$;
revoke all on function private.fn_freeze_nursery_r0_candidate_metadata_v1()
  from public,anon,authenticated,service_role;

drop trigger if exists zzz_change_candidates_r0_freeze_metadata_v1
  on public.change_candidates;
create trigger zzz_change_candidates_r0_freeze_metadata_v1
before update on public.change_candidates
for each row execute function private.fn_freeze_nursery_r0_candidate_metadata_v1();

create or replace function private.fn_freeze_nursery_r0_extraction_metadata_v1()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  -- document_extractions is a DD9-private pre-review table.  The extraction
  -- state/revision carry lifecycle semantics; wall-clock update timing does not
  -- and is therefore not a durable caller-selectable scalar in R0.
  new.created_at:=old.created_at;
  new.updated_at:=old.updated_at;
  return new;
end;
$$;
revoke all on function private.fn_freeze_nursery_r0_extraction_metadata_v1()
  from public,anon,authenticated,service_role;

drop trigger if exists zzz_document_extractions_r0_freeze_metadata_v1
  on private.document_extractions;
create trigger zzz_document_extractions_r0_freeze_metadata_v1
before update on private.document_extractions
for each row execute function private.fn_freeze_nursery_r0_extraction_metadata_v1();
