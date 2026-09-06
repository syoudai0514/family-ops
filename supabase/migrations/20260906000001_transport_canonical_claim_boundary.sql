-- Issue #48 transport command boundary closeout.
--
-- DD9 deliberately made private.fn_claim_canonical_operation_v1 internal-only:
-- service_role must not be able to supply an arbitrary action_type/request_hash to
-- the generic SECURITY DEFINER claim helper.  The transport mutation wrappers were
-- added later as SECURITY INVOKER functions, which meant they could no longer enter
-- that internal canonical receipt boundary when invoked by service_role.
--
-- Keep the generic helper locked down.  Instead, make only the three fixed-shape
-- transport mutation commands SECURITY DEFINER, matching the canonical command
-- pattern: action type and request hash are derived inside trusted command code,
-- search_path is empty, and only service_role may execute the public server wrapper.

alter function public.server_tx_save_transport_template(uuid, uuid, date, jsonb)
  security definer;
alter function public.server_tx_set_transport_occurrence_override(
  uuid, uuid, date, boolean, uuid, boolean, uuid, text
) security definer;
alter function public.server_tx_delete_transport_occurrence_override(uuid, uuid, date)
  security definer;

-- Reassert the externally callable boundary.  Never expose these server transaction
-- wrappers to browser roles.
revoke all on function public.server_tx_save_transport_template(uuid, uuid, date, jsonb)
  from public, anon, authenticated;
revoke all on function public.server_tx_set_transport_occurrence_override(
  uuid, uuid, date, boolean, uuid, boolean, uuid, text
) from public, anon, authenticated;
revoke all on function public.server_tx_delete_transport_occurrence_override(uuid, uuid, date)
  from public, anon, authenticated;

grant execute on function public.server_tx_save_transport_template(uuid, uuid, date, jsonb)
  to service_role;
grant execute on function public.server_tx_set_transport_occurrence_override(
  uuid, uuid, date, boolean, uuid, boolean, uuid, text
) to service_role;
grant execute on function public.server_tx_delete_transport_occurrence_override(uuid, uuid, date)
  to service_role;

-- Preserve the DD9 provenance fence: service_role must still be unable to call the
-- generic claim primitive directly.
revoke execute on function private.fn_claim_canonical_operation_v1(
  uuid, uuid, uuid, uuid, uuid, text, text
) from service_role;
revoke all on function private.fn_claim_canonical_operation_v1(
  uuid, uuid, uuid, uuid, uuid, text, text
) from public, anon, authenticated;

do $$
begin
  if has_function_privilege(
    'service_role',
    'private.fn_claim_canonical_operation_v1(uuid,uuid,uuid,uuid,uuid,text,text)',
    'EXECUTE'
  ) then
    raise exception 'TRANSPORT_BOUNDARY_GENERIC_CLAIM_EXPOSED';
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
    raise exception 'TRANSPORT_BOUNDARY_COMMAND_NOT_SECURITY_DEFINER';
  end if;
end;
$$;
