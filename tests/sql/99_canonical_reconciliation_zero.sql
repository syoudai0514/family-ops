-- Final suite gate: valid source-review fixtures must leave no canonical
-- foundation reconciliation issue behind.  Keeping this last in lexical order
-- prevents later tests from introducing a blocker after an earlier zero check.
\set ON_ERROR_STOP on
set role service_role;

do $$
declare
  v_total bigint;
  v_issues jsonb;
begin
  select coalesce(sum(issue_count), 0),
         coalesce(jsonb_object_agg(issue_type, issue_count), '{}'::jsonb)
    into v_total, v_issues
  from private.canonical_foundation_reconciliation_v1();

  if v_total <> 0 then
    raise exception 'FAIL canonical reconciliation final gate: %', v_issues;
  end if;
end;
$$;

reset role;
select '99_canonical_reconciliation_zero: PASS' as result;
