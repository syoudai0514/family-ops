-- Follow-up to 20260903030020: preserve the precise Google test-leakage
-- predicate introduced by 20260903030013 while adding the new unresolved
-- provider-mutation fence gate.  This is forward-only rather than rewriting
-- either prior migration.
create or replace function private.canonical_cutover_readiness_audit_v1()
returns table(audit_name text,issue_count bigint,blocks_p1 boolean)
language sql stable security definer set search_path='' as $$
  select 'canonical_'||r.issue_type,r.issue_count,true
  from private.canonical_foundation_reconciliation_v1() r
  union all
  select 'capability_not_r0',count(*),true
  from private.canonical_capability_gates
  where release_stage<>'R0' or reader_enabled or writer_enabled or not mutation_paused or p1_crossed_at is not null
  union all
  select 'production_notification_test_leakage',count(*),true
  from public.user_notifications where test_context_id is not null
  union all
  select 'production_outbox_test_leakage',count(*),true
  from private.notification_outbox where test_context_id is not null
  union all
  select 'google_write_test_leakage',count(*),true
  from private.google_write_operations where test_context_id is not null
  union all
  select 'google_projection_test_leakage',count(*),true
  from private.family_ops_calendar_mirrors m
  join public.task_instances t on t.id=m.task_instance_id and t.household_id=m.household_id
  where t.test_context_id is not null
    and nullif(btrim(coalesce(m.provider_event_id,'')),'') is not null
  union all
  select 'provider_mutation_owner_overlap',count(*),true
  from private.canonical_google_provider_owner_audit_v1() a where a.active_owner_count>1
  union all
  select 'provider_mutation_fence_unresolved',count(*),true
  from private.google_provider_mutation_fences f where f.state in ('inflight','uncertain')
  union all
  select 'family_event_p1_unrevalidated_orphan',count(*),true
  from private.canonical_google_provider_owner_audit_v1() a
  join private.canonical_capability_gates g on g.capability='family_event_authority_v1'
  where g.release_stage='P1' and a.orphan_blocked;
$$;
revoke all on function private.canonical_cutover_readiness_audit_v1() from public,anon,authenticated;
grant execute on function private.canonical_cutover_readiness_audit_v1() to service_role;
