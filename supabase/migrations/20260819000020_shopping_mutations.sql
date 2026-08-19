-- WP2: shopping_items state machine mutations.
-- docs/design/v6/03_DOMAIN_AND_DATA_MODEL.md #6; state machine confirmed
-- directly from the shopping_items CHECK constraints
-- (20260819000003_tasks_recurrence.sql):
--   wanted/assigned -> ordered   (purchase_method in online/either/undecided)
--   wanted/assigned -> purchased (purchase_method in store/either/undecided)
--   ordered         -> arrived
--   wanted/assigned/ordered -> cancelled (terminal)
--   purchased/arrived/cancelled -> terminal, no further transition
-- Every mutation locks the row FOR UPDATE and validates the current status
-- (+ purchase_method, for order/purchase) before transitioning, raising
-- INVALID_SHOPPING_TRANSITION otherwise.

-- ---------------------------------------------------------------------------
-- add-shopping-item
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_add_shopping_item(
  p_actor_id uuid,
  p_operation_id uuid,
  p_title text,
  p_purchase_method text,
  p_assignee_user_id uuid,
  p_url text,
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
  v_item_id uuid;
  v_status text;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null then
    raise exception 'INVALID_INPUT';
  end if;
  if coalesce(btrim(p_title), '') = '' then
    raise exception 'INVALID_INPUT';
  end if;
  if p_purchase_method not in ('store', 'online', 'either', 'undecided') then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to('add-shopping-item|' || p_title || '|' || p_purchase_method, 'UTF8')),
    'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'add-shopping-item', v_request_hash)
    on conflict (actor_id, operation_id) do nothing;

    if found then
      exit;
    end if;

    select * into v_receipt
    from private.mutation_receipts
    where actor_id = p_actor_id and operation_id = p_operation_id
    for update;

    if found then
      if v_receipt.request_hash <> v_request_hash then
        raise exception 'IDEMPOTENCY_CONFLICT';
      end if;
      return v_receipt.result_payload;
    end if;
  end loop;

  select household_id into v_household_id
  from public.household_members
  where user_id = p_actor_id;

  if v_household_id is null then
    raise exception 'NOT_HOUSEHOLD_MEMBER';
  end if;

  if p_assignee_user_id is not null and not exists (
    select 1 from public.household_members
    where household_id = v_household_id and user_id = p_assignee_user_id
  ) then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  v_status := case when p_assignee_user_id is not null then 'assigned' else 'wanted' end;

  insert into public.shopping_items
    (household_id, title, purchase_method, status, assignee_id, url, due_at, created_by)
  values
    (v_household_id, btrim(p_title), p_purchase_method, v_status, p_assignee_user_id,
     nullif(btrim(coalesce(p_url, '')), ''), p_due_at, p_actor_id)
  returning id into v_item_id;

  v_result := jsonb_build_object('shopping_item_id', v_item_id);

  update private.mutation_receipts
  set result_type = 'shopping_item', result_id = v_item_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_add_shopping_item(uuid, uuid, text, text, uuid, text, timestamptz) from public;
revoke all on function public.server_tx_add_shopping_item(uuid, uuid, text, text, uuid, text, timestamptz) from anon;
revoke all on function public.server_tx_add_shopping_item(uuid, uuid, text, text, uuid, text, timestamptz) from authenticated;
grant execute on function public.server_tx_add_shopping_item(uuid, uuid, text, text, uuid, text, timestamptz) to service_role;

-- ---------------------------------------------------------------------------
-- assign-shopping-item (assign/unassign)
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_assign_shopping_item(
  p_actor_id uuid,
  p_operation_id uuid,
  p_shopping_item_id uuid,
  p_assignee_user_id uuid,
  p_unassign boolean
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
  v_item record;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_shopping_item_id is null then
    raise exception 'INVALID_INPUT';
  end if;
  if coalesce(p_unassign, false) is false and p_assignee_user_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(
    sha256(convert_to(
      'assign-shopping-item|' || p_shopping_item_id::text || '|'
        || coalesce(p_assignee_user_id::text, '') || '|' || coalesce(p_unassign::text, ''),
      'UTF8'
    )),
    'hex'
  );

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'assign-shopping-item', v_request_hash)
    on conflict (actor_id, operation_id) do nothing;

    if found then
      exit;
    end if;

    select * into v_receipt
    from private.mutation_receipts
    where actor_id = p_actor_id and operation_id = p_operation_id
    for update;

    if found then
      if v_receipt.request_hash <> v_request_hash then
        raise exception 'IDEMPOTENCY_CONFLICT';
      end if;
      return v_receipt.result_payload;
    end if;
  end loop;

  select household_id into v_household_id
  from public.household_members
  where user_id = p_actor_id;

  if v_household_id is null then
    raise exception 'NOT_HOUSEHOLD_MEMBER';
  end if;

  if p_assignee_user_id is not null and not exists (
    select 1 from public.household_members
    where household_id = v_household_id and user_id = p_assignee_user_id
  ) then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;

  select * into v_item
  from public.shopping_items
  where household_id = v_household_id and id = p_shopping_item_id
  for update;

  if not found then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;
  if v_item.status not in ('wanted', 'assigned') then
    raise exception 'INVALID_SHOPPING_TRANSITION';
  end if;

  if coalesce(p_unassign, false) then
    update public.shopping_items
    set status = 'wanted', assignee_id = null
    where household_id = v_household_id and id = p_shopping_item_id;
  else
    update public.shopping_items
    set status = 'assigned', assignee_id = p_assignee_user_id
    where household_id = v_household_id and id = p_shopping_item_id;
  end if;

  v_result := jsonb_build_object('ok', true);

  update private.mutation_receipts
  set result_type = 'shopping_item', result_id = p_shopping_item_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_assign_shopping_item(uuid, uuid, uuid, uuid, boolean) from public;
