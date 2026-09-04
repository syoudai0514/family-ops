-- The canonical semantic kind is request.received.  Keep the pre-existing
-- public adapter's notification type stable for legacy clients while retaining
-- notification_kind as the canonical semantic field.
alter function public.server_tx_send_request(uuid,uuid,uuid,text,text,timestamptz)
  rename to server_tx_send_request_dd4_contract_impl_v1;

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
declare v_result jsonb; v_request_id uuid;
begin
  v_result := public.server_tx_send_request_dd4_contract_impl_v1(
    p_actor_id,p_operation_id,p_recipient_user_id,p_shared_title,p_shared_message,p_due_at
  );
  v_request_id := (v_result->>'request_id')::uuid;
  update public.user_notifications
  set type = 'request_received'
  where recipient_user_id = p_recipient_user_id
    and dedup_key = 'request:received:' || v_request_id::text
    and notification_kind = 'request.received';
  return v_result;
end;
$$;

revoke all on function public.server_tx_send_request(uuid,uuid,uuid,text,text,timestamptz)
  from public, anon, authenticated;
grant execute on function public.server_tx_send_request(uuid,uuid,uuid,text,text,timestamptz)
  to service_role;
