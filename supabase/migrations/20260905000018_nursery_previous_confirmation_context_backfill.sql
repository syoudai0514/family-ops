-- Issue #48 Q94/Q95 closeout.
-- Review items are inserted while an intake is still in `processing`; the
-- intake's resolved child/school context is persisted immediately afterwards.
-- Link later-notice candidates to the previous human-confirmed item once that
-- context becomes available. This keeps pre-confirmation candidates read-only
-- with respect to canonical event/rule rows while preserving diff provenance.

create or replace function private.fn_backfill_nursery_review_previous_v1()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.child_school_context_id is null
     or new.child_school_context_id is not distinct from old.child_school_context_id then
    return new;
  end if;

  update private.nursery_review_items r
  set previous_confirmed_item_id = previous.id
  from lateral (
    select c.id
    from public.nursery_confirmed_items c
    where c.household_id = r.household_id
      and c.child_school_context_id = new.child_school_context_id
      and c.item_kind = r.item_kind
      and c.classification is not distinct from r.classification
    order by c.confirmed_at desc, c.id desc
    limit 1
  ) previous
  where r.intake_id = new.id
    and r.household_id = new.household_id
    and r.previous_confirmed_item_id is null;

  return new;
end;
$$;

revoke all on function private.fn_backfill_nursery_review_previous_v1()
  from public, anon, authenticated;
grant execute on function private.fn_backfill_nursery_review_previous_v1()
  to service_role;

drop trigger if exists nursery_intake_backfill_review_previous
  on private.nursery_line_image_intakes;
create trigger nursery_intake_backfill_review_previous
after update of child_school_context_id on private.nursery_line_image_intakes
for each row
execute function private.fn_backfill_nursery_review_previous_v1();
