-- Issue #48 / Q4,Q70,Q71: a LINE follow-up must resolve only the sender's
-- own most recent conversation item.  This is deliberately a server-only
-- read over the existing pending_actions state machine: it does not invent a
-- second mutation contract and it keeps webhook replay idempotency intact.

create or replace function public.server_tx_get_line_conversation_pending(
  p_actor_id uuid,
  p_line_user_id text
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare v_row record;
begin
  if p_actor_id is null or coalesce(p_line_user_id, '') = '' then
    raise exception 'INVALID_INPUT';
  end if;

  -- Lazily make an elapsed draft visibly terminal before returning it.  A
  -- delayed LINE correction may then never revive it as a fresh draft.
  update private.pending_actions pa
  set status = 'expired'
  from private.line_user_links link
  where pa.actor_id = p_actor_id
    and pa.source = 'line'
    and pa.status = 'draft'
    and pa.expires_at <= now()
    and link.user_id = pa.actor_id
    and link.household_id = pa.household_id
    and link.line_user_id = p_line_user_id
    and link.status = 'active';

  select pa.id, pa.household_id, pa.actor_id, pa.action_type,
         pa.normalized_payload, pa.status, pa.expires_at, pa.updated_at
    into v_row
  from private.pending_actions pa
  join private.line_user_links link
    on link.user_id = pa.actor_id
   and link.household_id = pa.household_id
   and link.line_user_id = p_line_user_id
   and link.status = 'active'
  where pa.actor_id = p_actor_id
    and pa.source = 'line'
  order by pa.updated_at desc, pa.created_at desc
  limit 1;

  if not found then return null; end if;
  return jsonb_build_object(
    'id', v_row.id,
    'household_id', v_row.household_id,
    'actor_id', v_row.actor_id,
    'action_type', v_row.action_type,
    'normalized_payload', v_row.normalized_payload,
    'status', v_row.status,
    'expires_at', v_row.expires_at,
    'updated_at', v_row.updated_at
  );
end;
$$;

revoke all on function public.server_tx_get_line_conversation_pending(uuid, text) from public, anon, authenticated;
grant execute on function public.server_tx_get_line_conversation_pending(uuid, text) to service_role;
