-- LINE sender-preview editing. Forward-only: a LINE postback may only read
-- or revise the sender's own, still-unconfirmed draft. These RPCs are worker
-- only; the caller must not be able to inspect or change another household's
-- pending action.

create or replace function public.server_tx_get_pending_action(
  p_actor_id uuid,
  p_pending_action_id uuid
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare v_row record;
begin
  if p_actor_id is null or p_pending_action_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  select id, action_type, normalized_payload, status, expires_at
    into v_row
  from private.pending_actions
  where id = p_pending_action_id and actor_id = p_actor_id
  for update;

  if not found then raise exception 'PENDING_ACTION_NOT_EDITABLE'; end if;
  if v_row.status <> 'draft' or v_row.expires_at <= now() then
    raise exception 'PENDING_ACTION_NOT_EDITABLE';
  end if;

  return jsonb_build_object(
    'id', v_row.id,
    'action_type', v_row.action_type,
    'normalized_payload', v_row.normalized_payload,
    'status', v_row.status
  );
end;
$$;

create or replace function public.server_tx_update_pending_action(
  p_actor_id uuid,
  p_pending_action_id uuid,
  p_action_type text,
  p_normalized_payload jsonb
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare v_row record;
begin
  if p_actor_id is null or p_pending_action_id is null
     or p_action_type not in (
       'shopping_item_add', 'task_create_once', 'request_create', 'assignment_change_request'
     )
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
    and source = 'line'
    and status = 'draft'
    and expires_at > now()
  returning id, action_type, normalized_payload, status into v_row;

  if not found then raise exception 'PENDING_ACTION_NOT_EDITABLE'; end if;
  return jsonb_build_object(
    'id', v_row.id,
    'action_type', v_row.action_type,
    'normalized_payload', v_row.normalized_payload,
    'status', v_row.status
  );
end;
$$;

revoke all on function public.server_tx_get_pending_action(uuid, uuid) from public, anon, authenticated;
revoke all on function public.server_tx_update_pending_action(uuid, uuid, text, jsonb) from public, anon, authenticated;
grant execute on function public.server_tx_get_pending_action(uuid, uuid) to service_role;
grant execute on function public.server_tx_update_pending_action(uuid, uuid, text, jsonb) to service_role;
