-- Follow-up to 20260824000004: subtasks-mode parents intentionally keep
-- actual_completed_by_id NULL (the per-subtask completed_by fields are the
-- actor record). Preserve that invariant while retaining optional-only list
-- behavior.
create or replace function public.server_tx_set_subtask_completion(
  p_actor_id uuid,
  p_operation_id uuid,
  p_subtask_instance_id uuid,
  p_completed boolean,
  p_completion_actor text
) returns jsonb
language plpgsql
set search_path to ''
as $$
declare
  v_request_hash text;
  v_receipt record;
  v_household_id uuid;
  v_subtask record;
  v_task record;
  v_resolved_actor uuid;
  v_required_total int;
  v_remaining_required int;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_subtask_instance_id is null or p_completed is null then
    raise exception 'INVALID_INPUT';
  end if;
  if p_completion_actor not in ('self', 'partner') then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to(
      'set-subtask-completion|' || p_subtask_instance_id::text || '|' || p_completed::text
        || '|' || p_completion_actor,
      'UTF8'
    )),
    'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'set-subtask-completion', v_request_hash)
    on conflict (actor_id, operation_id) do nothing;
    if found then exit; end if;

    select * into v_receipt
    from private.mutation_receipts
    where actor_id = p_actor_id and operation_id = p_operation_id
    for update;
    if found then
      if v_receipt.request_hash <> v_request_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
      return v_receipt.result_payload;
    end if;
  end loop;

  select household_id into v_household_id
  from public.household_members
  where user_id = p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;

  if p_completion_actor = 'self' then
    v_resolved_actor := p_actor_id;
  else
    select user_id into v_resolved_actor
    from public.household_members
    where household_id = v_household_id and user_id <> p_actor_id
    limit 1;
    if v_resolved_actor is null then raise exception 'INVALID_INPUT'; end if;
  end if;

  select * into v_subtask
  from public.task_subtask_instances
  where household_id = v_household_id and id = p_subtask_instance_id
  for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;

  select * into v_task
  from public.task_instances
  where household_id = v_household_id and id = v_subtask.task_instance_id
  for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if v_task.status not in ('todo', 'in_progress', 'completed') then raise exception 'TASK_TERMINAL'; end if;

  if p_completed then
    update public.task_subtask_instances
    set is_completed = true, completed_by = v_resolved_actor, completed_at = now()
    where household_id = v_household_id and id = p_subtask_instance_id;
  else
    update public.task_subtask_instances
    set is_completed = false, completed_by = null, completed_at = null
    where household_id = v_household_id and id = p_subtask_instance_id;
  end if;

  select
    count(*) filter (where required),
    count(*) filter (where required and not is_completed)
  into v_required_total, v_remaining_required
  from public.task_subtask_instances
  where household_id = v_household_id and task_instance_id = v_task.id;

  if v_required_total > 0 and v_remaining_required = 0 and v_task.status <> 'completed' then
    update public.task_instances
    set status = 'completed', completed_at = now()
    where household_id = v_household_id and id = v_task.id;
  elsif v_required_total > 0 and v_remaining_required > 0 and v_task.status = 'completed' then
    update public.task_instances
    set status = 'in_progress', completed_at = null
    where household_id = v_household_id and id = v_task.id;
  end if;

  insert into public.task_events
    (household_id, task_instance_id, actor_id, event_type, source, idempotency_key)
  values
    (v_household_id, v_task.id, p_actor_id, 'subtask_completed', 'pwa', p_operation_id::text || ':subtask');

  v_result := jsonb_build_object('ok', true);
  update private.mutation_receipts
  set result_type = 'task_subtask_instance', result_id = p_subtask_instance_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;
  return v_result;
end;
$$;
revoke all on function public.server_tx_set_subtask_completion(uuid,uuid,uuid,boolean,text) from public,anon,authenticated;
grant execute on function public.server_tx_set_subtask_completion(uuid,uuid,uuid,boolean,text) to service_role;
