\set ON_ERROR_STOP on
begin;
set role service_role;
do $$
declare
 actor uuid:=gen_random_uuid(); other uuid:=gen_random_uuid(); household uuid; pending uuid; result jsonb;
 milk_op uuid:=gen_random_uuid(); egg_op uuid:=gen_random_uuid(); milk uuid; egg uuid; rejected boolean:=false;
 payload jsonb;
begin
 insert into auth.users(id) values(actor),(other);
 household := (public.server_tx_create_household(actor,gen_random_uuid(),'Quick shopping','Owner')->>'household_id')::uuid;
 perform public.server_tx_create_household(other,gen_random_uuid(),'Other','Other');
 payload:=jsonb_build_object('raw_text','牛乳と卵買って','candidates',jsonb_build_array(
   jsonb_build_object('candidate_id','c1','operation_id',milk_op,'kind','shopping','title','牛乳','status','draft','action_type','shopping_item_add','payload',jsonb_build_object('title','牛乳')),
   jsonb_build_object('candidate_id','c2','operation_id',egg_op,'kind','shopping','title','卵','status','draft','action_type','shopping_item_add','payload',jsonb_build_object('title','卵'))));

 -- Undo before the worker ran: the pending action is cancelled and nothing is added.
 pending:=(public.server_tx_create_pending_action(actor,household,gen_random_uuid(),'line','line_multi_intent_review',payload,30)->>'pending_action_id')::uuid;
 perform public.server_tx_confirm_pending_action(actor,pending);
 result:=public.server_tx_undo_line_quick_shopping(actor,pending);
 if result->>'status'<>'cancelled_before_add' or (select status from private.pending_actions where id=pending)<>'cancelled' then
   raise exception 'FAIL undo before add: %',result; end if;

 -- Undo after the items were added: open ones are removed, bought ones are kept.
 pending:=(public.server_tx_create_pending_action(actor,household,gen_random_uuid(),'line','line_multi_intent_review',payload,30)->>'pending_action_id')::uuid;
 perform public.server_tx_confirm_pending_action(actor,pending);
 milk:=(public.server_tx_add_shopping_item(actor,milk_op,'牛乳','store',null,null,null)->>'shopping_item_id')::uuid;
 egg:=(public.server_tx_add_shopping_item(actor,egg_op,'卵','store',null,null,null)->>'shopping_item_id')::uuid;
 update private.pending_actions set status='succeeded' where id=pending;
 perform public.server_tx_shopping_action_v2(actor,gen_random_uuid(),egg,'purchased',(select revision from public.shopping_items where id=egg),null);
 begin perform public.server_tx_undo_line_quick_shopping(other,pending);
 exception when raise_exception then if sqlerrm='INVALID_INPUT' then rejected:=true; else raise; end if; end;
 if not rejected then raise exception 'FAIL another user undid'; end if;
 result:=public.server_tx_undo_line_quick_shopping(actor,pending);
 if result->'removed'<>'["牛乳"]'::jsonb or result->'kept'<>'["卵"]'::jsonb then raise exception 'FAIL undo result: %',result; end if;
 if (select status from public.shopping_items where id=milk)<>'cancelled' or (select status from public.shopping_items where id=egg)<>'purchased' then
   raise exception 'FAIL item states after undo'; end if;
 -- A second tap is harmless.
 if public.server_tx_undo_line_quick_shopping(actor,pending)->'removed'<>'["牛乳"]'::jsonb then raise exception 'FAIL repeat undo'; end if;

 -- A single "牛乳買って" is a plain shopping_item_add pending action.
 pending:=(public.server_tx_create_pending_action(actor,household,gen_random_uuid(),'line','shopping_item_add',
   jsonb_build_object('title','パン'),30)->>'pending_action_id')::uuid;
 perform public.server_tx_confirm_pending_action(actor,pending);
 perform public.server_tx_add_shopping_item(actor,(select operation_id from private.pending_actions where id=pending),'パン','store',null,null,null);
 update private.pending_actions set status='succeeded' where id=pending;
 result:=public.server_tx_undo_line_quick_shopping(actor,pending);
 if result->'removed'<>'["パン"]'::jsonb then raise exception 'FAIL single item undo: %',result; end if;
end $$;
reset role;
rollback;
select 'line_quick_shopping_undo: PASS' as result;
