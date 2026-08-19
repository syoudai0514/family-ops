-- WP2: shopping_items state machine — add/assign/order/purchase/arrive/cancel.
-- State machine confirmed from shopping_items CHECK constraints
-- (20260819000003_tasks_recurrence.sql); see
-- supabase/migrations/20260819000020_shopping_mutations.sql's header.
\set ON_ERROR_STOP on

insert into auth.users (id) values
  ('40000000-0000-0000-0000-000000000001'),
  ('40000000-0000-0000-0000-000000000002');

set role service_role;

do $$
declare
  v_hh jsonb;
  v_hh_id uuid;
  v_item_id uuid;
  v_result jsonb;
begin
  v_hh := public.server_tx_create_household('40000000-0000-0000-0000-000000000001', gen_random_uuid(), 'Shopping HH', 'Owner');
  v_hh_id := (v_hh->>'household_id')::uuid;
  insert into public.household_members (household_id, user_id, member_role)
  values (v_hh_id, '40000000-0000-0000-0000-000000000002', 'adult');

  -- add-shopping-item happy path (unassigned -> wanted)
  v_result := public.server_tx_add_shopping_item(
    '40000000-0000-0000-0000-000000000001', gen_random_uuid(), 'Milk', 'either', null, null, null
  );
  v_item_id := (v_result->>'shopping_item_id')::uuid;
  if (select status from public.shopping_items where id = v_item_id) <> 'wanted' then
    raise exception 'FAIL shopping: add-shopping-item without an assignee must start as wanted';
  end if;

  -- assign-shopping-item
  perform public.server_tx_assign_shopping_item('40000000-0000-0000-0000-000000000001', gen_random_uuid(), v_item_id, '40000000-0000-0000-0000-000000000002', false);
  if (select status from public.shopping_items where id = v_item_id) <> 'assigned' then
    raise exception 'FAIL shopping: assign-shopping-item must set status=assigned';
  end if;

  -- unassign (assignee_user_id null / p_unassign=true) goes back to wanted
  perform public.server_tx_assign_shopping_item('40000000-0000-0000-0000-000000000001', gen_random_uuid(), v_item_id, null, true);
  if (select status from public.shopping_items where id = v_item_id) <> 'wanted' or (select assignee_id from public.shopping_items where id = v_item_id) is not null then
    raise exception 'FAIL shopping: unassign must revert to wanted with a null assignee';
  end if;

  -- purchase-method='either' can go either order or purchase path; take purchase (store) path
  perform public.server_tx_purchase_shopping_item('40000000-0000-0000-0000-000000000001', gen_random_uuid(), v_item_id);
  if (select status from public.shopping_items where id = v_item_id) <> 'purchased' then
    raise exception 'FAIL shopping: purchase-shopping-item must set status=purchased';
  end if;
  if (select purchased_at from public.shopping_items where id = v_item_id) is null then
    raise exception 'FAIL shopping: purchased_at must be set';
  end if;
  if (select ordered_at from public.shopping_items where id = v_item_id) is not null then
    raise exception 'FAIL shopping: ordered_at must stay null on the store-purchase path';
  end if;

  -- purchased is terminal
  begin
    perform public.server_tx_cancel_shopping_item('40000000-0000-0000-0000-000000000001', gen_random_uuid(), v_item_id);
    raise exception 'FAIL shopping: cancel from purchased must be rejected (terminal state)';
  exception
    when others then
      if sqlerrm <> 'INVALID_SHOPPING_TRANSITION' then
        raise exception 'FAIL shopping: expected INVALID_SHOPPING_TRANSITION, got %', sqlerrm;
      end if;
  end;
end;
$$;

-- online order -> arrive path
do $$
declare
  v_hh_id uuid;
  v_item_id uuid;
  v_result jsonb;
