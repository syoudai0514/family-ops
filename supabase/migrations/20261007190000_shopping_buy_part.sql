-- "食器用洗剤は買った" when the list item is "食器用洗剤とパパ用のシャンプーとリンスの購入".
--
-- 2026-10-07: that one list item bundled three things; the owner said only the dish
-- soap was bought, and the whole item was marked 買った, so the shampoo and conditioner
-- dropped off the list. A part of an item can now be bought: the open item keeps the
-- rest (renamed to what is still needed, same assignee), and what was bought becomes
-- its own item, already purchased. Nothing is lost, and a replay does nothing twice.

create or replace function public.server_tx_shopping_buy_part_v1(
  p_actor_id uuid,
  p_operation_id uuid,
  p_shopping_item_id uuid,
  p_bought_title text,
  p_remaining_title text,
  p_source text default 'line'
) returns jsonb
language plpgsql
security invoker
set search_path=''
as $$
declare
  v_context jsonb;
  v_household_id uuid;
  v_actor_ref uuid;
  v_hash text;
  v_receipt private.mutation_receipts%rowtype;
  v_item public.shopping_items%rowtype;
  v_bought text:=btrim(coalesce(p_bought_title,''));
  v_remaining text:=btrim(coalesce(p_remaining_title,''));
  v_new jsonb;
  v_new_id uuid;
  v_new_revision bigint;
  v_result jsonb;
begin
  if p_actor_id is null or p_operation_id is null or p_shopping_item_id is null
     or v_bought='' or v_remaining='' or length(v_bought)>200 or length(v_remaining)>200
     or v_bought=v_remaining or p_source not in ('line','pwa') then
    raise exception 'INVALID_INPUT';
  end if;

  v_context:=private.fn_require_production_actor_context_v1(p_actor_id);
  v_household_id:=(v_context->>'household_id')::uuid;
  v_actor_ref:=(v_context->>'actor_ref_id')::uuid;

  v_hash:=encode(sha256(convert_to(
    'shopping-buy-part|'||p_shopping_item_id::text||'|'||v_bought||'|'||v_remaining||'|'||p_source,'UTF8')),'hex');
  loop
    insert into private.mutation_receipts(actor_id,operation_id,action_type,request_hash,actor_ref_id)
      values(p_actor_id,p_operation_id,'shopping-buy-part',v_hash,v_actor_ref)
      on conflict(actor_id,operation_id) do nothing;
    if found then exit; end if;
    select * into v_receipt from private.mutation_receipts
      where actor_id=p_actor_id and operation_id=p_operation_id for update;
    if found then
      if v_receipt.action_type<>'shopping-buy-part' or v_receipt.request_hash<>v_hash then
        raise exception 'IDEMPOTENCY_CONFLICT';
      end if;
      if v_receipt.result_payload is null then raise exception 'IDEMPOTENCY_INCOMPLETE'; end if;
      return v_receipt.result_payload;
    end if;
  end loop;

  select * into v_item from public.shopping_items
  where household_id=v_household_id and id=p_shopping_item_id and test_context_id is null
  for update;
  if not found then raise exception 'CROSS_HOUSEHOLD_RESOURCE'; end if;
  if v_item.status not in ('wanted','assigned') then raise exception 'INVALID_SHOPPING_TRANSITION'; end if;

  update public.shopping_items set title=v_remaining,revision=revision+1
  where household_id=v_household_id and id=p_shopping_item_id;

  -- What was bought: its own item, bought now (same method, unassigned).
  v_new:=private.fn_command_create_shopping_item_v1(
    v_household_id,p_actor_id,v_actor_ref,null,
    v_bought,v_item.purchase_method,'unassigned',null,'normal',null,null,
    (md5(p_operation_id::text||':buy-part-add'))::uuid,p_source
  );
  v_new_id:=(v_new->>'shopping_item_id')::uuid;
  v_new_revision:=(v_new->>'revision')::bigint;
  perform private.fn_command_complete_shopping_item_v1(
    v_household_id,p_actor_id,v_actor_ref,null,v_new_id,'purchased',v_actor_ref,
    v_new_revision,(md5(p_operation_id::text||':buy-part-purchase'))::uuid,p_source
  );

  v_result:=jsonb_build_object('ok',true,'remaining_item_id',p_shopping_item_id,
    'remaining_title',v_remaining,'bought_item_id',v_new_id,'bought_title',v_bought,
    'remaining_revision',v_item.revision+1);
  update private.mutation_receipts set
    result_type='shopping_item',result_id=p_shopping_item_id,result_payload=v_result
  where actor_id=p_actor_id and operation_id=p_operation_id;
  return v_result;
end;
$$;

revoke all on function public.server_tx_shopping_buy_part_v1(uuid,uuid,uuid,text,text,text)
  from public,anon,authenticated;
grant execute on function public.server_tx_shopping_buy_part_v1(uuid,uuid,uuid,text,text,text)
  to service_role;
