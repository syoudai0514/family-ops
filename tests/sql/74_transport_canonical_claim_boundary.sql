-- Regression for the transport/canonical-receipt privilege boundary.
-- The transport server commands may enter the internal canonical claim path, while
-- service_role/browser roles still cannot call the generic claim primitive directly.
\set ON_ERROR_STOP on

set role service_role;

do $$
begin
  if has_function_privilege(
    'service_role',
    'private.fn_claim_canonical_operation_v1(uuid,uuid,uuid,uuid,uuid,text,text)',
    'EXECUTE'
  ) then
    raise exception 'FAIL transport boundary: generic claim helper exposed to service_role';
  end if;

  if not has_function_privilege(
    'service_role',
    'public.server_tx_save_transport_template(uuid,uuid,date,jsonb)',
    'EXECUTE'
  ) or not has_function_privilege(
    'service_role',
    'public.server_tx_set_transport_occurrence_override(uuid,uuid,date,boolean,uuid,boolean,uuid,text)',
    'EXECUTE'
  ) or not has_function_privilege(
    'service_role',
    'public.server_tx_delete_transport_occurrence_override(uuid,uuid,date)',
    'EXECUTE'
  ) then
    raise exception 'FAIL transport boundary: service_role cannot execute transport command wrapper';
  end if;

  if has_function_privilege(
    'authenticated',
    'public.server_tx_save_transport_template(uuid,uuid,date,jsonb)',
    'EXECUTE'
  ) or has_function_privilege(
    'authenticated',
    'public.server_tx_set_transport_occurrence_override(uuid,uuid,date,boolean,uuid,boolean,uuid,text)',
    'EXECUTE'
  ) or has_function_privilege(
    'authenticated',
    'public.server_tx_delete_transport_occurrence_override(uuid,uuid,date)',
    'EXECUTE'
  ) or has_function_privilege(
    'anon',
    'public.server_tx_save_transport_template(uuid,uuid,date,jsonb)',
    'EXECUTE'
  ) then
    raise exception 'FAIL transport boundary: browser role can execute transport command wrapper';
  end if;

  if not (
    select p.prosecdef
    from pg_proc p
    where p.oid = 'public.server_tx_save_transport_template(uuid,uuid,date,jsonb)'::regprocedure
  ) or not (
    select p.prosecdef
    from pg_proc p
    where p.oid = 'public.server_tx_set_transport_occurrence_override(uuid,uuid,date,boolean,uuid,boolean,uuid,text)'::regprocedure
  ) or not (
    select p.prosecdef
    from pg_proc p
    where p.oid = 'public.server_tx_delete_transport_occurrence_override(uuid,uuid,date)'::regprocedure
  ) then
    raise exception 'FAIL transport boundary: mutation wrapper is not SECURITY DEFINER';
  end if;
end;
$$;

reset role;
select '74_transport_canonical_claim_boundary: PASS' as result;