begin
  select id into v_hh_id from public.households where name = 'Shopping HH';

  v_result := public.server_tx_add_shopping_item(
    '40000000-0000-0000-0000-000000000001', gen_random_uuid(), 'New shoes', 'online', null, 'https://example.com/shoes', null
  );
  v_item_id := (v_result->>'shopping_item_id')::uuid;

  -- store-only method can never be ordered; 'online' item CAN be ordered
  perform public.server_tx_order_shopping_item('40000000-0000-0000-0000-000000000001', gen_random_uuid(), v_item_id);
  if (select status from public.shopping_items where id = v_item_id) <> 'ordered' then
    raise exception 'FAIL shopping: order-shopping-item must set status=ordered';
  end if;
  if (select ordered_at from public.shopping_items where id = v_item_id) is null then
    raise exception 'FAIL shopping: ordered_at must be set';
  end if;
  -- order-shopping-item auto-assigns the caller when unassigned
  if (select assignee_id from public.shopping_items where id = v_item_id) <> '40000000-0000-0000-0000-000000000001'::uuid then
    raise exception 'FAIL shopping: order-shopping-item must auto-assign the caller when previously unassigned';
  end if;

  -- purchase-shopping-item from 'ordered' is rejected (wrong source state)
  begin
    perform public.server_tx_purchase_shopping_item('40000000-0000-0000-0000-000000000001', gen_random_uuid(), v_item_id);
    raise exception 'FAIL shopping: purchase from ordered must be rejected';
  exception
    when others then
      if sqlerrm <> 'INVALID_SHOPPING_TRANSITION' then
        raise exception 'FAIL shopping: expected INVALID_SHOPPING_TRANSITION, got %', sqlerrm;
      end if;
  end;

  -- arrive-shopping-item completes the online path
  perform public.server_tx_arrive_shopping_item('40000000-0000-0000-0000-000000000001', gen_random_uuid(), v_item_id);
  if (select status from public.shopping_items where id = v_item_id) <> 'arrived' then
    raise exception 'FAIL shopping: arrive-shopping-item must set status=arrived';
  end if;
  if (select arrived_at from public.shopping_items where id = v_item_id) is null then
    raise exception 'FAIL shopping: arrived_at must be set';
  end if;
end;
$$;

-- purchase_method gates which forward edges are legal
do $$
declare
  v_hh_id uuid;
  v_store_item uuid;
  v_online_item uuid;
  v_result jsonb;
begin
  select id into v_hh_id from public.households where name = 'Shopping HH';

  v_result := public.server_tx_add_shopping_item('40000000-0000-0000-0000-000000000001', gen_random_uuid(), 'Store only', 'store', null, null, null);
  v_store_item := (v_result->>'shopping_item_id')::uuid;
  v_result := public.server_tx_add_shopping_item('40000000-0000-0000-0000-000000000001', gen_random_uuid(), 'Online only', 'online', null, null, null);
  v_online_item := (v_result->>'shopping_item_id')::uuid;

  -- a store-only item can never be ordered
  begin
    perform public.server_tx_order_shopping_item('40000000-0000-0000-0000-000000000001', gen_random_uuid(), v_store_item);
    raise exception 'FAIL shopping: a store-only item must never be ordered';
  exception
    when others then
      if sqlerrm <> 'INVALID_SHOPPING_TRANSITION' then
        raise exception 'FAIL shopping: expected INVALID_SHOPPING_TRANSITION, got %', sqlerrm;
      end if;
  end;

  -- an online-only item can never be purchased directly
  begin
    perform public.server_tx_purchase_shopping_item('40000000-0000-0000-0000-000000000001', gen_random_uuid(), v_online_item);
    raise exception 'FAIL shopping: an online-only item must never be purchased directly';
  exception
    when others then
      if sqlerrm <> 'INVALID_SHOPPING_TRANSITION' then
        raise exception 'FAIL shopping: expected INVALID_SHOPPING_TRANSITION, got %', sqlerrm;
      end if;
  end;

  -- cancel from 'wanted' is allowed and terminal
  perform public.server_tx_cancel_shopping_item('40000000-0000-0000-0000-000000000001', gen_random_uuid(), v_store_item);
  if (select status from public.shopping_items where id = v_store_item) <> 'cancelled' then
    raise exception 'FAIL shopping: cancel-shopping-item from wanted must set status=cancelled';
  end if;
end;
$$;

-- cross-household assignee rejected
do $$
declare
  v_hh_id uuid;
  v_item_id uuid;
  v_result jsonb;
  v_outsider uuid := '40000000-0000-0000-0000-000000000099';
begin
  select id into v_hh_id from public.households where name = 'Shopping HH';
  insert into auth.users (id) values (v_outsider) on conflict do nothing;

  v_result := public.server_tx_add_shopping_item('40000000-0000-0000-0000-000000000001', gen_random_uuid(), 'Cross guard', 'either', null, null, null);
  v_item_id := (v_result->>'shopping_item_id')::uuid;

  begin
    perform public.server_tx_assign_shopping_item('40000000-0000-0000-0000-000000000001', gen_random_uuid(), v_item_id, v_outsider, false);
    raise exception 'FAIL shopping: cross-household assignee must be rejected';
  exception
    when others then
      if sqlerrm <> 'CROSS_HOUSEHOLD_RESOURCE' then
        raise exception 'FAIL shopping: expected CROSS_HOUSEHOLD_RESOURCE, got %', sqlerrm;
      end if;
  end;
end;
$$;

reset role;
select 'shopping_state_machine: PASS' as result;
