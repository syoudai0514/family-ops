-- DD9 R0 privacy boundary: canonical receipt claim provenance.
--
-- canonical_operation_receipts.request_hash is intentionally high-cardinality because
-- it carries a server-derived idempotency digest.  That is safe only when the row is
-- created through the canonical SECURITY DEFINER command/helper path.  A direct
-- service_role INSERT must never be able to mint a nursery receipt and persist an
-- arbitrary text value in request_hash.
--
-- Keep the generic receipt table compatible for the wider canonical foundation, but:
--   1. make the generic claim helper internal-only to SECURITY DEFINER commands; and
--   2. reject direct service_role INSERT / relabel into nursery.extraction.record at
--      the table boundary.

-- The helper is an implementation primitive, not an RPC surface.  Existing canonical
-- command functions are SECURITY DEFINER and continue to call it as the migration
-- owner; direct service_role callers no longer can use it to bypass the table guard.
revoke execute on function private.fn_claim_canonical_operation_v1(
  uuid, uuid, uuid, uuid, uuid, text, text
) from service_role;

create or replace function private.fn_guard_nursery_receipt_claim_provenance_v1()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if tg_op = 'INSERT' then
    if new.action_type = 'nursery.extraction.record'
       and current_user = 'service_role' then
      raise exception 'NURSERY_OPERATION_RECEIPT_DIRECT_INSERT_FORBIDDEN';
    end if;
    return new;
  end if;

  -- A caller must not mint a non-nursery row first and then relabel it after the
  -- INSERT guard has run.  The existing nursery receipt guard already blocks the
  -- opposite direction (nursery -> other action); this closes the inverse path.
  if new.action_type = 'nursery.extraction.record'
     and old.action_type is distinct from 'nursery.extraction.record' then
    raise exception 'NURSERY_OPERATION_RECEIPT_RELABEL_FORBIDDEN';
  end if;

  return new;
end;
$$;

revoke all on function private.fn_guard_nursery_receipt_claim_provenance_v1()
  from public, anon, authenticated, service_role;

drop trigger if exists canonical_operation_receipts_nursery_claim_provenance_v1
  on private.canonical_operation_receipts;
create trigger canonical_operation_receipts_nursery_claim_provenance_v1
before insert or update of action_type on private.canonical_operation_receipts
for each row execute function private.fn_guard_nursery_receipt_claim_provenance_v1();
