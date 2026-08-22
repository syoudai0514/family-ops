-- LINE draft correction session.  A sender may type a correction (for
-- example "ママじゃなくてパパ") after tapping 編集.  Keep the selected draft
-- private and actor-scoped; neither a partner nor a browser can enumerate
-- it.  The Edge Function applies the actual structured patch and clears the
-- marker in the same guarded update path as every other pending edit.

create or replace function public.server_tx_get_line_pending_text_edit(
  p_actor_id uuid
)
returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare v_row record;
begin
  if p_actor_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  select id, action_type, normalized_payload, status
    into v_row
  from private.pending_actions
  where actor_id = p_actor_id
    and source = 'line'
    and status = 'draft'
    and expires_at > now()
    and coalesce(normalized_payload->>'line_edit_mode', 'false') = 'true'
  order by updated_at desc, created_at desc
  limit 1;

  if not found then return null; end if;

  return jsonb_build_object(
    'id', v_row.id,
    'action_type', v_row.action_type,
    'normalized_payload', v_row.normalized_payload,
    'status', v_row.status
  );
end;
$$;

revoke all on function public.server_tx_get_line_pending_text_edit(uuid) from public, anon, authenticated;
grant execute on function public.server_tx_get_line_pending_text_edit(uuid) to service_role;
