-- Atomically replace the complete active weekday set for one or more task
-- definitions. Existing completed/in-progress history is retained by the
-- canonical child mutations; future todo work is reconciled in this same DB
-- transaction, so one UI save cannot leave a half-applied weekly schedule.
create or replace function public.server_tx_replace_recurrence_schedule(
  p_actor_id uuid,
  p_operation_id uuid,
  p_replacements jsonb
) returns jsonb
language plpgsql
security invoker
set search_path = ''
as $$
declare
  v_household_id uuid;
  v_hash text;
  v_receipt record;
  v_replacement jsonb;
  v_rule jsonb;
  v_existing record;
  v_definition_id uuid;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null
     or jsonb_typeof(p_replacements) <> 'array' or jsonb_array_length(p_replacements) = 0 then
    raise exception 'INVALID_INPUT';
  end if;
  if exists (
    select 1 from jsonb_array_elements(p_replacements) r
    where coalesce(r->>'task_definition_id', '') = ''
       or jsonb_typeof(r->'rules') <> 'array'
  ) then raise exception 'INVALID_INPUT'; end if;
  if exists (
    select 1
    from jsonb_array_elements(p_replacements) r
    cross join lateral jsonb_array_elements(r->'rules') x
    group by r->>'task_definition_id', x->>'weekday'
    having count(*) > 1
  ) then raise exception 'INVALID_INPUT'; end if;

  v_hash := encode(sha256(convert_to('replace-recurrence-schedule|' || p_replacements::text, 'UTF8')), 'hex');
  insert into private.mutation_receipts(actor_id, operation_id, action_type, request_hash)
  values(p_actor_id, p_operation_id, 'replace-recurrence-schedule', v_hash)
  on conflict(actor_id, operation_id) do nothing;
  if not found then
    select * into v_receipt from private.mutation_receipts
      where actor_id = p_actor_id and operation_id = p_operation_id;
    if v_receipt.request_hash <> v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    return v_receipt.result_payload;
  end if;

  select household_id into v_household_id from public.household_members where user_id = p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;
  if exists (
    select 1 from jsonb_array_elements(p_replacements) r
    where not exists (
      select 1 from public.task_definitions td
      where td.id = (r->>'task_definition_id')::uuid and td.household_id = v_household_id
    )
  ) then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;

  for v_replacement in select * from jsonb_array_elements(p_replacements)
  loop
    v_definition_id := (v_replacement->>'task_definition_id')::uuid;
    for v_existing in
      select weekday from public.recurrence_rules
      where household_id = v_household_id and task_definition_id = v_definition_id
        and slot_key = 'default' and active
    loop
      if not exists (
        select 1 from jsonb_array_elements(v_replacement->'rules') x
        where (x->>'weekday')::int = v_existing.weekday
      ) then
        perform public.server_tx_deactivate_recurrence(
          p_actor_id, gen_random_uuid(), v_definition_id, v_existing.weekday, 'default'
        );
      end if;
    end loop;

    for v_rule in select * from jsonb_array_elements(v_replacement->'rules')
    loop
      perform public.server_tx_change_recurrence(
        p_actor_id,
        gen_random_uuid(),
        v_definition_id,
        (v_rule->>'weekday')::int,
        'default',
        v_rule->>'assignee_strategy',
        nullif(v_rule->>'planned_assignee_user_id', '')::uuid,
        nullif(v_rule->>'scheduled_local_time', '')::time,
        coalesce((v_rule->>'conflict_window_minutes')::int, 60),
        null
      );
    end loop;
  end loop;

  v_result := jsonb_build_object('household_id', v_household_id, 'replaced', jsonb_array_length(p_replacements));
  update private.mutation_receipts
  set result_type = 'recurrence_schedule', result_id = v_household_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;
  return v_result;
end;
$$;

revoke all on function public.server_tx_replace_recurrence_schedule(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.server_tx_replace_recurrence_schedule(uuid, uuid, jsonb) to service_role;
