\set ON_ERROR_STOP on
set role service_role;

do $$
begin
  if exists(select 1 from private.canonical_cutover_readiness_audit_v1()
    where audit_name='capability_not_r0' and issue_count<>0) then
    raise exception 'FAIL DD11: source readiness unexpectedly crossed R0/P1 gate'; end if;
  if exists(select 1 from private.canonical_cutover_readiness_audit_v1()
    where audit_name in ('production_notification_test_leakage','production_outbox_test_leakage','google_write_test_leakage','google_projection_test_leakage')
      and issue_count<>0) then
    raise exception 'FAIL DD11: test/provider safety audit is not clean'; end if;
end;
$$;

reset role;
select '49_dd11_cutover_readiness_audits: PASS' as result;
