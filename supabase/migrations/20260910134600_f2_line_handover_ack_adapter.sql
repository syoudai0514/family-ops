-- F2 LINE handover acknowledgement adapter.
-- Keep the existing private canonical info.ack command as the single mutation
-- truth; expose only a service-role server_tx boundary for the LINE worker.

create or replace function public.server_tx_ack_info_v1(
  p_actor_id uuid,
  p_operation_id uuid,
  p_handover_id uuid
) returns jsonb
language plpgsql
security definer
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_actor_ref_id uuid;
begin
  if p_actor_id is null or p_operation_id is null or p_handover_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  select hm.household_id into v_household_id
  from public.household_members hm
  where hm.user_id = p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;

  select a.id into v_actor_ref_id
  from public.domain_actor_refs a
  where a.household_id = v_household_id
    and a.actor_kind = 'real_user'
    and a.real_user_id = p_actor_id
    and a.test_context_id is null;
  if v_actor_ref_id is null then raise exception 'ACTOR_REF_NOT_FOUND'; end if;

  if not exists (
    select 1
    from public.handovers h
    where h.household_id = v_household_id
      and h.id = p_handover_id
      and h.test_context_id is null
      and h.status = 'active'
      and h.visibility = 'household'
      and h.ack_policy = 'required'
  ) then
    raise exception 'INFO_ACK_NOT_ACTIONABLE';
  end if;

  return private.fn_command_ack_info_v1(
    v_household_id,
    p_actor_id,
    v_actor_ref_id,
    null,
    p_handover_id,
    p_operation_id
  );
end;
$$;

revoke all on function public.server_tx_ack_info_v1(uuid, uuid, uuid)
  from public, anon, authenticated;
grant execute on function public.server_tx_ack_info_v1(uuid, uuid, uuid)
  to service_role;
