-- Forward-fix for the DD9 helper's default PUBLIC EXECUTE grant.
revoke all on function private.fn_validate_nursery_structured_value_v1(jsonb)
  from public, anon, authenticated;
grant execute on function private.fn_validate_nursery_structured_value_v1(jsonb)
  to service_role;
