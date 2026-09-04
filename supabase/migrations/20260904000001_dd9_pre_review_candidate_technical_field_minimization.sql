-- Second independent re-review remediation for PR #45.
-- DD9 HIGH: caller/model supplied current_snapshot_hash and target_id are not
-- trusted technical metadata at the nursery pre-review boundary.  The durable
-- public.change_candidates row must not retain either value until a trusted
-- server-side target resolver computes/binds them after human confirmation.
--
-- This is deliberately enforced at the table boundary, not only in the
-- nursery command function, so a future service-role insertion path cannot
-- re-open the same covert-storage channel.

create or replace function private.fn_minimize_nursery_change_candidate_pre_review_v1()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  if new.source_type='ai_inference'
     and nullif(btrim(coalesce(new.source_ref,'')),'') is not null
     and exists (
       select 1
       from private.document_extractions e
       where e.id::text=new.source_ref
         and e.household_id=new.household_id
         and e.test_context_id is not distinct from new.test_context_id
     ) then
    -- Neither field is trusted from OCR/model/extractor input.  Keeping the
    -- submitted 64-hex value would provide a reversible 32-byte-per-candidate
    -- durable storage channel for third-party PII.  A model supplied UUID is
    -- likewise not a trusted canonical target binding.
    new.current_snapshot_hash:=null;
    new.target_id:=null;
  end if;
  return new;
end;
$$;

revoke all on function private.fn_minimize_nursery_change_candidate_pre_review_v1()
  from public,anon,authenticated,service_role;

drop trigger if exists change_candidates_minimize_nursery_pre_review_insert_v1
  on public.change_candidates;
create trigger change_candidates_minimize_nursery_pre_review_insert_v1
before insert on public.change_candidates
for each row execute function private.fn_minimize_nursery_change_candidate_pre_review_v1();

drop trigger if exists change_candidates_minimize_nursery_pre_review_update_v1
  on public.change_candidates;
create trigger change_candidates_minimize_nursery_pre_review_update_v1
before update of household_id,source_type,source_ref,target_id,current_snapshot_hash,test_context_id
on public.change_candidates
for each row execute function private.fn_minimize_nursery_change_candidate_pre_review_v1();
