-- Preserve the legacy public RPC error contract.  The canonical attempt
-- transition still enforces ActorRef roles; these adapters prevent the new
-- lower-level transition error from leaking to established callers.
alter function public.server_tx_decline_request(uuid,uuid,uuid)
  rename to server_tx_decline_request_dd4_contract_impl_v1;

create function public.server_tx_decline_request(
  p_actor_id uuid,p_operation_id uuid,p_request_id uuid
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare c jsonb; h uuid; a uuid; r public.requests%rowtype;
begin
  c:=private.fn_require_production_actor_context_v1(p_actor_id);
  h:=(c->>'household_id')::uuid; a:=(c->>'actor_ref_id')::uuid;
  select * into r from public.requests where household_id=h and id=p_request_id;
  if not found then raise exception 'REQUEST_NOT_FOUND'; end if;
  if r.recipient_actor_ref_id is distinct from a then raise exception 'REQUEST_NOT_RECIPIENT'; end if;
  return public.server_tx_decline_request_dd4_contract_impl_v1(p_actor_id,p_operation_id,p_request_id);
end;
$$;

alter function public.server_tx_cancel_request(uuid,uuid,uuid)
  rename to server_tx_cancel_request_dd4_contract_impl_v1;

create function public.server_tx_cancel_request(
  p_actor_id uuid,p_operation_id uuid,p_request_id uuid
) returns jsonb language plpgsql security invoker set search_path='' as $$
declare c jsonb; h uuid; a uuid; r public.requests%rowtype;
begin
  c:=private.fn_require_production_actor_context_v1(p_actor_id);
  h:=(c->>'household_id')::uuid; a:=(c->>'actor_ref_id')::uuid;
  select * into r from public.requests where household_id=h and id=p_request_id;
  if not found then raise exception 'REQUEST_NOT_FOUND'; end if;
  if r.requester_actor_ref_id is distinct from a then raise exception 'REQUEST_NOT_REQUESTER'; end if;
  return public.server_tx_cancel_request_dd4_contract_impl_v1(p_actor_id,p_operation_id,p_request_id);
end;
$$;

revoke all on function public.server_tx_decline_request(uuid,uuid,uuid)
  from public, anon, authenticated;
revoke all on function public.server_tx_cancel_request(uuid,uuid,uuid)
  from public, anon, authenticated;
grant execute on function public.server_tx_decline_request(uuid,uuid,uuid) to service_role;
grant execute on function public.server_tx_cancel_request(uuid,uuid,uuid) to service_role;
