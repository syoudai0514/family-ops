-- WP-DD2 forward fix: the R0 compatibility backfill must remain safe after
-- canonical Request commands have begun creating authoritative Attempts.
--
-- The original additive backfill selected Requests that lacked a
-- legacy_backfill Attempt. A canonical-created Request intentionally has no
-- legacy_backfill Attempt, so a later maintenance rerun could try to add a
-- second active Attempt and collide with request_attempts_one_active_nonterminal_idx.
-- Existing migrations stay immutable; this migration narrows that legacy-only
-- insertion at the table boundary and corrects the reconciliation predicate.

create or replace function private.fn_guard_legacy_request_backfill_coexistence_v1()
returns trigger
language plpgsql
security invoker
set search_path = ''
as $$
begin
  if new.legacy_backfill
     and exists (
       select 1
       from public.request_attempts a
       where a.household_id = new.household_id
         and a.request_id = new.request_id
         and not a.legacy_backfill
     ) then
    -- A canonical Attempt is already the complete negotiation history for this
    -- logical Request. Do not manufacture an additional legacy Attempt.
    return null;
  end if;

  return new;
end;
$$;

revoke all on function private.fn_guard_legacy_request_backfill_coexistence_v1()
  from public, anon, authenticated;
grant execute on function private.fn_guard_legacy_request_backfill_coexistence_v1()
  to service_role;

create trigger request_attempts_legacy_backfill_coexistence_guard_v1
  before insert on public.request_attempts
  for each row execute function private.fn_guard_legacy_request_backfill_coexistence_v1();

alter function private.canonical_foundation_reconciliation_v1()
  rename to canonical_foundation_reconciliation_v1_pre_command_coexistence;

create or replace function private.canonical_foundation_reconciliation_v1()
returns table(issue_type text, issue_count bigint)
language sql
stable
security definer
set search_path = ''
as $$
  -- Preserve every prior reconciliation check except the old predicate that
  -- incorrectly required a legacy_backfill Attempt even for canonical-created
  -- Requests.
  select r.issue_type, r.issue_count
  from private.canonical_foundation_reconciliation_v1_pre_command_coexistence() r
  where r.issue_type <> 'legacy_request_without_backfill_attempt'

  union all

  -- Keep the established issue key for monitoring compatibility. A Request is
  -- anomalous only when it has no Attempt representation at all; a canonical
  -- Attempt is sufficient and must not be supplemented by guessed legacy data.
  select 'legacy_request_without_backfill_attempt'::text, count(*)
  from public.requests r
  where r.test_context_id is null
    and not exists (
      select 1
      from public.request_attempts a
      where a.household_id = r.household_id
        and a.request_id = r.id
    );
$$;

revoke all on function private.canonical_foundation_reconciliation_v1()
  from public, anon, authenticated;
grant execute on function private.canonical_foundation_reconciliation_v1()
  to service_role;

