-- Canonical accepted Requests create an agreement-owned Task.  It is not a
-- legacy snapshot and must not be reported as a legacy-assignment mismatch.
alter function private.canonical_foundation_reconciliation_v1()
  rename to canonical_foundation_reconciliation_v1_pre_request_task_authority;

create function private.canonical_foundation_reconciliation_v1()
returns table(issue_type text, issue_count bigint)
language sql stable security definer set search_path='' as $$
  select r.issue_type,r.issue_count
  from private.canonical_foundation_reconciliation_v1_pre_request_task_authority() r
  where r.issue_type <> 'task_planned_actor_mismatch'

  union all

  select 'task_planned_actor_mismatch'::text,count(*)
  from public.task_instances t
  left join public.domain_actor_refs a
    on a.id=t.planned_assignee_actor_ref_id and a.household_id=t.household_id
  where t.test_context_id is null
    and (
      (
        t.origin='request' and t.source='canonical_request'
        and (
          t.planned_assignee_id is null
          or t.assignment_mode is distinct from 'person'
          or t.assignment_source is distinct from 'agreement'
          or a.id is null
          or a.real_user_id is distinct from t.planned_assignee_id
        )
      )
      or
      (
        not (t.origin='request' and t.source='canonical_request')
        and (
          (t.planned_assignee_id is null
            and (t.assignment_mode is distinct from 'unassigned'
              or t.planned_assignee_actor_ref_id is not null
              or t.assignment_source is distinct from 'legacy_snapshot'))
          or
          (t.planned_assignee_id is not null
            and (t.assignment_mode is distinct from 'person'
              or a.id is null
              or a.real_user_id is distinct from t.planned_assignee_id
              or t.assignment_source is distinct from 'legacy_snapshot'))
        )
      )
    );
$$;

revoke all on function private.canonical_foundation_reconciliation_v1()
  from public, anon, authenticated;
grant execute on function private.canonical_foundation_reconciliation_v1() to service_role;
