-- Preserve the already-reviewed canonical AI review marker while keeping the
-- R0 quarantine payload fully server-controlled.  This trigger runs after the
-- nursery canonicalizer (alphabetical trigger order) and is itself idempotent,
-- so direct service-role INSERT/UPDATE cannot choose this field either.

create or replace function private.fn_force_nursery_r0_review_marker_v1()
returns trigger
language plpgsql
security definer
set search_path=''
as $$
begin
  if new.nursery_pre_review_slot is not null
     or (
       new.source_type='ai_inference'
       and exists (
         select 1 from private.document_extractions e
         where e.id::text=new.source_ref
       )
     ) then
    new.proposed_patch:=coalesce(new.proposed_patch,'{}'::jsonb)
      || jsonb_build_object(
        'review_required',true,
        'origin_label','ai_inference',
        'reason_code','model_candidate_requires_review',
        'value_kind','r0_untrusted_ai_candidate_withheld'
      );
  end if;
  return new;
end;
$$;
revoke all on function private.fn_force_nursery_r0_review_marker_v1()
  from public,anon,authenticated,service_role;

drop trigger if exists zz_change_candidates_r0_review_marker_v1
  on public.change_candidates;
create trigger zz_change_candidates_r0_review_marker_v1
before insert or update on public.change_candidates
for each row execute function private.fn_force_nursery_r0_review_marker_v1();

-- Normalize any rows backfilled by the immediately preceding migration.
update public.change_candidates c
set proposed_patch=c.proposed_patch
where c.nursery_pre_review_slot is not null;
