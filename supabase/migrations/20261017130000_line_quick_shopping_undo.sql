-- LINEの「牛乳と卵買って」は確認タップなしで買い物リストに入り、返信の「取り消す」で戻せる
-- (owner 2026-10-17). This undoes one such LINE input: before the worker has added the
-- items it cancels the pending action; afterwards it removes the items that are still
-- open. Anything already bought, or changed by someone since, is left as it is.
create or replace function public.server_tx_undo_line_quick_shopping(p_actor_id uuid, p_pending_action_id uuid)
returns jsonb language plpgsql security invoker set search_path='' as $$
declare
  v private.pending_actions%rowtype; candidate jsonb; v_item public.shopping_items%rowtype;
  v_item_id uuid; removed text[]:='{}'; kept text[]:='{}'; candidates jsonb;
begin
  if p_actor_id is null or p_pending_action_id is null then raise exception 'INVALID_INPUT'; end if;
  select * into v from private.pending_actions where id=p_pending_action_id for update;
  if not found or v.actor_id<>p_actor_id or v.action_type not in ('line_multi_intent_review','shopping_item_add') then
    raise exception 'INVALID_INPUT';
  end if;
  -- One item ("牛乳買って") is a plain shopping_item_add executed under the pending
  -- action's own operation id; several are candidates of a multi-intent review.
  candidates:=case when v.action_type='shopping_item_add'
    then jsonb_build_array(jsonb_build_object('operation_id',v.operation_id,'title',v.normalized_payload->>'title',
      'action_type','shopping_item_add','status','draft'))
    else coalesce(v.normalized_payload->'candidates','[]') end;
  if exists(select 1 from jsonb_array_elements(candidates) c
    where coalesce(c->>'status','draft')<>'cancelled' and c->>'action_type'<>'shopping_item_add') then
    raise exception 'INVALID_INPUT';
  end if;
  if v.status='cancelled' then return jsonb_build_object('status','already_undone','removed','[]'::jsonb,'kept','[]'::jsonb); end if;
  if v.status in ('draft','confirmed','queued') then
    update private.pending_actions set status='cancelled' where id=v.id;
    return jsonb_build_object('status','cancelled_before_add','removed',
      coalesce((select jsonb_agg(c->>'title') from jsonb_array_elements(candidates) c
        where coalesce(c->>'status','draft')<>'cancelled'),'[]'::jsonb),'kept','[]'::jsonb);
  end if;
  if v.status='executing' then raise exception 'OPERATION_IN_PROGRESS'; end if;
  for candidate in select c from jsonb_array_elements(candidates) c
    where coalesce(c->>'status','draft')<>'cancelled'
  loop
    select r.result_id into v_item_id from private.canonical_operation_receipts r
    where r.operator_user_id=p_actor_id and r.operation_id=(candidate->>'operation_id')::uuid
      and r.result_type='shopping' and r.completed_at is not null;
    select * into v_item from public.shopping_items where id=v_item_id for update;
    if not found then continue; end if;
    if v_item.status='cancelled' then
      removed:=array_append(removed,v_item.title);
    elsif v_item.status in ('wanted','assigned') then
      perform public.server_tx_shopping_action_v2(p_actor_id,gen_random_uuid(),v_item.id,'cancel',v_item.revision,null);
      removed:=array_append(removed,v_item.title);
    else
      kept:=array_append(kept,v_item.title);
    end if;
  end loop;
  return jsonb_build_object('status','removed','removed',to_jsonb(removed),'kept',to_jsonb(kept));
end $$;
revoke all on function public.server_tx_undo_line_quick_shopping(uuid,uuid) from public,anon,authenticated;
grant execute on function public.server_tx_undo_line_quick_shopping(uuid,uuid) to service_role;
