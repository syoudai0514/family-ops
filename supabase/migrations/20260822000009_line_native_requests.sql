-- LINE-native natural-language actions: keep sender preview/correction and
-- recipient accept/decline entirely in LINE. Forward-only migration.

-- Actor-scoped read used by LINE postback correction. Draft text never becomes
-- household-readable merely because it came from LINE.
create or replace function public.server_tx_get_pending_action(
  p_actor_id uuid,
  p_pending_action_id uuid
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  if p_actor_id is null or p_pending_action_id is null then
    raise exception 'INVALID_INPUT';
  end if;
  select jsonb_build_object(
    'id', pa.id,
    'action_type', pa.action_type,
    'normalized_payload', pa.normalized_payload,
    'status', pa.status,
    'expires_at', pa.expires_at
  ) into v_result
  from private.pending_actions pa
  where pa.id = p_pending_action_id
    and pa.actor_id = p_actor_id
    and pa.status = 'draft'
    and pa.expires_at > now();
  if v_result is null then raise exception 'PENDING_ACTION_NOT_EDITABLE'; end if;
  return v_result;
end;
$$;

create or replace function public.server_tx_update_pending_action(
  p_actor_id uuid,
  p_pending_action_id uuid,
  p_action_type text,
  p_normalized_payload jsonb
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_result jsonb;
begin
  if p_actor_id is null or p_pending_action_id is null
     or p_action_type not in ('shopping_item_add','task_create_once','request_create','assignment_change_request','needs_pwa_review')
     or p_normalized_payload is null
     or jsonb_typeof(p_normalized_payload) <> 'object' then
    raise exception 'INVALID_INPUT';
  end if;

  update private.pending_actions
  set action_type = p_action_type,
      normalized_payload = p_normalized_payload,
      updated_at = now()
  where id = p_pending_action_id
    and actor_id = p_actor_id
    and status = 'draft'
    and expires_at > now()
  returning jsonb_build_object(
    'id', id,
    'action_type', action_type,
    'normalized_payload', normalized_payload,
    'status', status,
    'expires_at', expires_at
  ) into v_result;

  if v_result is null then raise exception 'PENDING_ACTION_NOT_EDITABLE'; end if;
  return v_result;
end;
$$;

revoke all on function public.server_tx_get_pending_action(uuid, uuid) from public, anon, authenticated;
revoke all on function public.server_tx_update_pending_action(uuid, uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.server_tx_get_pending_action(uuid, uuid) to service_role;
grant execute on function public.server_tx_update_pending_action(uuid, uuid, text, jsonb) to service_role;

-- General requests need their canonical request id in the notification payload
-- so LINE can render recipient-side accept/decline actions. Also strengthen the
-- idempotency hash to cover the complete request payload.
create or replace function public.server_tx_send_request(
  p_actor_id uuid,
  p_operation_id uuid,
  p_recipient_user_id uuid,
  p_shared_title text,
  p_shared_message text,
  p_due_at timestamptz
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_request_hash text;
  v_receipt record;
  v_household_id uuid;
  v_request_id uuid;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_recipient_user_id is null then
    raise exception 'INVALID_INPUT';
  end if;
  if coalesce(btrim(p_shared_title), '') = '' or p_recipient_user_id = p_actor_id then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(sha256(convert_to(
    concat_ws('|', 'send-request-v2', p_recipient_user_id::text, btrim(p_shared_title),
      coalesce(btrim(p_shared_message), ''), coalesce(p_due_at::text, '')),
    'UTF8'
  )), 'hex');

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'send-request-v2', v_request_hash)
    on conflict (actor_id, operation_id) do nothing;
    if found then exit; end if;

    select * into v_receipt from private.mutation_receipts
    where actor_id = p_actor_id and operation_id = p_operation_id for update;
    if found then
      if v_receipt.request_hash <> v_request_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
      return v_receipt.result_payload;
    end if;
  end loop;

  select household_id into v_household_id from public.household_members where user_id = p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  if not exists (
    select 1 from public.household_members
    where household_id = v_household_id and user_id = p_recipient_user_id
  ) then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;

  insert into public.requests
    (household_id, requester_id, recipient_id, shared_title, shared_message, due_at, status)
  values
    (v_household_id, p_actor_id, p_recipient_user_id, btrim(p_shared_title),
     nullif(btrim(coalesce(p_shared_message, '')), ''), p_due_at, 'pending')
  returning id into v_request_id;

  insert into public.user_notifications
    (household_id, recipient_user_id, type, title, body, payload, dedup_key)
  values
    (v_household_id, p_recipient_user_id, 'request_received', btrim(p_shared_title),
     coalesce(nullif(btrim(p_shared_message), ''), btrim(p_shared_title)),
     jsonb_build_object(
       'request_id', v_request_id,
       'request_kind', 'general',
       'due_at', p_due_at
     ),
     p_operation_id::text || ':request_received');

  v_result := jsonb_build_object('request_id', v_request_id);
  update private.mutation_receipts
  set result_type = 'request', result_id = v_request_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;
  return v_result;
end;
$$;

revoke all on function public.server_tx_send_request(uuid, uuid, uuid, text, text, timestamptz) from public, anon, authenticated;
grant execute on function public.server_tx_send_request(uuid, uuid, uuid, text, text, timestamptz) to service_role;

-- Assignment-change already used the same enrichment mechanism. General
-- requests now use it too; only canonical request metadata is copied into the
-- outbox item, never the sender's raw LINE text.
create or replace function private.fn_enrich_line_outbox_request_payload()
returns trigger language plpgsql security invoker set search_path = '' as $$
begin
  if new.type <> 'request_received' or coalesce(new.payload->>'request_id', '') = '' then
    return new;
  end if;
  update private.notification_outbox o
  set payload = jsonb_set(o.payload, '{items}', (
    select jsonb_agg(
      case when item->>'user_notification_id' = new.id::text
        then item || jsonb_build_object('payload', new.payload)
        else item end
    )
    from jsonb_array_elements(coalesce(o.payload->'items', '[]'::jsonb)) item
  ))
  where o.household_id = new.household_id
    and o.recipient_user_id = new.recipient_user_id
    and o.status = 'queued'
    and o.payload @> jsonb_build_object(
      'items', jsonb_build_array(jsonb_build_object('user_notification_id', new.id))
    );
  return new;
end;
$$;

revoke all on function private.fn_enrich_line_outbox_request_payload() from public, anon, authenticated;
grant execute on function private.fn_enrich_line_outbox_request_payload() to service_role;
