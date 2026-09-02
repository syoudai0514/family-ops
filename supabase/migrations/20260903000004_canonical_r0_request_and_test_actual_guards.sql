-- Canonical detailed-design implementation, Batch 1A source-review remediation.
--
-- This migration closes two R0 compatibility holes without activating any
-- canonical reader/writer:
--   1. test-scoped Tasks may never carry a legacy real-user actual performer;
--      canonical participants are the only performer identity in test scope;
--   2. the rerunnable R0 backfill must resynchronise the single historical
--      legacy-backfill Request Attempt when the still-active old runtime changes
--      the legacy Request lifecycle tuple after the first backfill.

-- ---------------------------------------------------------------------------
-- Test-scope actual performer identity
-- ---------------------------------------------------------------------------

-- A test-scoped Task must not use task_instances.actual_completed_by_id as a
-- compatibility substitute for a simulated (or real) domain actor. Test-mode
-- performer truth is represented only by task_actual_participants/ActorRef.
-- Production R0/R1 rows remain unchanged and continue to satisfy the CURRENT
-- whole-completion compatibility CHECK.
alter table public.task_instances
  add constraint task_instances_test_scope_legacy_actual_null_chk
  check (test_context_id is null or actual_completed_by_id is null);

-- ---------------------------------------------------------------------------
-- R0 Request lifecycle resynchronisation
-- ---------------------------------------------------------------------------

-- Preserve the already-reviewed Batch-1A backfill implementation as the base
-- pass, then wrap it with a deterministic Request lifecycle resync. This keeps
-- existing counters/behaviour intact while making the public v1 helper fully
-- convergent for old-runtime Request writes during R0/R1.
alter function private.backfill_canonical_foundation_v1()
  rename to backfill_canonical_foundation_v1_base;

create or replace function private.resync_legacy_request_backfill_attempts_v1()
returns integer
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_rows integer := 0;
begin
  with expected as (
    select
      r.id as request_id,
      r.requester_actor_ref_id as created_by_actor_ref_id,
      case r.status
        when 'pending' then 'pending'
        when 'accepted' then 'accepted'
        when 'completed' then 'accepted'
        when 'declined' then 'declined'
        when 'cancelled' then 'cancelled'
      end as expected_state,
      jsonb_build_object('legacy_status', r.status) as expected_terms,
      case when r.status in ('accepted', 'completed') then r.accepted_at else null end as expected_accepted_at,
      case when r.status = 'declined' then r.declined_at else null end as expected_declined_at,
      case when r.status = 'cancelled' then r.cancelled_at else null end as expected_cancelled_at
    from public.requests r
    where r.test_context_id is null
      and r.requester_actor_ref_id is not null
  )
  update public.request_attempts a
  set state = e.expected_state,
      terms = e.expected_terms,
      created_by_actor_ref_id = e.created_by_actor_ref_id,
      accepted_at = e.expected_accepted_at,
      declined_at = e.expected_declined_at,
      expired_at = null,
      cancelled_at = e.expected_cancelled_at,
      revision = a.revision + 1
  from expected e
  where a.request_id = e.request_id
    and a.legacy_backfill
    and (
      a.state is distinct from e.expected_state
      or a.terms is distinct from e.expected_terms
      or a.created_by_actor_ref_id is distinct from e.created_by_actor_ref_id
      or a.accepted_at is distinct from e.expected_accepted_at
      or a.declined_at is distinct from e.expected_declined_at
      or a.expired_at is not null
      or a.cancelled_at is distinct from e.expected_cancelled_at
    );
  get diagnostics v_rows = row_count;
  return v_rows;
end;
$$;

revoke all on function private.resync_legacy_request_backfill_attempts_v1()
  from public, anon, authenticated;
grant execute on function private.resync_legacy_request_backfill_attempts_v1()
  to service_role;

create or replace function private.backfill_canonical_foundation_v1()
returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_base jsonb;
  v_request_attempts_resynced integer;
begin
  v_base := private.backfill_canonical_foundation_v1_base();
  v_request_attempts_resynced := private.resync_legacy_request_backfill_attempts_v1();

  return v_base || jsonb_build_object(
    'request_attempts_resynced', v_request_attempts_resynced
  );
end;
$$;

revoke all on function private.backfill_canonical_foundation_v1()
  from public, anon, authenticated;
grant execute on function private.backfill_canonical_foundation_v1()
  to service_role;

-- Extend reconciliation rather than replacing the already-reviewed checks.
alter function private.canonical_foundation_reconciliation_v1()
  rename to canonical_foundation_reconciliation_v1_base;

create or replace function private.canonical_foundation_reconciliation_v1()
returns table(issue_type text, issue_count bigint)
language sql
stable
security definer
set search_path = ''
as $$
  select *
  from private.canonical_foundation_reconciliation_v1_base()

  union all

  select 'legacy_request_backfill_attempt_mismatch'::text, count(*)
  from public.requests r
  join public.request_attempts a
    on a.request_id = r.id
   and a.household_id = r.household_id
   and a.legacy_backfill
  where r.test_context_id is null
    and (
      a.state is distinct from (
        case r.status
          when 'pending' then 'pending'
          when 'accepted' then 'accepted'
          when 'completed' then 'accepted'
          when 'declined' then 'declined'
          when 'cancelled' then 'cancelled'
        end
      )
      or a.created_by_actor_ref_id is distinct from r.requester_actor_ref_id
      or a.terms is distinct from jsonb_build_object('legacy_status', r.status)
      or a.accepted_at is distinct from (
        case when r.status in ('accepted', 'completed') then r.accepted_at else null end
      )
      or a.declined_at is distinct from (
        case when r.status = 'declined' then r.declined_at else null end
      )
      or a.expired_at is not null
      or a.cancelled_at is distinct from (
        case when r.status = 'cancelled' then r.cancelled_at else null end
      )
    );
$$;

revoke all on function private.canonical_foundation_reconciliation_v1()
  from public, anon, authenticated;
grant execute on function private.canonical_foundation_reconciliation_v1()
  to service_role;

-- Converge any rows that could have changed between the previous migration's
-- initial pass and this migration. This remains R0/R1 compatibility only; no
-- canonical reader or command path is activated here.
select private.backfill_canonical_foundation_v1();
