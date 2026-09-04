-- Final DD11 source-review gate.  Run after all feature/adversarial fixtures
-- and require every blocking readiness audit class to be zero.  This is broader
-- than the earlier subset assertions and prevents a later test from leaving a
-- P1 blocker hidden behind a green SQL suite.
\set ON_ERROR_STOP on
set role service_role;

do $$
declare
  v_total bigint;
  v_issues jsonb;
begin
  select coalesce(sum(issue_count), 0),
         coalesce(jsonb_object_agg(audit_name, issue_count), '{}'::jsonb)
    into v_total, v_issues
  from private.canonical_cutover_readiness_audit_v1()
  where blocks_p1;

  if v_total <> 0 then
    raise exception 'FAIL DD11 full readiness final gate: %', v_issues;
  end if;
end;
$$;

reset role;
select '98_dd11_full_readiness_zero: PASS' as result;