revoke all on function public.server_tx_assign_shopping_item(uuid, uuid, uuid, uuid, boolean) from anon;
revoke all on function public.server_tx_assign_shopping_item(uuid, uuid, uuid, uuid, boolean) from authenticated;
grant execute on function public.server_tx_assign_shopping_item(uuid, uuid, uuid, uuid, boolean) to service_role;

-- ---------------------------------------------------------------------------
-- order-shopping-item
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_order_shopping_item(
  p_actor_id uuid,
  p_operation_id uuid,
  p_shopping_item_id uuid
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
  v_item record;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_shopping_item_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(sha256(convert_to('order-shopping-item|' || p_shopping_item_id::text, 'UTF8')), 'hex');

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'order-shopping-item', v_request_hash)
    on conflict (actor_id, operation_id) do nothing;

    if found then
      exit;
    end if;

    select * into v_receipt
    from private.mutation_receipts
    where actor_id = p_actor_id and operation_id = p_operation_id
    for update;

    if found then
      if v_receipt.request_hash <> v_request_hash then
        raise exception 'IDEMPOTENCY_CONFLICT';
      end if;
      return v_receipt.result_payload;
    end if;
  end loop;

  select household_id into v_household_id
  from public.household_members
  where user_id = p_actor_id;

  if v_household_id is null then
    raise exception 'NOT_HOUSEHOLD_MEMBER';
  end if;

  select * into v_item
  from public.shopping_items
  where household_id = v_household_id and id = p_shopping_item_id
  for update;

  if not found then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;
  if v_item.status not in ('wanted', 'assigned') or v_item.purchase_method not in ('online', 'either', 'undecided') then
    raise exception 'INVALID_SHOPPING_TRANSITION';
  end if;

  update public.shopping_items
  set status = 'ordered', ordered_at = now(),
      assignee_id = coalesce(assignee_id, p_actor_id)
  where household_id = v_household_id and id = p_shopping_item_id;

  v_result := jsonb_build_object('ok', true);

  update private.mutation_receipts
  set result_type = 'shopping_item', result_id = p_shopping_item_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_order_shopping_item(uuid, uuid, uuid) from public;
