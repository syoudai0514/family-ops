-- Preserve the long-standing public adapter contract while the canonical
-- command remains responsible for cross-household ActorRef validation.
alter function public.server_tx_send_request(uuid,uuid,uuid,text,text,timestamptz)
  rename to server_tx_send_request_dd4_legacy_impl_v1;

create function public.server_tx_send_request(
  p_actor_id uuid,
  p_operation_id uuid,
  p_recipient_user_id uuid,
  p_shared_title text,
  p_shared_message text,
  p_due_at timestamptz
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
begin
  -- This is an input error, not a household-membership disclosure.  Keep the
  -- legacy public command contract stable for existing callers and tests.
  if p_recipient_user_id is not null and p_recipient_user_id = p_actor_id then
    raise exception 'INVALID_INPUT';
  end if;
  return public.server_tx_send_request_dd4_legacy_impl_v1(
    p_actor_id,p_operation_id,p_recipient_user_id,p_shared_title,p_shared_message,p_due_at
  );
end;
$$;

revoke all on function public.server_tx_send_request(uuid,uuid,uuid,text,text,timestamptz)
  from public, anon, authenticated;
grant execute on function public.server_tx_send_request(uuid,uuid,uuid,text,text,timestamptz)
  to service_role;
