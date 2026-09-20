-- Purpose-first PF-07: bind a reviewed assignment proposal to the exact
-- current task revision. Existing callers remain on the v1 adapter.
create or replace function public.server_tx_create_assignment_change_request_v2(
  p_actor_id uuid,
  p_operation_id uuid,
  p_task_id uuid,
  p_recipient_user_id uuid,
  p_shared_message text,
  p_scope text,
  p_expected_task_revision integer
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_context jsonb;
  v_household_id uuid;
  v_actor_ref_id uuid;
  v_task public.task_instances%rowtype;
begin
  if p_expected_task_revision is null then
    raise exception 'INVALID_INPUT';
  end if;

  v_context := private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id := (v_context->>'household_id')::uuid;
  v_actor_ref_id := (v_context->>'actor_ref_id')::uuid;

  select * into v_task
  from public.task_instances
  where household_id = v_household_id
    and id = p_task_id
    and test_context_id is null
  for update;

  if not found then
    raise exception 'TASK_NOT_FOUND';
  end if;
  if v_task.revision <> p_expected_task_revision
     or v_task.status not in ('todo', 'in_progress')
     or v_task.planned_assignee_actor_ref_id is distinct from v_actor_ref_id then
    raise exception 'ASSIGNMENT_PROPOSAL_STALE';
  end if;

  return public.server_tx_create_assignment_change_request(
    p_actor_id,
    p_operation_id,
    p_task_id,
    p_recipient_user_id,
    p_shared_message,
    p_scope
  );
end;
$$;

revoke all on function public.server_tx_create_assignment_change_request_v2(
  uuid, uuid, uuid, uuid, text, text, integer
) from public, anon, authenticated;
grant execute on function public.server_tx_create_assignment_change_request_v2(
  uuid, uuid, uuid, uuid, text, text, integer
) to service_role;