revoke all on function public.server_tx_order_shopping_item(uuid, uuid, uuid) from anon;
revoke all on function public.server_tx_order_shopping_item(uuid, uuid, uuid) from authenticated;
grant execute on function public.server_tx_order_shopping_item(uuid, uuid, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- purchase-shopping-item
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_purchase_shopping_item(
  p_actor_id uuid,
  p_operation_id uuid,
  p_shopping_item_id uuid
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
  v_item record;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_shopping_item_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(sha256(convert_to('purchase-shopping-item|' || p_shopping_item_id::text, 'UTF8')), 'hex');

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'purchase-shopping-item', v_request_hash)
    on conflict (actor_id, operation_id) do nothing;

    if found then
      exit;
    end if;

    select * into v_receipt
    from private.mutation_receipts
    where actor_id = p_actor_id and operation_id = p_operation_id
    for update;

    if found then
      if v_receipt.request_hash <> v_request_hash then
        raise exception 'IDEMPOTENCY_CONFLICT';
      end if;
      return v_receipt.result_payload;
    end if;
  end loop;

  select household_id into v_household_id
  from public.household_members
  where user_id = p_actor_id;

  if v_household_id is null then
    raise exception 'NOT_HOUSEHOLD_MEMBER';
  end if;

  select * into v_item
  from public.shopping_items
  where household_id = v_household_id and id = p_shopping_item_id
  for update;

  if not found then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;
  if v_item.status not in ('wanted', 'assigned') or v_item.purchase_method not in ('store', 'either', 'undecided') then
    raise exception 'INVALID_SHOPPING_TRANSITION';
  end if;

  update public.shopping_items
  set status = 'purchased', purchased_at = now(),
      assignee_id = coalesce(assignee_id, p_actor_id)
  where household_id = v_household_id and id = p_shopping_item_id;

  v_result := jsonb_build_object('ok', true);

  update private.mutation_receipts
  set result_type = 'shopping_item', result_id = p_shopping_item_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_purchase_shopping_item(uuid, uuid, uuid) from public;
revoke all on function public.server_tx_purchase_shopping_item(uuid, uuid, uuid) from anon;
revoke all on function public.server_tx_purchase_shopping_item(uuid, uuid, uuid) from authenticated;
grant execute on function public.server_tx_purchase_shopping_item(uuid, uuid, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- arrive-shopping-item
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_arrive_shopping_item(
  p_actor_id uuid,
  p_operation_id uuid,
  p_shopping_item_id uuid
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
  v_item record;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_shopping_item_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(sha256(convert_to('arrive-shopping-item|' || p_shopping_item_id::text, 'UTF8')), 'hex');

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'arrive-shopping-item', v_request_hash)
    on conflict (actor_id, operation_id) do nothing;

    if found then
      exit;
    end if;

    select * into v_receipt
    from private.mutation_receipts
    where actor_id = p_actor_id and operation_id = p_operation_id
    for update;

    if found then
      if v_receipt.request_hash <> v_request_hash then
        raise exception 'IDEMPOTENCY_CONFLICT';
      end if;
      return v_receipt.result_payload;
    end if;
  end loop;

  select household_id into v_household_id
  from public.household_members
  where user_id = p_actor_id;

  if v_household_id is null then
    raise exception 'NOT_HOUSEHOLD_MEMBER';
  end if;

  select * into v_item
  from public.shopping_items
  where household_id = v_household_id and id = p_shopping_item_id
  for update;

  if not found then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;
  if v_item.status <> 'ordered' then
    raise exception 'INVALID_SHOPPING_TRANSITION';
  end if;

  update public.shopping_items
  set status = 'arrived', arrived_at = now()
  where household_id = v_household_id and id = p_shopping_item_id;

  v_result := jsonb_build_object('ok', true);

  update private.mutation_receipts
  set result_type = 'shopping_item', result_id = p_shopping_item_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_arrive_shopping_item(uuid, uuid, uuid) from public;
revoke all on function public.server_tx_arrive_shopping_item(uuid, uuid, uuid) from anon;
revoke all on function public.server_tx_arrive_shopping_item(uuid, uuid, uuid) from authenticated;
grant execute on function public.server_tx_arrive_shopping_item(uuid, uuid, uuid) to service_role;

-- ---------------------------------------------------------------------------
-- cancel-shopping-item
-- ---------------------------------------------------------------------------

create or replace function public.server_tx_cancel_shopping_item(
  p_actor_id uuid,
  p_operation_id uuid,
  p_shopping_item_id uuid
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
  v_item record;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_shopping_item_id is null then
    raise exception 'INVALID_INPUT';
  end if;

  v_request_hash := encode(sha256(convert_to('cancel-shopping-item|' || p_shopping_item_id::text, 'UTF8')), 'hex');

  loop
    insert into private.mutation_receipts (actor_id, operation_id, action_type, request_hash)
    values (p_actor_id, p_operation_id, 'cancel-shopping-item', v_request_hash)
    on conflict (actor_id, operation_id) do nothing;

    if found then
      exit;
    end if;

    select * into v_receipt
    from private.mutation_receipts
    where actor_id = p_actor_id and operation_id = p_operation_id
    for update;

    if found then
      if v_receipt.request_hash <> v_request_hash then
        raise exception 'IDEMPOTENCY_CONFLICT';
      end if;
      return v_receipt.result_payload;
    end if;
  end loop;

  select household_id into v_household_id
  from public.household_members
  where user_id = p_actor_id;

  if v_household_id is null then
    raise exception 'NOT_HOUSEHOLD_MEMBER';
  end if;

  select * into v_item
  from public.shopping_items
  where household_id = v_household_id and id = p_shopping_item_id
  for update;

  if not found then
    raise exception 'CROSS_HOUSEHOLD_RESOURCE';
  end if;
  if v_item.status not in ('wanted', 'assigned', 'ordered') then
    raise exception 'INVALID_SHOPPING_TRANSITION';
  end if;

  update public.shopping_items
  set status = 'cancelled'
  where household_id = v_household_id and id = p_shopping_item_id;

  v_result := jsonb_build_object('ok', true);

  update private.mutation_receipts
  set result_type = 'shopping_item', result_id = p_shopping_item_id, result_payload = v_result
  where actor_id = p_actor_id and operation_id = p_operation_id;

  return v_result;
end;
$$;

revoke all on function public.server_tx_cancel_shopping_item(uuid, uuid, uuid) from public;
revoke all on function public.server_tx_cancel_shopping_item(uuid, uuid, uuid) from anon;
revoke all on function public.server_tx_cancel_shopping_item(uuid, uuid, uuid) from authenticated;
grant execute on function public.server_tx_cancel_shopping_item(uuid, uuid, uuid) to service_role;
