-- DD11 final-readiness semantics for canonical Shopping assignment.
-- The original R0 reconciliation predates DD5B's explicit `anyone` mode and
-- therefore treated every null legacy assignee as `unassigned`.  Once the
-- canonical Shopping writer is present, `anyone` is a valid authoritative
-- state: both legacy assignee_id and canonical assignee_actor_ref_id are null,
-- while claim ownership is represented separately by active_claimant_actor_ref_id.
-- Preserve all other reconciliation checks and replace only this stale predicate.

alter function private.canonical_foundation_reconciliation_v1()
  rename to canonical_recon_v1_pre_dd11_shopping_assignment;

create or replace function private.canonical_foundation_reconciliation_v1()
returns table(issue_type text, issue_count bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select r.issue_type, r.issue_count
  from private.canonical_recon_v1_pre_dd11_shopping_assignment() r
  where r.issue_type <> 'shopping_assignee_actor_mismatch'

  union all

  select 'shopping_assignee_actor_mismatch'::text, count(*)
  from public.shopping_items s
  left join public.domain_actor_refs a
    on a.id = s.assignee_actor_ref_id
   and a.household_id = s.household_id
  where s.test_context_id is null
    and case
      when s.assignment_mode = 'person' then
        s.assignee_id is null
        or s.assignee_actor_ref_id is null
        or a.id is null
        or a.actor_kind <> 'real_user'
        or a.real_user_id is distinct from s.assignee_id
      when s.assignment_mode in ('unassigned', 'anyone') then
        s.assignee_id is not null
        or s.assignee_actor_ref_id is not null
      else true
    end;
$$;

revoke all on function private.canonical_foundation_reconciliation_v1()
  from public, anon, authenticated;
grant execute on function private.canonical_foundation_reconciliation_v1()
  to service_role;
