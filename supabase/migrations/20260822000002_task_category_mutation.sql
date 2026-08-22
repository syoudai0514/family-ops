-- Household category settings are server mutations, never direct client
-- writes. Unknown legacy task categories remain readable as "その他".
create or replace function public.server_tx_update_task_categories(
  p_actor_id uuid, p_operation_id uuid, p_categories jsonb
) returns jsonb language plpgsql security invoker set search_path = '' as $$
declare
  v_household_id uuid;
  v_receipt record;
  v_hash text;
  v_item jsonb;
  v_index int := 0;
begin
  if p_actor_id is null or p_operation_id is null or jsonb_typeof(p_categories) <> 'array' then
    raise exception 'INVALID_INPUT';
  end if;
  v_hash := encode(sha256(convert_to('task-categories|' || p_categories::text, 'UTF8')), 'hex');
  loop
    insert into private.mutation_receipts(actor_id, operation_id, action_type, request_hash)
      values (p_actor_id, p_operation_id, 'update-task-categories', v_hash)
      on conflict (actor_id, operation_id) do nothing;
    if found then exit; end if;
    select * into v_receipt from private.mutation_receipts
      where actor_id = p_actor_id and operation_id = p_operation_id for update;
    if v_receipt.request_hash <> v_hash then raise exception 'IDEMPOTENCY_CONFLICT'; end if;
    return v_receipt.result_payload;
  end loop;
  select household_id into v_household_id from public.household_members where user_id = p_actor_id;
  if v_household_id is null then raise exception 'NOT_HOUSEHOLD_MEMBER'; end if;

  for v_item in select value from jsonb_array_elements(p_categories) loop
    v_index := v_index + 1;
    if coalesce(nullif(btrim(v_item->>'code'), ''), '') = '' or coalesce(nullif(btrim(v_item->>'label'), ''), '') = '' then
      raise exception 'INVALID_INPUT';
    end if;
    insert into public.household_task_categories
      (household_id, code, label, icon_key, accent_token, sort_order, is_active, is_system)
    values (
      v_household_id, v_item->>'code', v_item->>'label', nullif(v_item->>'icon_key', ''),
      nullif(v_item->>'accent_token', ''), v_index,
      coalesce((v_item->>'is_active')::boolean, true), false
    )
    on conflict (household_id, code) do update set
      label = excluded.label,
      icon_key = excluded.icon_key,
      accent_token = excluded.accent_token,
      sort_order = excluded.sort_order,
      is_active = excluded.is_active,
      updated_at = now();
  end loop;
  update public.household_task_categories
    set is_active = false, updated_at = now()
    where household_id = v_household_id
      and code not in (select value->>'code' from jsonb_array_elements(p_categories));

  update private.mutation_receipts set result_type = 'household_task_categories', result_payload = jsonb_build_object('ok', true)
    where actor_id = p_actor_id and operation_id = p_operation_id;
  return jsonb_build_object('ok', true);
end $$;
revoke all on function public.server_tx_update_task_categories(uuid, uuid, jsonb) from public, anon, authenticated;
grant execute on function public.server_tx_update_task_categories(uuid, uuid, jsonb) to service_role;
