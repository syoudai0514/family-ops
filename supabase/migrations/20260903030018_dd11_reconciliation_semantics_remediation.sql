-- DD11 source-review remediation.
-- A downstream Request-specific reconciliation wrapper had accidentally
-- reintroduced the legacy_snapshot-only Task assignment predicate fixed in the
-- canonical foundation.  Restore canonical manual/agreement coexistence and
-- distinguish a confirmed post-accept cancellation from a contradictory
-- terminal Task.

alter function private.canonical_foundation_reconciliation_v1()
  rename to canonical_recon_v1_pre_dd11_fix;

create or replace function private.canonical_foundation_reconciliation_v1()
returns table(issue_type text, issue_count bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select r.issue_type, r.issue_count
  from private.canonical_recon_v1_pre_dd11_fix() r
  where r.issue_type not in (
    'task_planned_actor_mismatch',
    'accepted_request_task_contradictory_terminal'
  )

  union all

  select 'task_planned_actor_mismatch'::text, count(*)
  from public.task_instances t
  left join public.domain_actor_refs a
    on a.id = t.planned_assignee_actor_ref_id
   and a.household_id = t.household_id
  where t.test_context_id is null
    and case
      when t.assignment_source in ('manual', 'agreement') then
        case
          when t.assignment_mode = 'person' then
            t.planned_assignee_actor_ref_id is null
            or a.id is null
            or a.actor_kind <> 'real_user'
            or a.real_user_id is distinct from t.planned_assignee_id
          when t.assignment_mode in ('unassigned', 'anyone') then
            t.planned_assignee_actor_ref_id is not null
            or t.planned_assignee_id is not null
          else true
        end
      else
        (
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
    end

  union all

  select 'accepted_request_task_contradictory_terminal'::text, count(*)
  from public.requests r
  join public.task_instances t
    on t.household_id = r.household_id
   and t.id = r.linked_task_instance_id
  where r.test_context_id is null
    and r.status = 'accepted'
    and (
      t.status = 'skipped'
      or (
        t.status = 'cancelled'
        and not exists (
          select 1
          from public.request_attempts a
          where a.household_id = r.household_id
            and a.request_id = r.id
            and a.test_context_id is null
            and a.attempt_kind = 'cancel'
            and a.state = 'accepted'
        )
      )
    );
$$;
revoke all on function private.canonical_foundation_reconciliation_v1()
  from public, anon, authenticated;
grant execute on function private.canonical_foundation_reconciliation_v1()
  to service_role;
