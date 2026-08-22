-- CustomRoutineEditor owns only user-created routine definitions. Built-in
-- evening chores have their own weekday-pattern editor and must never be
-- flattened through the custom-subtask mutation. `code` is the stable domain
-- marker; this deliberately does not inspect translated/display titles.

create or replace function private.is_custom_routine_definition(p_task_kind text, p_code text)
returns boolean language sql immutable security definer set search_path = '' as $$
  select (p_task_kind = 'morning_chore' and (
      starts_with(p_code, 'morning_chore_custom_')
      or starts_with(p_code, 'morning_custom_')
    )) or (p_task_kind = 'evening_chore' and (
      starts_with(p_code, 'evening_chore_custom_')
      or starts_with(p_code, 'evening_custom_')
    ))
$$;
revoke all on function private.is_custom_routine_definition(text,text) from public,anon,authenticated;

create or replace function public.server_tx_replace_routine_subtasks(
  p_actor_id uuid,p_operation_id uuid,p_task_definition_id uuid,p_subtasks jsonb
) returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  v_household uuid; v_hash text; v_receipt record; v_result jsonb; v_subtask jsonb;
  v_existing_id uuid; v_seen_ids uuid[] := '{}'; v_count integer := 0;
  v_code text; v_task_kind text;
begin
  if p_actor_id is null or p_operation_id is null or p_task_definition_id is null
     or jsonb_typeof(p_subtasks) <> 'array' then raise exception 'INVALID_INPUT'; end if;
  select household_id into v_household from public.household_members where user_id=p_actor_id;
  if v_household is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  select code,task_kind into v_code,v_task_kind from public.task_definitions
  where household_id=v_household and id=p_task_definition_id for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if not private.is_custom_routine_definition(v_task_kind,v_code) then
    raise exception 'CUSTOM_ROUTINE_REQUIRED';
  end if;

  v_hash:=encode(sha256(convert_to(jsonb_build_object('definition',p_task_definition_id,'subtasks',p_subtasks)::text,'UTF8')),'hex');
  insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash)
  values(p_actor_id,p_operation_id,'replace-routine-subtasks-v2',v_hash)
  on conflict(actor_id,operation_id) do nothing;
  if not found then
    select * into v_receipt from private.mutation_receipts where actor_id=p_actor_id and operation_id=p_operation_id for update;
    if v_receipt.request_hash<>v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    return v_receipt.result_payload;
  end if;

  for v_subtask in select * from jsonb_array_elements(p_subtasks) loop
    if coalesce(btrim(v_subtask->>'title'),'')='' then raise exception 'INVALID_INPUT'; end if;
    if v_subtask ? 'id' and nullif(v_subtask->>'id','') is not null then
      begin v_existing_id := (v_subtask->>'id')::uuid; exception when invalid_text_representation then raise exception 'INVALID_INPUT'; end;
      update public.task_subtask_definitions
      set title=btrim(v_subtask->>'title'), required=coalesce((v_subtask->>'required')::boolean,true),
          sort_order=v_count, is_active=true
      where household_id=v_household and task_definition_id=p_task_definition_id and id=v_existing_id;
      if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
    else
      insert into public.task_subtask_definitions(household_id,task_definition_id,title,required,sort_order,is_active)
      values(v_household,p_task_definition_id,btrim(v_subtask->>'title'),coalesce((v_subtask->>'required')::boolean,true),v_count,true)
      returning id into v_existing_id;
    end if;
    v_seen_ids := array_append(v_seen_ids,v_existing_id);
    v_count := v_count + 1;
  end loop;
  update public.task_subtask_definitions d set is_active=false
  where d.household_id=v_household and d.task_definition_id=p_task_definition_id
    and not (d.id=any(v_seen_ids))
    and exists(select 1 from public.task_subtask_instances i where i.household_id=d.household_id and i.source_definition_id=d.id);
  delete from public.task_subtask_definitions d
  where d.household_id=v_household and d.task_definition_id=p_task_definition_id
    and not (d.id=any(v_seen_ids))
    and not exists(select 1 from public.task_subtask_instances i where i.household_id=d.household_id and i.source_definition_id=d.id);
  update public.task_definitions set completion_mode=case when v_count>0 then 'subtasks' else 'whole' end
  where household_id=v_household and id=p_task_definition_id;
  v_result:=jsonb_build_object('ok',true,'task_definition_id',p_task_definition_id,'subtask_count',v_count);
  update private.mutation_receipts set result_type='task_definition',result_id=p_task_definition_id,result_payload=v_result
  where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end $$;
revoke all on function public.server_tx_replace_routine_subtasks(uuid,uuid,uuid,jsonb) from public,anon,authenticated;
grant execute on function public.server_tx_replace_routine_subtasks(uuid,uuid,uuid,jsonb) to service_role;
